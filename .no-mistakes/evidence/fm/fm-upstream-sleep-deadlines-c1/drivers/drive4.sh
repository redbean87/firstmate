#!/usr/bin/env bash
# Independent live drive of the guards around the suspension grace:
#   K. a deadline that fires only slightly late (inside the 2 s slack, i.e.
#      not a suspension) gets no grace and still dies at its bound;
#   L. the legacy four-key host error still coalesces through the real capture
#      gate (the change must not disturb the pre-existing evidence shape);
#   M. a five-key envelope whose extra key is not a valid bound is refused, so
#      the gate stays an exact shape and not a permissive "one extra key".
set -u
WT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M6A1ZFAW2KVYR5BNMBZ5E7ND
. "$WT/tests/lib.sh"

HOST="$ROOT/bin/fm-extension.mjs"
BOUND=3000
TMP_ROOT_RAW=$(fm_test_tmproot fm-live-slack)
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

now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }
wait_for_file() {
  local file=$1 limit=${2:-300}
  for _ in $(seq 1 "$limit"); do [ -s "$file" ] && return 0; sleep 0.02; done
  return 1
}
wait_for_pid_exit() {
  local pid=$1 limit=$(( $2 * 20 )) attempt
  for ((attempt = 0; attempt < limit; attempt++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

PACKAGE="$PACKAGES/slack-live"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.slack-live",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-slack"]}
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

prepare_home() { # <home>
  local home=$1 resolution
  mkdir -p "$home"
  FM_HOME="$home" "$HOST" bind "$PACKAGE" --adapter ext-slack \
    --trust-same-user-code --timeout-ms "$BOUND" >/dev/null \
    || fail "cannot bind the slack-live fixture"
  resolution=$(FM_HOME="$home" "$HOST" resolve-process-event ext-slack) \
    || fail "cannot resolve the slack-live fixture"
  IFS=$'\t' read -r r_schema r_id r_version r_cap r_package r_binding r_extra <<< "$resolution"
  [ "$r_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$r_extra" ] \
    || fail "resolution record is malformed: $resolution"
}

# --- K: slight lateness is not a suspension ---------------------------------
case_slight_lateness_is_not_suspension() {
  local home="$TMP_ROOT/home-slack" marker="$TMP_ROOT/slack.marker"
  local started entry barrier resume_at killed_at rc=0 output overrun_freeze
  prepare_home "$home"
  started=$(now_ms)
  FM_HOME="$home" "$HOST" process-event ext-slack source.poll \
    --source-id slack-source --config-ref "stall|$marker" \
    --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" \
    --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP_ROOT/slack.out" 2> "$TMP_ROOT/slack.err" &
  poll_pid=$!
  wait_for_file "$marker" || fail "slack fixture never reached the adapter"
  entry=$(sed -n '1p' "$marker")
  barrier=$(ps -o pgid= -p "$entry" | tr -d '[:space:]')
  inner_host_pid=$(ps -o ppid= -p "$barrier" | tr -d '[:space:]')
  group_pid=$barrier
  case "$inner_host_pid" in ''|*[!0-9]*) fail "cannot locate the extension host" ;; esac
  kill -STOP "$inner_host_pid"
  kill -STOP -"$group_pid"
  # Resume ~1.2 s late: past the 3 s bound but inside the 2 s suspension slack.
  while [ $(( $(now_ms) - started )) -lt 4300 ]; do sleep 0.05; done
  resume_at=$(now_ms)
  kill -CONT "$inner_host_pid" 2>/dev/null || true
  kill -CONT -"$group_pid" 2>/dev/null || true
  wait_for_pid_exit "$poll_pid" 15 || fail "a slightly late deadline never killed the invocation"
  killed_at=$(now_ms)
  wait "$poll_pid"; rc=$?
  poll_pid=
  group_pid=; inner_host_pid=
  output=$(cat "$TMP_ROOT/slack.out")
  echo "SLACK-EVIDENCE $output"
  [ "$rc" -eq 70 ] || fail "slightly late deadline exited $rc instead of 70: $(cat "$TMP_ROOT/slack.err")"
  assert_contains "$output" '"bound":"invoke"' "the bound was not named"
  assert_not_contains "$output" "overrun_ms" "a sub-slack lateness was treated as a suspension"
  [ $(( killed_at - resume_at )) -lt 1500 ] \
    || fail "a sub-slack lateness waited $(( killed_at - resume_at ))ms after resume instead of dying at once"
  echo "LIVE-PASS slight-lateness-is-not-suspension rc=$rc post_resume_ms=$(( killed_at - resume_at ))"
}

