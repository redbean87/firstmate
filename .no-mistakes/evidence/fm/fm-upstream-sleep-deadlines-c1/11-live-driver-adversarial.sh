#!/usr/bin/env bash
# Adversarial live checks for the sleep-aware deadline guard:
#  G: a pause that ends WITHIN the 2s slack still kills at the bound (documented limit)
#  H: the bounded grace is granted at most once (a second suspension gets none)
set -u
ROOT=${1:?worktree root}; EVID=${2:?evidence dir}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-demo2.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
PACKAGES="$TMP/packages"; HOMES="$TMP/homes"; mkdir -p "$PACKAGES" "$HOMES"
poll_pid=; group_pid=; inner_host_pid=; BOUND_MS=3000
cleanup() {
  [ -z "$group_pid" ] || kill -CONT -"$group_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -CONT "$inner_host_pid" 2>/dev/null || true
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -TERM "$inner_host_pid" 2>/dev/null || true
  [ -z "$group_pid" ] || kill -TERM -"$group_pid" 2>/dev/null || true
  sleep 0.3; chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

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
if verb != "invoke": sys.exit(8)
mode = request.get("input", {}).get("config_ref", "")
if mode.startswith("stall|"):
    _, marker = mode.split("|", 1)
    with open(marker, "w", encoding="utf-8") as out: out.write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(1)
sys.exit(6)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

wait_for_file() { local f=$1 i; for i in $(seq 1 300); do [ -s "$f" ] && return 0; sleep 0.05; done; return 1; }
wait_for_pid_exit() { local p=$1 max=$(( $2 * 20 )) i; for ((i=0;i<max;i++)); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.05; done; return 1; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
sleep_ms_until() { python3 -c 'import sys,time;t=int(sys.argv[1])/1000.0;d=t-time.time()
if d>0: time.sleep(d)' "$1"; }

prepare_home() { home=$1; mkdir -p "$home"
  FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-sleep \
    --trust-same-user-code --timeout-ms "$BOUND_MS" >/dev/null || fail "bind"
  resolution=$(FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" resolve-process-event ext-sleep) || fail "resolve"
  IFS=$'\t' read -r _ r_id r_version r_cap r_package r_binding _ <<< "$resolution"; }
start_poll() { FM_HOME="$1" "$ROOT/bin/fm-extension.mjs" process-event ext-sleep source.poll \
    --source-id sleep-source --config-ref "$2" --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP/$3.out" 2> "$TMP/$3.err" & poll_pid=$!; }
freeze_invocation() { local ep bp
  ep=$(sed -n '1p' "$1"); case "$ep" in ''|*[!0-9]*) fail "marker pid" ;; esac
  bp=$(ps -o pgid= -p "$ep" | tr -d '[:space:]'); case "$bp" in ''|*[!0-9]*) fail "pgid" ;; esac
  group_pid=$bp; inner_host_pid=$(ps -o ppid= -p "$bp" | tr -d '[:space:]')
  case "$inner_host_pid" in ''|*[!0-9]*) fail "host pid" ;; esac
  kill -STOP "$inner_host_pid"; kill -STOP -"$group_pid"; }
pause_invocation() { kill -STOP "$inner_host_pid" 2>/dev/null || true; kill -STOP -"$group_pid" 2>/dev/null || true; }
resume_invocation() { kill -CONT -"$group_pid" 2>/dev/null || true; kill -CONT "$inner_host_pid" 2>/dev/null || true; }

echo "== SCENARIO G: a pause ending INSIDE the 2s slack still kills at the bound (documented limit) =="
attempt=0; g_ok=0
while [ "$attempt" -lt 3 ] && [ "$g_ok" -eq 0 ]; do
  attempt=$((attempt + 1)); target_ms=$(( 3000 + 1200 + (attempt - 1) * 300 ))
  prepare_home "$HOMES/subslack$attempt"; marker="$TMP/g.marker"; rm -f "$marker"
  start_poll "$HOMES/subslack$attempt" "stall|$marker" g
  wait_for_file "$marker" || fail "fixture never reached the adapter"
  # The host's invoke timer starts a few hundred ms before the adapter marker.
  anchor=$(now_ms); freeze_invocation "$marker"
  # Resume so the deadline callback runs well inside the 2000ms slack.
  sleep_ms_until $(( anchor + target_ms - 400 )); resume_invocation
  wait_for_pid_exit "$poll_pid" 8 || fail "sub-slack pause was not killed at the bound"
  wait "$poll_pid"; rc=$?; poll_pid=
  echo "attempt $attempt (resume ${target_ms}ms past invoke start): exit=$rc"
  cat "$TMP/g.out"; cat "$TMP/g.err"
  [ "$rc" -eq 70 ] || fail "sub-slack pause exited $rc instead of the captured host-error status"
  grep -q '"code":"timeout"' "$TMP/g.out" || fail "sub-slack pause did not produce timeout evidence"
  grep -q '"bound":"invoke"' "$TMP/g.out" || fail "sub-slack pause evidence did not name its bound"
  if grep -q 'overrun_ms' "$TMP/g.out" && grep -q '"overrun_ms":[0-9]' "$TMP/g.out"; then
    echo "attempt $attempt landed beyond the slack (a grace was granted); retrying with a shorter pause"
    continue
  fi
  g_ok=1
  cp "$TMP/g.out" "$EVID/07-subslack-still-kills-evidence.json"
  { echo "Scenario G: pause ending inside the 2s slack still kills at the bound, no grace, no overrun_ms";
    echo "attempt $attempt resume offset ${target_ms}ms past invoke start"; echo "exit=$rc"; cat "$TMP/g.out"; } \
    > "$EVID/07-subslack-still-kills.txt"
done
[ "$g_ok" -eq 1 ] || fail "every attempt overran beyond the slack; the within-slack limit was not exercised"

echo; echo "== SCENARIO H: the bounded grace is granted at most once =="
prepare_home "$HOMES/onegrace"; marker="$TMP/h.marker"
start_poll "$HOMES/onegrace" "stall|$marker" h
wait_for_file "$marker" || fail "fixture never reached the adapter"
anchor=$(now_ms); freeze_invocation "$marker"
sleep_ms_until $(( anchor + 7000 )); resume_invocation
# The first late deadline arms the single 5s grace. Freeze again across it.
sleep 0.05; pause_invocation
echo "re-froze the invocation across the armed grace at $(date -u +%H:%M:%S)Z for 8s"
sleep 8; anchor2=$(now_ms); resume_invocation
wait_for_pid_exit "$poll_pid" 5 || fail "a second suspension was granted a second grace"
wait "$poll_pid"; rc=$?; poll_pid=
settle_ms=$(( $(now_ms) - anchor2 ))
echo "exit=$rc, seconds-to-exit after the second resume=${settle_ms}ms"
cat "$TMP/h.out"; cat "$TMP/h.err"
[ "$rc" -eq 70 ] || fail "second suspension exited $rc instead of the captured host-error status"
grep -q '"overrun_ms":' "$TMP/h.out" || fail "the single grace kill lost its measured overrun"
overrun=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["overrun_ms"])' "$TMP/h.out")
echo "recorded overrun_ms=$overrun (from the first suspension, not the second)"
[ "$overrun" -lt 6000 ] || fail "the recorded overrun $overrun ms shows a second grace measurement"
[ "$settle_ms" -lt 3000 ] || fail "the second suspension bought another grace (${settle_ms}ms to exit)"
cp "$TMP/h.out" "$EVID/08-single-grace-evidence.json"
{ echo "Scenario H: the bounded grace is granted at most once";
  echo "exit=$rc seconds-to-exit-after-second-resume=$(( settle_ms / 1000 ))"; cat "$TMP/h.out"; } \
  > "$EVID/08-single-grace.txt"
echo "ALL ADVERSARIAL LIVE SCENARIOS COMPLETED"
