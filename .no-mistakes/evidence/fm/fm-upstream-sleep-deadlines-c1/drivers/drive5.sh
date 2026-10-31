#!/usr/bin/env bash
# Live drive of the launch-ready bound's captured evidence:
#   N. a launch-ready wait frozen past its bound and never satisfied inside its
#      grace must be killed after exactly one grace, and the captured host error
#      must name bound "launch-ready" with the measured overrun, so the capture
#      gate keeps host-error identity for that bound name too.
set -u
WT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M6A1ZFAW2KVYR5BNMBZ5E7ND
. "$WT/tests/lib.sh"

TMP_ROOT_RAW=$(fm_test_tmproot fm-live-launch-fail)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
PACKAGES="$TMP_ROOT/packages"
CODE="$TMP_ROOT/code"
mkdir -p "$PACKAGES" "$CODE"
export HOME="$TMP_ROOT/user-home" XDG_STATE_HOME="$TMP_ROOT/xdg"
mkdir -p "$HOME"

poll_pid=
host_pid=
cleanup_all() {
  [ -z "$host_pid" ] || kill -CONT "$host_pid" 2>/dev/null || true
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
  chmod -R u+w "$TMP_ROOT_RAW" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

PACKAGE="$PACKAGES/launch-fail"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.launch-fail",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-lfail"]}
  ],
  "required_consents": []
}
JSON
chmod 0644 "$PACKAGE/firstmate-extension.json"
cat > "$PACKAGE/entrypoint.py" <<'PY'
#!/usr/bin/env python3
import json, sys
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
sys.exit(7)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

# Copy the product tree and delay only the source.poll invocation's barrier, so
# the launch-ready wait is frozen past its bound and never satisfied inside the
# grace while the handshake launches stay on their normal path.
cp -R "$ROOT/bin" "$CODE/bin"
mv "$CODE/bin/fm-extension-launch-barrier.mjs" "$CODE/bin/fm-extension-launch-barrier.original.mjs"
cat > "$CODE/bin/fm-extension-launch-barrier.mjs" <<'JS'
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
if (process.argv[9] === "invoke") {
  writeFileSync(fileURLToPath(new URL("./launch-delay.marker", import.meta.url)), `${process.pid}\n`);
  await new Promise((resolve) => setTimeout(resolve, 15000));
}
await import("./fm-extension-launch-barrier.original.mjs");
JS
MARKER="$CODE/bin/launch-delay.marker"

home="$TMP_ROOT/home"
claims="$TMP_ROOT/claims"
source=launch-fail
mkdir -p "$home" "$claims"
FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-lfail \
  --trust-same-user-code --timeout-ms 60000 >/dev/null || fail "cannot bind the launch-fail fixture"
fm_test_track_procevent_home "$home" "$claims"
export FM_PROCEVENT_CLAIM_ROOT="$claims"
export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=20
FM_HOME="$home" "$CODE/bin/fm-procevent.sh" register-extension ext-lfail "$source" \
  --config-ref good >/dev/null || fail "cannot register the launch-fail source"

start_secs=$EPOCHSECONDS
FM_HOME="$home" "$CODE/bin/fm-procevent.sh" start "$source" \
  > "$TMP_ROOT/start.out" 2>&1 &
poll_pid=$!
while [ "$(( EPOCHSECONDS - start_secs ))" -lt 15 ]; do
  [ -s "$MARKER" ] && break
done
[ -s "$MARKER" ] || fail "the delayed invoke barrier never started"
barrier_pid=$(sed -n '1p' "$MARKER")
host_pid=$(ps -o ppid= -p "$barrier_pid" | tr -d '[:space:]')
case "$host_pid" in ''|*[!0-9]*) fail "cannot locate the extension host" ;; esac
kill -STOP "$host_pid"
sleep 8
kill -CONT "$host_pid"
host_pid=
echo "resumed the frozen host; the delayed barrier cannot publish readiness inside the grace"

inbox="$home/state/procevent-inbox"
deadline=$(( EPOCHSECONDS + 40 ))
while [ "$EPOCHSECONDS" -lt "$deadline" ]; do
  [ -n "$(compgen -G "$inbox/$source.*.result" 2>/dev/null)" ] && break
  sleep 0.1
done
wait "$poll_pid" 2>/dev/null; poll_pid=
results=$(compgen -G "$inbox/$source.*.result" 2>/dev/null | wc -l | tr -d ' ')
host_errors=$(compgen -G "$inbox/$source.*.host-error" 2>/dev/null | wc -l | tr -d ' ')
result=$(compgen -G "$inbox/$source.*.result" 2>/dev/null | head -1)
echo "LAUNCH-FAIL-START $(cat "$TMP_ROOT/start.out")"
[ -n "$result" ] || fail "the launch-ready failure produced no captured result"
echo "LAUNCH-FAIL-RESULT $(cat "$result")"
[ "$results" -eq 1 ] || fail "expected one captured result, got $results"
[ "$host_errors" -eq 1 ] || fail "the launch-ready failure lost host-error identity ($host_errors sidecars)"
assert_contains "$(cat "$result")" '"bound":"launch-ready"' "the captured failure did not name the launch-ready bound"
assert_contains "$(cat "$result")" '"overrun_ms":' "the suspension-driven launch failure lost its overrun"
overrun=$(node -e 'const fs=require("fs");const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(String(v.overrun_ms))' "$result") \
  || fail "captured failure is not JSON"
case "$overrun" in ''|*[!0-9]*) fail "overrun is not numeric: $overrun" ;; esac
[ "$overrun" -gt 2000 ] || fail "overrun ${overrun}ms does not exceed the suspension slack"
echo "LIVE-PASS launch-ready-failure-captured results=$results host_error_sidecars=$host_errors overrun_ms=$overrun"
echo "FM_LIVE_COMPLETE"