# --- L/M: the capture gate's exact evidence shapes --------------------------
shape_case() { # <tag> <evidence-json> <expect-host-error yes|no>
  set -u
  local tag=$1 evidence=$2 expect_marker=$3
  local case_root="$TMP_ROOT/shape-$tag" home="$TMP_ROOT/shape-$tag/home" source="shape-$tag"
  local claims="$TMP_ROOT/shape-$tag/claims" inbox count host_errors round
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
  FM_HOME="$home" "$ROOT/bin/fm-extension.mjs" bind "$PACKAGE" --adapter ext-slack \
    --trust-same-user-code --timeout-ms "$BOUND" >/dev/null || fail "cannot bind $tag fixture"
  fm_test_track_procevent_home "$home" "$claims"
  export FM_PROCEVENT_CLAIM_ROOT="$claims"
  export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10
  FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" register-extension ext-slack "$source" \
    --config-ref boundary >/dev/null || fail "cannot register $tag fixture"
  inbox="$home/state/procevent-inbox"
  for round in 1 2; do
    if [ "$round" -eq 1 ]; then
      FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" start "$source" \
        > "$case_root/start.out" 2>&1 || fail "$tag start failed: $(cat "$case_root/start.out")"
    else
      FM_SHIM_EVIDENCE="$evidence" FM_HOME="$home" "$case_root/code/bin/fm-procevent.sh" reconcile \
        > "$case_root/reconcile.out" 2>&1 || fail "$tag reconcile failed: $(cat "$case_root/reconcile.out")"
    fi
    for _ in $(seq 1 600); do
      [ -z "$(sed -n '2p' "$claims/$source.claim" 2>/dev/null || true)" ] \
        && [ ! -e "$home/state/procevent/$source.runner" ] && break
      sleep 0.05
    done
    count=$(compgen -G "$inbox/$source.*.result" 2>/dev/null | wc -l | tr -d ' ')
    echo "SHAPE-$tag ROUND-$round captures=$count"
  done
  host_errors=$(compgen -G "$inbox/$source.*.host-error" 2>/dev/null | wc -l | tr -d ' ')
  echo "SHAPE-$tag captures=$count host_error_sidecars=$host_errors"
  if [ "$expect_marker" = yes ]; then
    [ "$count" -eq 1 ] || fail "$tag retry allocated $count captures instead of coalescing"
    [ "$host_errors" -eq 1 ] || fail "$tag lost host-error identity"
  else
    [ "$count" -eq 2 ] || fail "$tag coalesced unexpectedly ($count captures)"
    [ "$host_errors" -eq 0 ] || fail "$tag was accepted as host-error identity"
  fi
}

case_legacy_shape() {
  shape_case legacy '{"schema":"firstmate.process-event-extension-error.v1","extension_id":"org.example.slack-live","operation":"source.poll","code":"timeout"}' yes
  echo "LIVE-PASS legacy-four-key-envelope-still-coalesces"
}

case_extra_key_refused() {
  shape_case extra '{"schema":"firstmate.process-event-extension-error.v1","extension_id":"org.example.slack-live","operation":"source.poll","code":"timeout","unexpected":"value"}' no
  echo "LIVE-PASS unexpected-extra-key-refused-without-host-error-identity"
}

case_slight_lateness_is_not_suspension || { echo "LIVE-FAIL slight_lateness"; exit 1; }
case_legacy_shape || { echo "LIVE-FAIL legacy"; exit 1; }
case_extra_key_refused || { echo "LIVE-FAIL extra"; exit 1; }
echo "FM_LIVE_COMPLETE"
