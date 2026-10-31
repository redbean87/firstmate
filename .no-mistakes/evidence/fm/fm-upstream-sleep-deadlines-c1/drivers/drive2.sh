#!/usr/bin/env bash
# Independent live drive of the two launch-time bounds against the real product:
#   F. the host's launch-ready wait (bin/fm-extension.mjs) survives a freeze
#      that lands before the barrier published readiness, using the UNMODIFIED
#      product barrier;
#   G. the launch barrier's own startup wait (bin/fm-extension-launch-barrier.mjs)
#      stays at its bound when it fires on time and grants exactly one bounded
#      grace when it fired because the process was frozen.
set -u
WT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M6A1ZFAW2KVYR5BNMBZ5E7ND
. "$WT/tests/lib.sh"

HOST="$ROOT/bin/fm-extension.mjs"
BARRIER="$ROOT/bin/fm-extension-launch-barrier.mjs"
TMP_ROOT_RAW=$(fm_test_tmproot fm-live-launch)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
PACKAGES="$TMP_ROOT/packages"
HOMES="$TMP_ROOT/homes"
mkdir -p "$PACKAGES" "$HOMES"

poll_pid=
stopped_pids=
cleanup_all() {
  local pid
  for pid in $stopped_pids; do kill -CONT "$pid" 2>/dev/null || true; done
  [ -z "$poll_pid" ] || kill -TERM "$poll_pid" 2>/dev/null || true
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

# --- fixture package ---------------------------------------------------------
PACKAGE="$PACKAGES/launch-live"
mkdir -p "$PACKAGE"
cat > "$PACKAGE/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "org.example.launch-live",
  "version": "1.0.0",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["ext-launch"]}
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
if verb != "invoke":
    sys.exit(8)
raw({
    "schema": "firstmate.extension-response.v1",
    "request_id": request["request_id"],
    "ok": True,
    "result": {"status": "result", "output": "launched after a suspended launch wait\n"},
    "error": None,
})
sys.exit(0)
PY
chmod 0755 "$PACKAGE/entrypoint.py"

prepare_home() { # <home> <timeout-ms>
  local home=$1 timeout=$2 resolution
  mkdir -p "$home"
  FM_HOME="$home" "$HOST" bind "$PACKAGE" --adapter ext-launch \
    --trust-same-user-code --timeout-ms "$timeout" >/dev/null \
    || fail "cannot bind the launch-live fixture"
  resolution=$(FM_HOME="$home" "$HOST" resolve-process-event ext-launch) \
    || fail "cannot resolve the launch-live fixture"
  IFS=$'\t' read -r r_schema r_id r_version r_cap r_package r_binding r_extra <<< "$resolution"
  [ "$r_schema" = fm-extension-process-event-resolution.v1 ] && [ -z "$r_extra" ] \
    || fail "resolution record is malformed: $resolution"
}

# Children of <pid>, one per line.
children_of() {
  ps -axo pid=,ppid= | awk -v parent="$1" '$2 == parent { print $1 }'
}

