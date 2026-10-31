#!/usr/bin/env bash
# Independent live drive of the capture side:
#   H. a real suspension-driven invocation killed by the real host through the
#      real process-event pipeline still records host-error identity with
#      overrun_ms (the 6-key deadline envelope is accepted by the capture gate);
#   I/J. the gate's overrun_ms range boundary at the top of the host's own
#      safe-integer emission (MAX_SAFE_INTEGER accepted, a 17-digit value
#      rejected). The overrun value is injected because no live run can
#      manufacture a 9e15 ms sleep; the pipeline under test is the real one.
set -u
WT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M6A1ZFAW2KVYR5BNMBZ5E7ND
. "$WT/tests/lib.sh"

HOST="$ROOT/bin/fm-extension.mjs"
BOUND=3000
TMP_ROOT_RAW=$(fm_test_tmproot fm-live-capture)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
PACKAGES="$TMP_ROOT/packages"
mkdir -p "$PACKAGES"
export HOME="$TMP_ROOT/user-home" XDG_STATE_HOME="$TMP_ROOT/xdg"
mkdir -p "$HOME"

poll_pid=
group_pid=
inner_host_pid=
cleanup_all() {
  [ -z "$group_pid" ] || kill -CONT -"$group_pid" 2>/dev/null || true
  [ -z "$inner_host_pid" ] || kill -CONT "$inner_host_pid" 2>/dev/null || true
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
  [ -z "$group_pid" ] || kill -TERM -"$group_pid" 2>/dev/null || true
  chmod -R u+w "$TMP_ROOT_RAW" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

wait_for_file() {
  local file=$1 limit=${2:-300}
  for _ in $(seq 1 "$limit"); do [ -s "$file" ] && return 0; sleep 0.02; done
  return 1
}

PACKAGE="$PACKAGES/capture-live"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.capture-live",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-capture"]}
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
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

if verb == "handshake":
    raw({
        "schema": "firstmate.extension-handshake-response.v1",
        "request_id": request["request_id"],
        "extension_id": manifest["id"],
        "extension_version": manifest["version"],
        "host_protocol": 1,
        "capability": "process-event-adapter",
        "capability_version": 1,
        "adapter_names": request["capability"]["adapter_names"],
    })
    sys.exit(0)
if verb != "invoke":
    sys.exit(8)
mode = request.get("input", {}).get("config_ref", "")
if mode.startswith("stall|"):
    _, marker = mode.split("|", 1)
    with open(marker, "w", encoding="utf-8") as output:
        output.write(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
sys.exit(6)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

# --- H: suspension-driven kill through the real pipeline ---------------------
case_pipeline_suspension_capture() {
  local home="$TMP_ROOT/home-susp" claims="$TMP_ROOT/claims-susp" source=live-susp
  local marker="$TMP_ROOT/susp.marker" entry barrier started rc=0 results host_errors result
  mkdir -p "$home" "$claims"
  FM_PROCEVENT_CLAIM_ROOT="$claims" FM_HOME="$home" "$HOST" bind "$PACKAGE" \
    --adapter ext-capture --trust-same-user-code --timeout-ms "$BOUND" >/dev/null \
    || fail "cannot bind the capture-live fixture"
  fm_test_track_procevent_home "$home" "$claims"
  export FM_PROCEVENT_CLAIM_ROOT="$claims"
  export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=20
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" register-extension ext-capture "$source" \
    --config-ref "stall|$marker" >/dev/null || fail "cannot register the suspension source"
  started=$(date +%s)
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$source" \
    > "$TMP_ROOT/susp-start.out" 2>&1 &
  poll_pid=$!
  wait_for_file "$marker" 400 || fail "the suspension fixture never reached the adapter"
  entry=$(sed -n '1p' "$marker")
  case "$entry" in ''|*[!0-9]*) fail "marker has no pid" ;; esac
  barrier=$(ps -o pgid= -p "$entry" | tr -d '[:space:]')
  inner_host_pid=$(ps -o ppid= -p "$barrier" | tr -d '[:space:]')
  group_pid=$barrier
  case "$inner_host_pid" in ''|*[!0-9]*) fail "cannot locate the extension host" ;; esac
  kill -STOP "$inner_host_pid"
  kill -STOP -"$group_pid"
  sleep 7
  kill -CONT -"$group_pid" 2>/dev/null || true
  kill -CONT "$inner_host_pid" 2>/dev/null || true
  wait "$poll_pid"; rc=$?
  poll_pid=
  group_pid=; inner_host_pid=
  local deadline=$(( started + 40 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -n "$(compgen -G "$home/state/procevent-inbox/$source.*.result" 2>/dev/null)" ] && break
    sleep 0.1
  done
  results=$(compgen -G "$home/state/procevent-inbox/$source.*.result" 2>/dev/null | wc -l | tr -d ' ')
  host_errors=$(compgen -G "$home/state/procevent-inbox/$source.*.host-error" 2>/dev/null | wc -l | tr -d ' ')
  echo "PIPELINE-SUSPENSION-START $(cat "$TMP_ROOT/susp-start.out")"
  [ "$results" -eq 1 ] || fail "the suspension kill published $results results, expected 1"
  [ "$host_errors" -eq 1 ] || fail "the suspension kill lost host-error identity ($host_errors sidecars)"
  result=$(compgen -G "$home/state/procevent-inbox/$source.*.result" | head -1)
  echo "PIPELINE-SUSPENSION-RESULT $(cat "$result")"
  assert_contains "$(cat "$result")" '"code":"timeout"' "captured suspension kill lost the timeout code"
  assert_contains "$(cat "$result")" '"bound":"invoke"' "captured suspension kill lost the bound name"
  assert_contains "$(cat "$result")" '"overrun_ms":' "captured suspension kill lost the overrun"
  echo "LIVE-PASS pipeline-suspension-capture results=$results host_error_sidecars=$host_errors"
}

