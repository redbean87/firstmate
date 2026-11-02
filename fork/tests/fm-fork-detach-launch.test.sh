#!/usr/bin/env bash
# fm-detach-launch: the fork's detached-launch helper pins a long-running
# service's working directory to an explicit directory outside every root
# bin/fm-teardown.sh reaps (linked task worktrees, the task's /tmp/fm-<id> temp
# root, and the task's recorded worktree=/tasktmp= records), so a service a
# recipe deliberately leaves running survives its own task's cleanup while a
# process rooted in the worktree is still reaped. Refusals fail closed with no
# launch; the pid capture in $(...) never blocks on the child.
#
# The integration point drives the REAL scripts end to end: the real
# fork/chatgpt/fm-chatgpt-loop.sh `bridge start` recipe (through the real
# helper) launched from inside a real task worktree, then the real
# bin/fm-teardown.sh cleanup - the bridge must survive while an in-worktree
# leak is reaped. The teardown fixtures are lifted read-only from upstream's
# tests/fm-teardown.test.sh with a FIXTURE-DRIFT guard, the same contract
# fork_lift_relaunch_fixture uses for the relaunch suite.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCH="$ROOT/fork/bin/fm-detach-launch"
LOOP="$ROOT/fork/chatgpt/fm-chatgpt-loop.sh"
# shellcheck disable=SC2034 # read by the lifted run_teardown fixture via eval
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-detach-launch)
mkdir -p "$TMP_ROOT"
fm_git_identity fmtest fmtest@example.invalid

# kill_quiet <pid>: best-effort TERM so no fixture process outlives its test.
kill_quiet() {
  [ -n "${1:-}" ] && kill -TERM "$1" 2>/dev/null || true
}

# A stand-in service: records its own working directory, then idles until
# TERM. The recorded pwd is what the reaper's lsof cwd match would read.
write_recorder() { # <script-path> <record-file>
  cat > "$1" <<SH
#!/usr/bin/env bash
pwd -P > "$2"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
SH
  chmod +x "$1"
}

# poll_present <file> [attempts]: wait for a fixture file to appear.
poll_present() {
  local i
  for i in $(seq 1 30); do
    [ -e "$1" ] && return 0
    sleep 0.1
  done
  [ -e "$1" ]
}

test_launch_pins_cwd_and_captures_pid() {
  local dir="$TMP_ROOT/svc" out pid
  mkdir -p "$dir"
  # The caller stands somewhere else entirely: the child must land in --cwd,
  # and $(...) must return with only the pid even though the child writes to
  # stdout and stderr (both routed to --log).
  # shellcheck disable=SC2016 # $0 must stay literal for sh -c's arg0
  out=$(cd "$TMP_ROOT" &&
    "$LAUNCH" --cwd "$dir" --log "$TMP_ROOT/launch.log" -- \
      sh -c 'pwd -P >"$0"; echo TO-STDOUT; echo TO-STDERR >&2; exec sleep 30' \
      "$TMP_ROOT/launched-cwd.txt") || fail "launch must succeed: $out"
  case "$out" in ''|*[!0-9]*) fail "helper stdout must be exactly the pid (got '$out')" ;; esac
  pid=$out
  # shellcheck disable=SC2064 # expand now: $pid is local and out of scope at signal time
  trap "kill_quiet $pid" EXIT
  kill -0 "$pid" 2>/dev/null || fail "launched pid $pid must be alive"
  poll_present "$TMP_ROOT/launched-cwd.txt" || fail "child must record its cwd"
  assert_equals "$(cd "$dir" && pwd -P)" "$(cat "$TMP_ROOT/launched-cwd.txt")" \
    "child cwd must be the pinned --cwd, never the caller's directory"
  assert_grep 'TO-STDOUT' "$TMP_ROOT/launch.log" "child stdout must land in --log"
  assert_grep 'TO-STDERR' "$TMP_ROOT/launch.log" "child stderr must land in --log"
  kill_quiet "$pid"
  trap - EXIT
  pass "launch pins cwd to --cwd, returns only the pid, and routes child stdio to --log"
}

