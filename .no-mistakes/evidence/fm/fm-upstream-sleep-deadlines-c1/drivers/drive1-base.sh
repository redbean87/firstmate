#!/usr/bin/env bash
# Independent live drive of the extension deadline change against the real
# product CLI ($ROOT/bin/fm-extension.mjs and bin/fm-procevent.sh).
set -u
WT=/tmp/fm-base
. "$WT/tests/lib.sh"

HOST="$ROOT/bin/fm-extension.mjs"
BOUND=3000
TMP_ROOT_RAW=$(fm_test_tmproot fm-live-sleep)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
PACKAGES="$TMP_ROOT/packages"
HOMES="$TMP_ROOT/homes"
mkdir -p "$PACKAGES" "$HOMES"

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

PACKAGE="$PACKAGES/sleep-live"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.live-sleep",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-live"]}
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
if mode == "good":
    raw({
        "schema": "firstmate.extension-response.v1",
        "request_id": request["request_id"],
        "ok": True,
        "result": {"status": "result", "output": "healthy invocation result\n"},
        "error": None,
    })
    sys.exit(0)
if mode.startswith("hold|"):
    _, marker, release = mode.split("|", 2)
    with open(marker, "w", encoding="utf-8") as output:
        output.write(f"{os.getpid()}\n")
    while not os.path.exists(release):
        time.sleep(0.01)
    raw({
        "schema": "firstmate.extension-response.v1",
        "request_id": request["request_id"],
        "ok": True,
        "result": {"status": "result", "output": "resumed inside the grace\n"},
        "error": None,
    })
    sys.exit(0)
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

wait_for_file() {
  local file=$1
  for _ in $(seq 1 300); do
    [ -s "$file" ] && return 0
    sleep 0.05
  done
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

now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

prepare_home() {
  local home=$1 resolution
  mkdir -p "$home"
  FM_HOME="$home" "$HOST" bind "$PACKAGE" --adapter ext-live \
    --trust-same-user-code --timeout-ms "$BOUND" >/dev/null \
    || fail "cannot bind the live-sleep fixture"
  resolution=$(FM_HOME="$home" "$HOST" resolve-process-event ext-live) \
    || fail "cannot resolve the live-sleep fixture"
  IFS=$'\t' read -r r_schema r_id r_version r_cap r_package r_binding r_extra <<< "$resolution"
  [ "$r_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$r_extra" ] \
    || fail "resolution record is malformed: $resolution"
}

start_poll() {
  FM_HOME="$1" "$HOST" process-event ext-live source.poll \
    --source-id live-source --config-ref "$2" \
    --expect-extension "$r_id" --expect-version "$r_version" \
    --expect-capability-version "$r_cap" \
    --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
    > "$TMP_ROOT/$3.out" 2> "$TMP_ROOT/$3.err" &
  poll_pid=$!
}

freeze_invocation() {
  local entry_pid barrier_pid
  entry_pid=$(sed -n '1p' "$1")
  case "$entry_pid" in ''|*[!0-9]*) fail "marker has no pid: $1" ;; esac
  barrier_pid=$(ps -o pgid= -p "$entry_pid" | tr -d '[:space:]')
  case "$barrier_pid" in ''|*[!0-9]*) fail "cannot locate invocation group" ;; esac
  group_pid=$barrier_pid
  inner_host_pid=$(ps -o ppid= -p "$group_pid" | tr -d '[:space:]')
  case "$inner_host_pid" in ''|*[!0-9]*) fail "cannot locate invocation host" ;; esac
  kill -STOP "$inner_host_pid"
  kill -STOP -"$group_pid"
}

resume_invocation() {
  [ -n "$group_pid" ] && kill -CONT -"$group_pid" 2>/dev/null || true
  [ -n "$inner_host_pid" ] && kill -CONT "$inner_host_pid" 2>/dev/null || true
}