# --- F: the host's launch-ready wait recovers after a freeze ------------------
# Freeze the host the instant the barrier publishes readiness, while the host
# has not yet read it, and hold it frozen past the 5 s launch-ready bound. The
# invoke bound is 60 s, so only the launch-ready bound can be the one that
# fired. A missed stop (host already released) is detected and retried.
case_launch_ready_resume() {
  local attempt home inv_root ready started resume_at rc=0 group attempt_log
  local frozen ok=0 start_secs
  for attempt in 1 2 3 4 5; do
    home="$HOMES/launch-ready-$attempt"
    prepare_home "$home" 60000   # 60s invoke bound: only the 5s launch wait can fire
    inv_root="$home/state/extension-invocations"
    ready=""
    started=$(now_ms)
    start_secs=$EPOCHSECONDS
    FM_HOME="$home" "$HOST" process-event ext-launch source.poll \
      --source-id launch-source --config-ref good \
      --expect-extension "$r_id" --expect-version "$r_version" \
      --expect-capability-version "$r_cap" \
      --expect-package-digest "$r_package" --expect-binding-digest "$r_binding" \
      > "$TMP_ROOT/launch-$attempt.out" 2> "$TMP_ROOT/launch-$attempt.err" &
    poll_pid=$!
    # Tight-builtin wait for the barrier's readiness record (no forked ps yet).
    while [ "$(( EPOCHSECONDS - start_secs ))" -lt 10 ]; do
      for candidate in "$inv_root"/*.ready.json; do
        [ -e "$candidate" ] && ready=$candidate && break
      done
      [ -n "$ready" ] && break
    done
    [ -n "$ready" ] || { kill -TERM "$poll_pid" 2>/dev/null; wait "$poll_pid" 2>/dev/null; poll_pid=; fail "the barrier never published readiness"; }
    kill -STOP "$poll_pid"
    stopped_pids="$poll_pid"
    # The barrier's own pid is the group_pid it just published.
    group=$(<"$ready")
    group=${group#*\"group_pid\":}
    group=${group%%[,}]*}
    group=${group//[^0-9]/}
    case "$group" in ''|*[!0-9]*) fail "readiness record carried no group pid" ;; esac
    kill -STOP "$group" 2>/dev/null || true
    stopped_pids="$stopped_pids $group"
    frozen=$(ls -A "$inv_root" 2>/dev/null | tr '\n' ' ')
    if [ "$(ls -A "$inv_root" 2>/dev/null | grep -c 'release.json' || true)" -gt 0 ]; then
      echo "ATTEMPT-$attempt missed: host already released ($frozen)"
      kill -CONT "$group" 2>/dev/null || true
      kill -CONT "$poll_pid" 2>/dev/null || true
      stopped_pids=
      wait "$poll_pid" 2>/dev/null
      poll_pid=
      continue
    fi
    echo "ATTEMPT-$attempt STATE-AT-FREEZE $frozen"
    sleep 8
    resume_at=$(now_ms)
    kill -CONT "$group" 2>/dev/null || true
    kill -CONT "$poll_pid" 2>/dev/null || true
    stopped_pids=
    wait_for_pid_exit "$poll_pid" 15 || fail "a launch interrupted inside the launch-ready wait never recovered"
    wait "$poll_pid"; rc=$?
    poll_pid=
    echo "ATTEMPT-$attempt LAUNCH-STDOUT $(cat "$TMP_ROOT/launch-$attempt.out")"
    echo "ATTEMPT-$attempt LAUNCH-STDERR $(cat "$TMP_ROOT/launch-$attempt.err")"
    [ "$rc" -eq 0 ] || fail "suspended launch wait failed rc=$rc: $(cat "$TMP_ROOT/launch-$attempt.err")"
    assert_contains "$(cat "$TMP_ROOT/launch-$attempt.out")" "launched after a suspended launch wait" \
      "the recovered launch's result was lost"
    ok=1
    echo "LIVE-PASS launch-ready-recovers-after-freeze attempt=$attempt rc=$rc frozen_ms=$(( resume_at - started )) total_ms=$(( $(now_ms) - started ))"
    break
  done
  [ "$ok" -eq 1 ] || fail "could not freeze the host inside its launch-ready wait"
}

# --- G: the barrier's own startup wait -------------------------------------
barrier_case_dir() { # <tag> -> sets CASE_DIR, CASE_ROOT
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR"
  CASE_ROOT=$CASE_DIR
}

start_barrier() { # <case-dir> <token>
  local dir=$1 token=$2
  "$BARRIER" "$token" "$dir/owner.json" "$dir/ready.json" "$dir/release.json" \
    "$$" "$dir/entrypoint.sh" "$dir" invoke \
    > "$dir/barrier.out" 2> "$dir/barrier.err" &
  barrier_pid=$!
}

write_entrypoint() { # <case-dir>
  cat > "$1/entrypoint.sh" <<SH
#!/usr/bin/env bash
printf 'barrier delegated to the package entrypoint\n' >> "$1/entrypoint.ran"
cat >/dev/null
exit 0
SH
  chmod 0755 "$1/entrypoint.sh"
}

write_owner() { # <case-dir> <token> <group-pid>
  local dir=$1 token=$2 group=$3
  cat > "$dir/owner.json" <<JSON
{"schema":"firstmate.extension-invocation-owner.v1","token":"$token","phase":"group","host_pid":$$,"host_identity":"firstmate-extension-host:$$","group_pid":$group,"group_identity":"barrier-token:$token","extension_id":"org.example.launch-live","binding_digest":"sha256:$(printf 'b%.0s' $(seq 1 64))","request_id":"req-1234567890abcdef","source_id":"launch-source","operation":"source.poll"}
JSON
  chmod 0600 "$dir/owner.json"
}

write_release() { # <case-dir> <token>
  printf '{"schema":"firstmate.extension-invocation-release.v1","token":"%s"}\n' "$2" > "$1/release.json"
  chmod 0600 "$1/release.json"
}

# G1: no release, no freeze -> dies at the startup bound with no grace text.
case_barrier_bound_intact() {
  local dir="$TMP_ROOT/barrier-intact" token started elapsed rc=0
  barrier_case_dir barrier-intact
  dir=$CASE_DIR
  token="sha256:$(printf 'a%.0s' $(seq 1 64))"
  write_entrypoint "$dir"
  started=$(now_ms)
  start_barrier "$dir" "$token"
  wait_for_pid_exit "$barrier_pid" 15 || fail "the barrier outlived its startup bound"
  wait "$barrier_pid"; rc=$?
  elapsed=$(( $(now_ms) - started ))
  echo "BARRIER-INTACT-STDERR $(cat "$dir/barrier.err")"
  [ "$rc" -eq 125 ] || fail "barrier exited $rc instead of 125 at its bound"
  assert_contains "$(cat "$dir/barrier.err")" "bound startup fired" "the bound never named itself"
  assert_not_contains "$(cat "$dir/barrier.err")" "system suspension" "an on-time bound claimed a suspension"
  [ "$elapsed" -lt 8000 ] || fail "on-time startup bound waited ${elapsed}ms, past its bound"
  [ ! -e "$dir/entrypoint.ran" ] || fail "the package ran after a bound failure"
  echo "LIVE-PASS barrier-bound-intact rc=$rc elapsed_ms=$elapsed"
}

# G2: frozen across the bound, released inside the grace -> the package runs.
case_barrier_resume_inside_grace() {
  local dir="$TMP_ROOT/barrier-resume" token started resume_at rc=0 group
  barrier_case_dir barrier-resume
  dir=$CASE_DIR
  token="sha256:$(printf 'c%.0s' $(seq 1 64))"
  write_entrypoint "$dir"
  started=$(now_ms)
  start_barrier "$dir" "$token"
  wait_for_file "$dir/ready.json" 200 || fail "the barrier never published readiness"
  group=$(node -e 'const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(v.group_pid))' "$dir/ready.json")
  write_owner "$dir" "$token" "$group"
  kill -STOP "$barrier_pid"
  stopped_pids="$barrier_pid"
  write_release "$dir" "$token"
  sleep 8
  resume_at=$(now_ms)
  kill -CONT "$barrier_pid"
  stopped_pids=
  wait_for_pid_exit "$barrier_pid" 15 || fail "a resumed barrier never finished inside the grace"
  wait "$barrier_pid"; rc=$?
  echo "BARRIER-RESUME-STDERR $(cat "$dir/barrier.err")"
  [ "$rc" -eq 0 ] || fail "a release inside the grace was refused (rc=$rc): $(cat "$dir/barrier.err")"
  [ -s "$dir/entrypoint.ran" ] || fail "the barrier never delegated to the package entrypoint"
  echo "LIVE-PASS barrier-resume-inside-grace rc=$rc frozen_ms=$(( resume_at - started ))"
}

# G3: frozen across the bound, never released -> one grace, then the bound.
case_barrier_frozen_never_released() {
  local dir="$TMP_ROOT/barrier-frozen" token started resume_at stopped_at rc=0 grace_ms
  barrier_case_dir barrier-frozen
  dir=$CASE_DIR
  token="sha256:$(printf 'd%.0s' $(seq 1 64))"
  write_entrypoint "$dir"
  start_barrier "$dir" "$token"
  wait_for_file "$dir/ready.json" 200 || fail "the barrier never published readiness"
  kill -STOP "$barrier_pid"
  stopped_pids="$barrier_pid"
  sleep 8
  resume_at=$(now_ms)
  kill -CONT "$barrier_pid"
  stopped_pids=
  wait_for_pid_exit "$barrier_pid" 20 || fail "a frozen barrier that was never released was never killed"
  stopped_at=$(now_ms)
  wait "$barrier_pid"; rc=$?
  grace_ms=$(( stopped_at - resume_at ))
  echo "BARRIER-FROZEN-STDERR $(cat "$dir/barrier.err")"
  [ "$rc" -eq 125 ] || fail "frozen barrier exited $rc instead of 125"
  assert_contains "$(cat "$dir/barrier.err")" "bound startup fired" "the suspension kill did not name its bound"
  assert_contains "$(cat "$dir/barrier.err")" "system suspension" "the suspension kill did not record the suspension"
  [ ! -e "$dir/entrypoint.ran" ] || fail "the package ran without a release"
  [ "$grace_ms" -gt 4500 ] && [ "$grace_ms" -lt 8500 ] \
    || fail "after resume the barrier died ${grace_ms}ms later: not exactly one bounded grace"
  echo "LIVE-PASS barrier-frozen-never-released rc=$rc grace_window_ms=$grace_ms"
}

case_launch_ready_resume || { echo "LIVE-FAIL launch_ready_resume"; exit 1; }
case_barrier_bound_intact || { echo "LIVE-FAIL barrier_bound_intact"; exit 1; }
case_barrier_resume_inside_grace || { echo "LIVE-FAIL barrier_resume_inside_grace"; exit 1; }
case_barrier_frozen_never_released || { echo "LIVE-FAIL barrier_frozen_never_released"; exit 1; }
echo "FM_LIVE_COMPLETE"
