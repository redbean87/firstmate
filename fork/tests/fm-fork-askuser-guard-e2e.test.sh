#!/usr/bin/env bash
# The ask-user self-answer guard through the REAL launch path: bin/fm-spawn.sh
# runs the real fork launch policy, which arms and registers the task's
# state/<id>.check.sh; the registered check is then executed through
# bin/fm-check-lib.sh's own snapshot path - the watcher's exact read of a
# custom check - and must emit the wake line for a violating status log and
# stay silent for a clean one. A home without fork policy arms nothing, a
# policy refusal leaves no check behind, and the read-only relaunch preflight
# never arms either.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-askuser-guard-e2e)
mkdir -p "$TMP_ROOT"

# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

# new_spawn_case <name> <id>: fixture home, brief, worktree, fakebin, log.
new_spawn_case() {
  CASE="$TMP_ROOT/$1"
  ID=$2
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  DB="$CASE/runs.sqlite"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes)
  : > "$LAUNCH_LOG"
  sqlite3 "$DB" <<'SQL'
CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT, created_at INTEGER);
CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT, approval_reason TEXT, skip_reason TEXT);
CREATE TABLE step_rounds (step_result_id TEXT, findings_json TEXT, selected_finding_ids TEXT, selection_source TEXT);
SQL
}

spawn_ship() {
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$ID" "$PROJ" --mode no-mistakes --yolo off
}

# sweep: run the registered check exactly as the watcher's slow-check sweep
# does - through fm_custom_check_snapshot_prepare's hash-validated snapshot of
# the armed shim - and echo its output. The fixture run record is selected by
# environment so no sweep ever touches the machine's real one.
sweep() {
  local snap rc out
  FM_CUSTOM_CHECK_SNAPSHOT=
  fm_custom_check_snapshot_prepare "$HOME_DIR/state" "$ID" || return 9
  snap=$FM_CUSTOM_CHECK_SNAPSHOT
  out=$(FM_ASKUSER_GUARD_DB="$DB" bash "$snap" 2>&1)
  rc=$?
  fm_custom_check_snapshot_cleanup
  printf '%s\n' "$out"
  return "$rc"
}

assert_armed() {
  local msg=$1
  assert_present "$HOME_DIR/state/$ID.check.sh" "$msg: state/$ID.check.sh must exist"
  fm_custom_check_registered "$HOME_DIR/state" "$ID" || fail "$msg: the check must pass the watcher's own registration verdict"
}

test_policy_arms_the_guard_on_spawn() {
  local out
  new_spawn_case armed t-armed
  fork_policies "$HOME_DIR" claude-subscription
  out=$(spawn_ship)
  case "$out" in
    *refused*) fail "the launch must proceed: $out" ;;
  esac
  assert_present "$HOME_DIR/state/$ID.meta" "the fixture task must have launched"
  assert_armed "spawn with fork policy"
  assert_grep "check $ID" "$HOME_DIR/state/$ID.check.sh" "the shim must exec the guard for the spawned task"
  pass "spawn: the real launch policy arms and registers the guard for the task"
}

test_registered_check_wakes_once_on_a_violation() {
  local out
  new_spawn_case violating t-violating
  fork_policies "$HOME_DIR" claude-subscription
  spawn_ship >/dev/null
  assert_armed "fixture spawn"
  # The incident's shape: a keyed answered close written with no
  # firstmate delivery behind it.
  cat > "$HOME_DIR/state/$ID.status" <<'EOF'
needs-decision [at=150] [key=nm-E2EVIO1-review]: ask-user findings=f1 file=/x
resolved [key=nm-E2EVIO1-review] [at=200]: answered: DECLINE the code expansion, apply the documentation-only remedy.
EOF
  out=$(sweep) || fail "the snapshot sweep must run the registered check"
  assert_contains "$out" "no steering-inbox delivery" "the registered check must surface the hand-written close through the watcher's snapshot path"
  out=$(sweep) || fail "the snapshot sweep must run the registered check again"
  assert_equals "" "$out" "the same violation must wake only once"
  pass "sweep: the registered check wakes through the watcher's own read path, once"
}