# --- I/J: the capture gate's overrun_ms range boundary -----------------------
overrun_case() { # <tag> <overrun-ms> <expect-host-error yes|no> <expected captures>
  set -u
  local tag=$1 overrun=$2 expect_marker=$3 expect_count=$4
  local case_root="$TMP_ROOT/overrun-$tag" home source claims evidence inbox
  local round count
  home="$case_root/home"
  source="boundary-$tag"
  claims="$case_root/claims"
  mkdir -p "$case_root/code" "$home" "$claims"
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
  FM_HOME="$home" "$HOST" bind "$PACKAGE" --adapter ext-capture \
    --trust-same-user-code --timeout-ms "$BOUND" >/dev/null || fail "cannot bind $tag fixture"
  fm_test_track_procevent_home "$home" "$claims"
  export FM_PROCEVENT_CLAIM_ROOT="$claims"
  export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10
  FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" register-extension ext-capture "$source" \
    --config-ref boundary >/dev/null || fail "cannot register $tag fixture"
  evidence=$(printf '{"schema":"firstmate.process-event-extension-error.v1","extension_id":"org.example.capture-live","operation":"source.poll","code":"timeout","bound":"invoke","overrun_ms":%s}' "$overrun")
  inbox="$home/state/procevent-inbox"
  for round in 1 2; do
    if [ "$round" -eq 1 ]; then
      FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" start "$source" \
        > "$case_root/start.out" 2>&1 || fail "$tag start failed: $(cat "$case_root/start.out")"
    else
      FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" reconcile \
        > "$case_root/reconcile.out" 2>&1 || fail "$tag reconcile failed: $(cat "$case_root/reconcile.out")"
      assert_contains "$(cat "$case_root/reconcile.out")" 'started=1' "$tag retry did not start a recovery poll"
    fi
    for _ in $(seq 1 600); do
      [ -z "$(sed -n '2p' "$claims/$source.claim" 2>/dev/null || true)" ] \
        && [ ! -e "$home/state/procevent/$source.runner" ] && break
      sleep 0.05
    done
    count=$(compgen -G "$inbox/$source.*.result" 2>/dev/null | wc -l | tr -d ' ')
    echo "OVERRUN-$tag ROUND-$round captures=$count"
    if [ "$expect_marker" = yes ]; then
      [ "$count" -eq 1 ] || fail "$tag round $round produced $count captures instead of coalescing"
    else
      [ "$count" -eq "$round" ] || fail "$tag round $round produced $count captures, expected $round"
    fi
  done
  local host_errors
  host_errors=$(compgen -G "$inbox/$source.*.host-error" 2>/dev/null | wc -l | tr -d ' ')
  echo "OVERRUN-$tag captures=$count host_error_sidecars=$host_errors"
  if [ "$expect_marker" = yes ]; then
    [ "$host_errors" -eq 1 ] || fail "$tag lost host-error identity"
    [ "$expect_count" -eq 1 ] || fail "$tag must coalesce to one capture"
  else
    [ "$host_errors" -eq 0 ] || fail "$tag was accepted as host-error identity beyond the gate cap"
    [ "$expect_count" -eq 2 ] || fail "$tag must not coalesce"
  fi
}

case_overrun_at_gate_cap() { overrun_case cap 9007199254740991 yes 1; echo "LIVE-PASS overrun-at-gate-cap coalesced with host-error identity"; }
case_overrun_beyond_gate_cap() { overrun_case beyond 10000000000000000 no 2; echo "LIVE-PASS overrun-beyond-gate-cap rejected without host-error identity"; }

case_pipeline_suspension_capture || { echo "LIVE-FAIL pipeline_suspension_capture"; exit 1; }
case_overrun_at_gate_cap || { echo "LIVE-FAIL overrun_at_gate_cap"; exit 1; }
case_overrun_beyond_gate_cap || { echo "LIVE-FAIL overrun_beyond_gate_cap"; exit 1; }
echo "FM_LIVE_COMPLETE"
