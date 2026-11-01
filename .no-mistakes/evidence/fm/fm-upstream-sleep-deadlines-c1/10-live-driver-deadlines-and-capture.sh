#!/usr/bin/env bash
# Disposable live driver for the sleep-aware extension deadline change.
# Drives the real host (bin/fm-extension.mjs) and the real capture gate
# (bin/fm-procevent.sh + fm-procevent-extension-capture.pl) in an isolated
# temp root. Prints transcripts only; never touches the operator fleet.
set -u

ROOT=${1:?worktree root}
EVID=${2:?evidence dir}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-demo.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
PACKAGES="$TMP/packages"; HOMES="$TMP/homes"
mkdir -p "$PACKAGES" "$HOMES"
poll_pid=; group_pid=; inner_host_pid=
BOUND_MS=3000

cleanup() {
  [ -z "$group_pid" ] || kill -CONT -"$group_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -CONT "$inner_host_pid" 2>/dev/null || true
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -TERM "$inner_host_pid" 2>/dev/null || true
  [ -z "$group_pid" ] || kill -TERM -"$group_pid" 2>/dev/null || true
  for claim in "$TMP"/claims/*.claim; do
    [ -e "$claim" ] || continue
    pid=$(sed -n '2p' "$claim" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) kill -TERM "$pid" 2>/dev/null || true ;; esac
  done
  sleep 0.3
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------- fixture package: real executable, real manifest ----------
PACKAGE="$PACKAGES/sleep-deadlines"; mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<'JSON'
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.sleep-deadlines",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-sleep"]}
  ],
  "required_consents": []
}
JSON
chmod 0644 "$PACKAGE/firstmate-extension.json"
cat > "$PACKAGE/entrypoint.py" <<'PY'
#!/usr/bin/env python3
import json, os, signal, sys, time
request = json.load(sys.stdin)
with open("firstmate-extension.json", encoding="utf-8") as source:
    manifest = json.load(source)
verb = sys.argv[1] if len(sys.argv) > 1 else ""
def raw(value):
    sys.stdout.write(json.dumps(value) + "\n"); sys.stdout.flush()
if verb == "handshake":
    raw({"schema": "firstmate.extension-handshake-response.v1",
         "request_id": request["request_id"], "extension_id": manifest["id"],
         "extension_version": manifest["version"], "host_protocol": 1,
         "capability": "process-event-adapter", "capability_version": 1,
         "adapter_names": request["capability"]["adapter_names"]})
    sys.exit(0)
if verb != "invoke":
    sys.exit(8)
mode = request.get("input", {}).get("config_ref", "")
if mode == "good":
    raw({"schema": "firstmate.extension-response.v1", "request_id": request["request_id"],
         "ok": True, "result": {"status": "result", "output": "launch ready recovered\n"}, "error": None})
    sys.exit(0)
if mode.startswith("hold|"):
    _, marker, release = mode.split("|", 2)
    with open(marker, "w", encoding="utf-8") as out: out.write(f"{os.getpid()}\n")
    while not os.path.exists(release): time.sleep(0.01)
    raw({"schema": "firstmate.extension-response.v1", "request_id": request["request_id"],
         "ok": True, "result": {"status": "result", "output": "resumed inside the grace\n"}, "error": None})
    sys.exit(0)
if mode.startswith("stall|"):
    _, marker = mode.split("|", 1)
    with open(marker, "w", encoding="utf-8") as out: out.write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(1)
sys.exit(6)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

wait_for_file() { local f=$1 i; for i in $(seq 1 300); do [ -s "$f" ] && return 0; sleep 0.05; done; return 1; }
wait_for_pid_exit() { local p=$1 max=$(( $2 * 10 )) i; for ((i=0;i<max;i++)); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
sleep_until() { while [ "$(date +%s)" -lt "$1" ]; do sleep 0.2; done; }

prepare_home() { # <home> <timeout-ms>
  home=$1
  mkdir -p "$home"
  FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-sleep \
    --trust-same-user-code --timeout-ms "${2:-$BOUND_MS}" >/dev/null || fail "bind"
  resolution=$(FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" resolve-process-event ext-sleep) || fail "resolve"
  IFS=$'\t' read -r r_schema r_id r_version r_cap r_package r_binding r_extra <<< "$resolution"
}

start_poll() { # <home> <config-ref> <tag>
  FM_HOME="$1" "$ROOT/bin/fm-extension.mjs" process-event ext-sleep source.poll \
    --source-id sleep-source --config-ref "$2" \
    --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" \
    --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP/$3.out" 2> "$TMP/$3.err" &
  poll_pid=$!
}

freeze_invocation() { # <marker>
  local ep bp
  ep=$(sed -n '1p' "$1"); case "$ep" in ''|*[!0-9]*) fail "marker pid" ;; esac
  bp=$(ps -o pgid= -p "$ep" | tr -d '[:space:]'); case "$bp" in ''|*[!0-9]*) fail "pgid" ;; esac
  group_pid=$bp
  inner_host_pid=$(ps -o ppid= -p "$bp" | tr -d '[:space:]')
  case "$inner_host_pid" in ''|*[!0-9]*) fail "host pid" ;; esac
  kill -STOP "$inner_host_pid"; kill -STOP -"$group_pid"
}
resume_invocation() {
  [ -n "$group_pid" ] && kill -CONT -"$group_pid" 2>/dev/null || true
  [ -n "$inner_host_pid" ] && kill -CONT "$inner_host_pid" 2>/dev/null || true
  group_pid=; inner_host_pid=
}

echo "== SCENARIO A: frozen invocation, resumed inside the bounded grace =="
prepare_home "$HOMES/resume"
marker="$TMP/resume.marker"; release="$TMP/resume.release"
start_poll "$HOMES/resume" "hold|$marker|$release" resume
wait_for_file "$marker" || fail "fixture never reached the adapter"
mepoch=$(date +%s)
freeze_invocation "$marker"
echo "froze host $inner_host_pid and group $group_pid at $(date -u +%H:%M:%S)Z; invoke bound is ${BOUND_MS}ms"
sleep_until $(( mepoch + 7 ))
echo "resuming at $(date -u +%H:%M:%S)Z (~7s frozen, deadline overrun ~4s > 2000ms slack)"
resume_invocation; touch "$release"
wait_for_pid_exit "$poll_pid" 10 || fail "resumed invocation never completed"
wait "$poll_pid"; rc=$?; poll_pid=
echo "exit=$rc"
echo "--- stdout ---"; cat "$TMP/resume.out"
echo "--- stderr ---"; cat "$TMP/resume.err"
[ "$rc" -eq 0 ] || fail "resumed invocation did not succeed"
grep -q "resumed inside the grace" "$TMP/resume.out" || fail "result lost"
{
  echo "SCENARIO A: invocation frozen $(sleep 0)x across its invoke bound and resumed inside the bounded grace"
  echo "exit=$rc"; cat "$TMP/resume.out"; cat "$TMP/resume.err"
} > "$EVID/01-suspension-resume-inside-grace.txt"

echo; echo "== SCENARIO B: frozen invocation that never resumes work still dies after the grace =="
prepare_home "$HOMES/frozen-stall"
marker="$TMP/frozen.marker"
start_poll "$HOMES/frozen-stall" "stall|$marker" frozen
wait_for_file "$marker" || fail "fixture never reached the adapter"
mepoch=$(date +%s); freeze_invocation "$marker"
sleep_until $(( mepoch + 7 )); resume_invocation
wait_for_pid_exit "$poll_pid" 12 || fail "frozen invocation was never killed"
wait "$poll_pid"; rc=$?; poll_pid=
echo "exit=$rc"; echo "--- stdout (captured host-error evidence) ---"; cat "$TMP/frozen.out"
[ "$rc" -eq 70 ] || fail "expected host-error exit 70, got $rc: $(cat "$TMP/frozen.err")"
grep -q '"bound":"invoke"' "$TMP/frozen.out" || fail "no bound in evidence"
grep -q '"overrun_ms":' "$TMP/frozen.out" || fail "no overrun_ms in evidence"
cp "$TMP/frozen.out" "$EVID/02-frozen-kill-evidence.json"
cp "$TMP/frozen.err" "$EVID/02-frozen-kill-stderr.txt"

echo; echo "== SCENARIO C: genuine stall (no suspension) still dies at its bound with no grace =="
prepare_home "$HOMES/stall"
marker="$TMP/stall.marker"
start_poll "$HOMES/stall" "stall|$marker" stall
wait_for_file "$marker" || fail "fixture never reached the adapter"
t0=$(date +%s%N)
wait_for_pid_exit "$poll_pid" 15 || fail "stalled invocation outlived its bound"
wait "$poll_pid"; rc=$?; poll_pid=
t1=$(date +%s%N); elapsed_ms=$(( (t1 - t0) / 1000000 ))
echo "exit=$rc elapsed_since_adapter_reached=${elapsed_ms}ms"
echo "--- stdout (captured host-error evidence) ---"; cat "$TMP/stall.out"
[ "$rc" -eq 70 ] || fail "expected host-error exit 70, got $rc"
grep -q '"bound":"invoke"' "$TMP/stall.out" || fail "no bound in evidence"
if grep -q 'overrun_ms' "$TMP/stall.out"; then fail "a plain stall claimed a suspension overrun"; fi
[ "$elapsed_ms" -le 6000 ] || fail "a plain stall waited through a grace: ${elapsed_ms}ms"
cp "$TMP/stall.out" "$EVID/03-plain-stall-evidence.json"
echo "PLAIN_STALL_ELAPSED_MS=$elapsed_ms" > "$EVID/03-plain-stall-timing.txt"
cat "$TMP/stall.out" >> "$EVID/03-plain-stall-timing.txt"

# ---------- capture gate scenarios: real fm-procevent.sh + real capture.pl ----------
capture_case() { # <tag> <overrun1|absent> <overrun2|absent>
  local tag=$1 o1=$2 o2=$3 case_root="$TMP/capture-$1" home source evidence round
  home="$case_root/home"; source="boundary-$tag"
  mkdir -p "$case_root/user-home" "$case_root/code" "$home" "$case_root/claims"
  (
    export HOME="$case_root/user-home" XDG_STATE_HOME="$case_root/xdg"
    export FM_PROCEVENT_CLAIM_ROOT="$case_root/claims"
    export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10
    cp -R "$ROOT/bin" "$case_root/code/bin"
    cat > "$case_root/code/bin/fm-extension.mjs" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" process-event "*" source.poll "*)
    printf '%s\\n' "\${FM_SHIM_EVIDENCE:?FM_SHIM_EVIDENCE is required}"
    exit 70
    ;;
esac
exec "$ROOT/bin/fm-extension.mjs" "\$@"
SHIM
    chmod 0755 "$case_root/code/bin/fm-extension.mjs"
    FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-sleep \
      --trust-same-user-code --timeout-ms "$BOUND_MS" >/dev/null || fail "bind capture fixture"
    FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" register-extension ext-sleep "$source" \
      --config-ref boundary >/dev/null || fail "register $tag"
    inbox="$home/state/procevent-inbox"
    for round in 1 2; do
      local o=$o1; [ "$round" -eq 2 ] && o=$o2
      if [ "$o" = absent ]; then
        evidence='{"schema":"firstmate.process-event-extension-error.v1","extension_id":"org.example.sleep-deadlines","operation":"source.poll","code":"timeout","bound":"invoke"}'
      else
        evidence="{\"schema\":\"firstmate.process-event-extension-error.v1\",\"extension_id\":\"org.example.sleep-deadlines\",\"operation\":\"source.poll\",\"code\":\"timeout\",\"bound\":\"invoke\",\"overrun_ms\":$o}"
      fi
      if [ "$round" -eq 1 ]; then
        FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" start "$source" \
          > "$case_root/start.out" 2>&1 || fail "$tag start: $(cat "$case_root/start.out")"
      else
        FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" reconcile \
          > "$case_root/reconcile.out" 2>&1 || fail "$tag reconcile: $(cat "$case_root/reconcile.out")"
      fi
      # settle
      local i runner
      for i in $(seq 1 600); do
        runner=$(sed -n '2p' "$case_root/claims/$source.claim" 2>/dev/null || true)
        if [ ! -e "$home/state/procevent/$source.runner" ] && [ -z "$runner" ]; then break; fi
        sleep 0.05
      done
      echo "--- $tag round $round: inbox after round ---"
      ls -1 "$inbox" | sort
    done
    echo "--- $tag stored result (.1.result) ---"
    cat "$inbox/$source.1.result"
    if [ -e "$inbox/$source.2.result" ]; then
      echo "--- $tag second capture (.2.result) ---"
      cat "$inbox/$source.2.result"
    fi
    echo "--- $tag host-error sidecar identity hash lines ---"
    for f in "$inbox"/"$source".*.host-error; do [ -e "$f" ] || continue; echo "sidecar $(basename "$f"):"; cat "$f"; done
    echo "RESULT_COUNT=$(compgen -G "$inbox/$source"'.*.result' | wc -l | tr -d ' ')"
    echo "SIDECAR_COUNT=$(compgen -G "$inbox/$source"'.*.host-error' | wc -l | tr -d ' ')"
  ) 2>&1
}

echo; echo "== SCENARIO D: two suspension kills differing only in overrun_ms coalesce (4000ms, then 4100ms) =="
capture_case drift 4000 4100 | tee "$EVID/04-capture-coalescing-drift.txt"

echo; echo "== SCENARIO E: plain timeout then suspension timeout stay distinct captures =="
capture_case mixed absent 4000 | tee "$EVID/05-capture-presence-distinct.txt"

echo; echo "== SCENARIO F: overrun beyond the capture gate cap keeps no host-error identity =="
capture_case beyond 10000000000000000 10000000000000000 | tee "$EVID/06-capture-overrun-cap.txt"

echo "ALL LIVE DEMO SCENARIOS COMPLETED"