# --- A: healthy invocation is untouched by the deadline work ------------------
case_healthy() {
  local home="$HOMES/healthy" started elapsed rc=0
  prepare_home "$home"
  started=$(now_ms)
  start_poll "$home" good healthy
  wait_for_pid_exit "$poll_pid" 10 || fail "healthy invocation never finished"
  wait "$poll_pid"; rc=$?
  poll_pid=
  elapsed=$(( $(now_ms) - started ))
  [ "$rc" -eq 0 ] || fail "healthy invocation failed rc=$rc: $(cat "$TMP_ROOT/healthy.err")"
  assert_contains "$(cat "$TMP_ROOT/healthy.out")" "healthy invocation result" "healthy result was lost"
  [ "$elapsed" -lt 2000 ] || fail "healthy invocation took ${elapsed}ms"
  assert_not_contains "$(cat "$TMP_ROOT/healthy.out")" "bound" "healthy invocation produced deadline evidence"
  echo "LIVE-PASS healthy-invocation rc=$rc elapsed_ms=$elapsed"
}

# --- B: genuine stall still dies at its bound with stable evidence ------------
case_stall() {
  local home="$HOMES/stall" marker="$TMP_ROOT/stall.marker" started elapsed rc=0 output
  prepare_home "$home"
  started=$(now_ms)
  start_poll "$home" "stall|$marker" stall
  wait_for_file "$marker" || fail "stall fixture never reached the adapter"
  wait_for_pid_exit "$poll_pid" 15 || fail "genuine stall outlived its bound"
  wait "$poll_pid"; rc=$?
  poll_pid=
  elapsed=$(( $(now_ms) - started ))
  output=$(cat "$TMP_ROOT/stall.out")
  [ "$rc" -eq 70 ] || fail "stall exited $rc instead of 70: $(cat "$TMP_ROOT/stall.err")"
  echo "STALL-EVIDENCE $output"
  assert_contains "$output" '"code":"timeout"' "stall produced no timeout evidence"
  assert_contains "$output" '"bound":"invoke"' "stall evidence did not name its bound"
  assert_not_contains "$output" "overrun_ms" "stall at its bound claimed a suspension overrun"
  # bound 3000 + terminate grace + finalize; a granted grace would add 5000.
  [ "$elapsed" -lt 7000 ] || fail "genuine stall waited ${elapsed}ms, past its bound"
  echo "LIVE-PASS genuine-stall-dies-at-bound rc=$rc elapsed_ms=$elapsed"
}

# --- C: frozen invocation resumes inside the grace and completes -------------
case_frozen_resume() {
  local home="$HOMES/resume" marker="$TMP_ROOT/resume.marker" release="$TMP_ROOT/resume.release"
  local started resume_at rc=0
  prepare_home "$home"
  started=$(now_ms)
  start_poll "$home" "hold|$marker|$release" resume
  wait_for_file "$marker" || fail "frozen fixture never reached the adapter"
  freeze_invocation "$marker"
  sleep 7
  resume_at=$(now_ms)
  resume_invocation
  touch "$release"
  wait_for_pid_exit "$poll_pid" 10 || fail "resumed invocation never completed inside the grace"
  wait "$poll_pid"; rc=$?
  poll_pid=
  [ "$rc" -eq 0 ] || fail "resumed invocation failed rc=$rc: $(cat "$TMP_ROOT/resume.err")"
  assert_contains "$(cat "$TMP_ROOT/resume.out")" "resumed inside the grace" "resumed result lost"
  group_pid=; inner_host_pid=
  echo "LIVE-PASS frozen-resumes-inside-grace rc=$rc frozen_ms=$(( resume_at - started )) total_ms=$(( $(now_ms) - started ))"
}