test_clean_task_stays_silent() {
  local out
  new_spawn_case cleant t-clean
  fork_policies "$HOME_DIR" claude-subscription
  spawn_ship >/dev/null
  assert_armed "fixture spawn"
  cat > "$HOME_DIR/state/$ID.status" <<'EOF'
needs-decision [at=150] [key=nm-E2EOK1-review]: ask-user findings=f1 file=/x
resolved [key=nm-E2EOK1-review] [at=200]: answered: Keep the three verdict outputs as the shared contract.
EOF
  mkdir -p "$HOME_DIR/state/$ID.inbox"
  {
    printf 'schema=fm-task-inbox.v1\n'
    printf 'at=2026-10-29T00:00:00Z\n'
    printf -- '--\n'
    printf 'Keep the three verdict outputs as the shared contract.\n'
  } > "$HOME_DIR/state/$ID.inbox/001.msg"
  out=$(sweep) || fail "the snapshot sweep must run the registered check"
  assert_equals "" "$out" "an answered close with its delivery must produce no wake"
  pass "clean: the armed check stays silent when the pairing holds"
}

test_inactive_home_arms_nothing() {
  local out
  new_spawn_case inactive t-inactive
  out=$(spawn_ship)
  case "$out" in
    *refused*) fail "without fork policy the launch must proceed as upstream: $out" ;;
  esac
  assert_present "$HOME_DIR/state/$ID.meta" "the fixture task must have launched"
  assert_absent "$HOME_DIR/state/$ID.check.sh" "a home without config/fork-policies must arm nothing"
  pass "inactive: without fork policy nothing is armed, exactly as upstream"
}

test_refused_launch_leaves_no_check() {
  local out
  new_spawn_case refused t-refused
  fork_policies "$HOME_DIR" consult-gate
  out=$(spawn_ship)
  case "$out" in
    *refused*) : ;;
    *) fail "consult-gate must refuse this launch: $out" ;;
  esac
  assert_absent "$HOME_DIR/state/$ID.check.sh" "a launch refused by policy must leave no check behind"
  assert_absent "$HOME_DIR/state/$ID.meta" "a refused launch must leave no task record"
  pass "refused: a policy refusal happens before arming, leaving no residue"
}

test_preflight_never_arms_and_spawn_does() {
  local home out
  new_spawn_case direct t-direct
  fork_policies "$HOME_DIR" claude-subscription
  home=$HOME_DIR
  # The read-only relaunch preflight HK2 runs must not arm.
  out=$(env FM_LP_PHASE=relaunch-preflight FM_LP_TASK="$ID" FM_LP_KIND=ship \
    FM_LP_HOME="$home" FM_LP_STATE="$home/state" FM_LP_DATA="$home/data" \
    FM_LP_CONFIG="$home/config" FM_LP_HARNESS=pi FM_LP_MODEL= FM_LP_EFFORT= \
    FM_LP_RAW_LAUNCH= FM_LP_PROJECT="$PROJ" FM_LP_OWNER_PID=$$ \
    bash "$ROOT/fork/bin/fm-launch-policy" 2>&1)
  assert_equals 0 $? "the preflight must be allowed: $out"
  assert_absent "$home/state/$ID.check.sh" "the read-only preflight must not arm the guard"
  # The same policy in the spawn phase must arm.
  out=$(env FM_LP_PHASE=spawn FM_LP_TASK="$ID" FM_LP_KIND=ship \
    FM_LP_HOME="$home" FM_LP_STATE="$home/state" FM_LP_DATA="$home/data" \
    FM_LP_CONFIG="$home/config" FM_LP_HARNESS=pi FM_LP_MODEL= FM_LP_EFFORT= \
    FM_LP_RAW_LAUNCH= FM_LP_PROJECT="$PROJ" FM_LP_OWNER_PID=$$ \
    bash "$ROOT/fork/bin/fm-launch-policy" 2>&1)
  assert_equals 0 $? "the spawn phase must be allowed: $out"
  assert_armed "direct policy spawn phase"
  # A secondmate launch never arms the guard even in the spawn phase.
  out=$(env FM_LP_PHASE=spawn FM_LP_TASK="${ID}-mate" FM_LP_KIND=secondmate \
    FM_LP_HOME="$home" FM_LP_STATE="$home/state" FM_LP_DATA="$home/data" \
    FM_LP_CONFIG="$home/config" FM_LP_HARNESS=pi FM_LP_MODEL= FM_LP_EFFORT= \
    FM_LP_RAW_LAUNCH= FM_LP_PROJECT="$PROJ" FM_LP_OWNER_PID=$$ \
    bash "$ROOT/fork/bin/fm-launch-policy" 2>&1)
  assert_equals 0 $? "a secondmate launch must be allowed: $out"
  assert_absent "$home/state/${ID}-mate.check.sh" "a secondmate launch must never arm the guard"
  pass "phases: preflight stays read-only, spawn arms, secondmate stays unarmed"
}

fork_run_tests