test_launch_refuses_git_worktree_cwd() {
  local repo="$TMP_ROOT/wtrepo" wt="$TMP_ROOT/wt-out" out rc
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add -q -b wt1 "$wt"
  mkdir -p "$wt/sub"
  # Refuse the worktree root itself...
  out=$("$LAUNCH" --cwd "$wt" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "worktree root must be refused"
  assert_contains "$out" "inside the git worktree" "refusal must name the mechanism"
  # ...and a subdirectory of it (the walk-up is what makes it provable).
  out=$("$LAUNCH" --cwd "$wt/sub" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "worktree subdirectory must be refused"
  assert_contains "$out" "inside the git worktree" "refusal must name the mechanism"
  # A plain clone INSIDE the worktree is still caught by the worktree above it.
  git clone -q "$repo" "$wt/inner"
  out=$("$LAUNCH" --cwd "$wt/inner" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "clone nested in a worktree must be refused by the walk-up"
  assert_contains "$out" "inside the git worktree" "refusal must name the mechanism"
  pass "a linked git worktree (root, subdir, or a clone nested inside it) is refused"
}

test_launch_allows_plain_clone_cwd() {
  local clone="$TMP_ROOT/plain-clone" out pid
  fm_git_init_commit "$clone"   # .git is a directory: a primary checkout, never reaped
  # shellcheck disable=SC2016 # $0 must stay literal for sh -c's arg0
  out=$("$LAUNCH" --cwd "$clone" -- sh -c 'pwd -P >"$0"; exec sleep 30' "$TMP_ROOT/clone-cwd.txt") ||
    fail "a plain clone must be allowed (the bridge's own daemon directory is one): $out"
  case "$out" in ''|*[!0-9]*) fail "helper stdout must be exactly the pid (got '$out')" ;; esac
  pid=$out
  # shellcheck disable=SC2064 # expand now: $pid is local and out of scope at signal time
  trap "kill_quiet $pid" EXIT
  poll_present "$TMP_ROOT/clone-cwd.txt" || fail "child must record its cwd"
  assert_equals "$(cd "$clone" && pwd -P)" "$(cat "$TMP_ROOT/clone-cwd.txt")" \
    "child cwd must be the clone"
  kill_quiet "$pid"
  trap - EXIT
  pass "a plain clone (primary checkout, .git directory) is an allowed launch directory"
}

test_launch_refuses_task_temp_and_recorded_roots() {
  local id tmp out rc
  id="detachtst$$"
  tmp="/tmp/fm-$id"
  local state="$TMP_ROOT/state" rec="$TMP_ROOT/recorded" rec2="$TMP_ROOT/recorded-tmp"
  mkdir -p "$state" "$rec/sub" "$rec2/sub" "$TMP_ROOT/ok"
  mkdir -p "$tmp/sub"
  # Register the /tmp fixture for exit cleanup even if this test fails midway.
  printf '%s\n' "$tmp" >> "$FM_TEST_CLEANUP_REGISTRY"
  printf 'worktree=%s\ntasktmp=%s\n' "$rec" "$rec2" > "$state/task-x1.meta"

  # Derived root: the launching task's own /tmp/fm-<id> temp root, refused
  # even though it is not a git worktree at all.
  out=$(FM_TASK_ID="$id" "$LAUNCH" --cwd "$tmp/sub" --state "$state" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "the task's /tmp/fm-<id> temp root must be refused"
  assert_contains "$out" "task temp root" "refusal must name the temp-root mechanism"

  # Recorded roots: exactly the records the reaper reads, refused even though
  # these directories are plain dirs with no git metadata at all.
  out=$(FM_TASK_ID=task-x1 "$LAUNCH" --cwd "$rec/sub" --state "$state" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "the recorded worktree= root must be refused"
  assert_contains "$out" "recorded worktree root" "refusal must name the recorded-root mechanism"
  out=$(FM_TASK_ID=task-x1 "$LAUNCH" --cwd "$rec2/sub" --state "$state" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "the recorded tasktmp= root must be refused"
  assert_contains "$out" "recorded tasktmp root" "refusal must name the recorded-root mechanism"

  # Outside those roots the same task context must still launch.
  out=$(FM_TASK_ID=task-x1 "$LAUNCH" --cwd "$TMP_ROOT/ok" --state "$state" -- sh -c 'exec sleep 30') ||
    fail "a directory outside every root must still launch: $out"
  case "$out" in ''|*[!0-9]*) fail "helper stdout must be exactly the pid (got '$out')" ;; esac
  kill_quiet "$out"

  # An id that is not a plain task id never becomes a path: no crash, no
  # spurious refusal, structural checks still applied.
  out=$(FM_TASK_ID='../evil' "$LAUNCH" --cwd "$TMP_ROOT/ok" --state "$state" -- sh -c 'exec sleep 30') ||
    fail "a non-plain task id must never build a path or break the launch: $out"
  kill_quiet "$out"

  rm -rf "$tmp"
  pass "the task's derived temp root and recorded worktree=/tasktmp= roots are refused exactly"
}

test_launch_usage_errors() {
  local out rc
  out=$("$LAUNCH" -- sleep 30 2>&1); rc=$?
  expect_code 2 "$rc" "missing --cwd must be a usage error"
  assert_contains "$out" "--cwd is required" "usage must say why"
  out=$("$LAUNCH" --cwd "$TMP_ROOT" 2>&1); rc=$?
  expect_code 2 "$rc" "missing command must be a usage error"
  out=$("$LAUNCH" --cwd "$TMP_ROOT/no-such-dir-$$" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "a missing launch directory must refuse"
  assert_contains "$out" "launch directory not found" "refusal must name the missing directory"
  out=$("$LAUNCH" --cwd "$TMP_ROOT" --log "$TMP_ROOT/no-such-sub-$$/launch.log" -- sleep 30 2>&1); rc=$?
  expect_code 1 "$rc" "an unwritable log must refuse rather than launch"
  assert_contains "$out" "cannot write log file" "refusal must name the log problem"
  pass "usage errors exit 2 and launch failures refuse with a named reason"
}

# The integration point: the real recipe, the real helper, the real teardown.
test_bridge_start_survives_real_task_teardown() {
  # Lift upstream's teardown fixtures read-only; drift stops the suite instead
  # of silently testing less (fork_lift_relaunch_fixture's contract).
  local suite="$ROOT/tests/fm-teardown.test.sh" fn body
  for fn in make_case write_meta wt_commit land_shippable_commit run_teardown; do
    body=$(sed -n "/^$fn() {/,/^}/p" "$suite")
    if [ -z "$body" ]; then
      printf 'not ok - FIXTURE-DRIFT: %s no longer defines %s()\n' "${suite#"$ROOT"/}" "$fn" >&2
      exit 3
    fi
    eval "$body"
  done

  local case_dir fake_home daemon out rc bridge_pid leak_pid daemon_cwd i
  case_dir=$(make_case detach-e2e)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A fake home whose bridge daemon records its own working directory and then
  # idles - the exact shape of the incident's relaunched service.
  fake_home="$case_dir/home"
  daemon="$fake_home/tools/codex-chatgpt-web"
  mkdir -p "$daemon/bin"
  write_recorder "$daemon/bin/codex-chatgpt-web" "$case_dir/daemon-cwd.txt"

  # The documented recipe, invoked exactly as the incident did: the worker's
  # shell standing inside the task worktree, worker environment (FM_TASK_ID)
  # exported, task record carrying both reap roots.
  out=$(
    cd "$case_dir/wt" &&
      HOME="$fake_home" FM_HOME="$case_dir" \
        FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
        FM_TASK_ID=task-x1 CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" \
        bash "$LOOP" bridge start 2>&1
  ) || fail "bridge start through the real recipe must succeed: $out"
  bridge_pid=$(printf '%s\n' "$out" | sed -n 's/.*starting (pid \([0-9][0-9]*\).*/\1/p')
  [ -n "$bridge_pid" ] || fail "recipe must report its bridge pid: $out"
  # shellcheck disable=SC2064 # expand now: bridge_pid is local and out of scope at signal time
  trap "kill_quiet $bridge_pid" EXIT

  # The mechanism, asserted from the process itself: the daemon's working
  # directory is its own directory - outside the worktree the reaper scans -
  # not the worktree the recipe was invoked from.
  poll_present "$case_dir/daemon-cwd.txt" || fail "bridge daemon must record its cwd"
  daemon_cwd=$(cat "$case_dir/daemon-cwd.txt")
  assert_equals "$(cd "$daemon" && pwd -P)" "$daemon_cwd" \
    "the recipe-relaunched bridge must run from the daemon directory, not the invoking worktree"
  assert_not_contains "$daemon_cwd" "$(cd "$case_dir/wt" && pwd -P)" \
    "the bridge cwd must be outside the task worktree (the reaped root)"

  # The genuine-leak direction that must keep working: a process whose working
  # directory IS the worktree.
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  leak_pid=$!
  disown
  # shellcheck disable=SC2064 # expand now: both pids are local and out of scope at signal time
  trap "kill_quiet $bridge_pid; kill_quiet $leak_pid" EXIT
  sleep 0.3
  kill -0 "$leak_pid" 2>/dev/null || fail "the in-worktree leak must start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "real teardown must succeed"

  # Direction 1: the deliberately detached service survives its own task's
  # cleanup.
  kill -0 "$bridge_pid" 2>/dev/null ||
    fail "the recipe-relaunched bridge must survive its own task's teardown$(printf '\n--- teardown stderr ---\n'; tail -20 "$case_dir/stderr")"
  # Direction 2: the in-worktree leak is still reaped.
  if kill -0 "$leak_pid" 2>/dev/null; then
    kill -KILL "$leak_pid" 2>/dev/null || true
    fail "the in-worktree leak must be reaped by teardown"
  fi
  assert_grep 'reaping leaked worktree process' "$case_dir/stderr" \
    "teardown must report reaping the in-worktree leak"

  kill_quiet "$bridge_pid"
  trap - EXIT
  pass "real bridge start from inside the worktree survives real teardown while the in-worktree leak is reaped"
}

fork_run_tests