# --- D: frozen invocation that never resumes dies after exactly one grace ----
case_frozen_stall() {
  local home="$HOMES/frozen-stall" marker="$TMP_ROOT/frozen.marker"
  local started resume_at stopped_at rc=0 output overrun grace_ms
  prepare_home "$home"
  started=$(now_ms)
  start_poll "$home" "stall|$marker" frozen-stall
  wait_for_file "$marker" || fail "frozen stall fixture never reached the adapter"
  freeze_invocation "$marker"
  sleep 7
  resume_at=$(now_ms)
  resume_invocation
  wait_for_pid_exit "$poll_pid" 20 || fail "never-resuming invocation was never killed"
  stopped_at=$(now_ms)
  wait "$poll_pid"; rc=$?
  poll_pid=
  output=$(cat "$TMP_ROOT/frozen-stall.out")
  echo "SUSPENSION-EVIDENCE $output"
  [ "$rc" -eq 70 ] || fail "suspension kill exited $rc instead of 70: $(cat "$TMP_ROOT/frozen-stall.err")"
  assert_contains "$output" '"code":"timeout"' "suspension kill produced no timeout evidence"
  assert_contains "$output" '"bound":"invoke"' "suspension kill did not name its bound"
  assert_contains "$output" '"overrun_ms":' "suspension kill did not record its overrun"
  overrun=$(node -e 'const v=JSON.parse(process.argv[1]);process.stdout.write(String(v.overrun_ms))' "$output") \
    || fail "timeout evidence is not JSON"
  case "$overrun" in ''|*[!0-9]*) fail "overrun not numeric: $overrun" ;; esac
  [ "$overrun" -gt 2000 ] || fail "overrun ${overrun}ms does not exceed the suspension slack"
  grace_ms=$(( stopped_at - resume_at ))
  # One 5s grace only. Two graces would be ~10s here.
  [ "$grace_ms" -lt 8500 ] || fail "kill came ${grace_ms}ms after resume: more than one grace was granted"
  [ "$grace_ms" -gt 4500 ] || fail "kill came ${grace_ms}ms after resume: the bounded grace never ran"
  group_pid=; inner_host_pid=
  echo "LIVE-PASS frozen-never-resumes-killed rc=$rc overrun_ms=$overrun grace_window_ms=$grace_ms"
}

# --- E: genuine stall retry coalesces through the real capture pipeline ------
case_pipeline_coalesce() {
  local home="$TMP_ROOT/home-pipe" source=live-stall claims="$TMP_ROOT/claims" round counts
  local marker="$TMP_ROOT/pipe.marker"
  mkdir -p "$home" "$claims" "$TMP_ROOT/user-home"
  (
    export HOME="$TMP_ROOT/user-home" XDG_STATE_HOME="$TMP_ROOT/xdg"
    export FM_PROCEVENT_CLAIM_ROOT="$claims"
    export FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=15
    prepare_home "$home"
    fm_test_track_procevent_home "$home" "$claims"
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" register-extension ext-live "$source" \
      --config-ref "stall|$marker" >/dev/null || fail "cannot register the stall source"
    for round in 1 2; do
      rm -f "$marker"
      if [ "$round" -eq 1 ]; then
        FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" start "$source" > "$TMP_ROOT/pipe-start.out" 2>&1 \
          || fail "start failed: $(cat "$TMP_ROOT/pipe-start.out")"
      else
        FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile > "$TMP_ROOT/pipe-reconcile.out" 2>&1 \
          || fail "reconcile failed: $(cat "$TMP_ROOT/pipe-reconcile.out")"
      fi
      # Wait for the stalled invocation to be killed and captured.
      for _ in $(seq 1 400); do
        compgen -G "$home/state/procevent-inbox/$source.*.result" >/dev/null && break
        sleep 0.05
      done
      for _ in $(seq 1 200); do
        [ "$(compgen -G "$home/state/procevent/runner"* 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && break
        sleep 0.05
      done
      counts=$(compgen -G "$home/state/procevent-inbox/$source.*.result" | wc -l | tr -d ' ')
      echo "ROUND-$round results=$counts"
    done
    local results host_errors result_files
    results=$(compgen -G "$home/state/procevent-inbox/$source.*.result" | wc -l | tr -d ' ')
    host_errors=$(compgen -G "$home/state/procevent-inbox/$source.*.host-error" | wc -l | tr -d ' ')
    result_files=$(compgen -G "$home/state/procevent-inbox/$source.*.result")
    [ "$results" -eq 1 ] || fail "a genuine stall retry allocated $results captures instead of coalescing"
    [ "$host_errors" -eq 1 ] || fail "host-error identity was lost across the retry ($host_errors sidecars)"
    echo "COALESCED-RESULT $(cat $result_files)"
    assert_contains "$(cat $result_files)" '"bound":"invoke"' "coalesced capture lost the bound name"
    echo "LIVE-PASS pipeline-coalesce results=$results host_error_sidecars=$host_errors"
  )
}

fm_test_run_live() {
  local name
  for name in "$@"; do
    "case_$name" || { echo "LIVE-FAIL $name"; exit 1; }
  done
  echo "FM_LIVE_COMPLETE"
}

fm_test_run_live frozen_resume
