#!/usr/bin/env bash
# HK1: the budget-mode marker through the REAL launch path - the real
# fm-budget-mode writes the marker from a fake quota-axi, then the real
# bin/fm-spawn.sh launches through the real fork launch policy. A claude
# marker must refuse an opencode launch before any task record, brief, or
# launch; an opencode marker, or no marker at all, must launch as today. The
# spawn world is the suite's standard fake (fake tmux, exit-0 tools).
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/fork/bin/fm-budget-mode"
TMP_ROOT=$(fm_test_tmproot fm-fork-budget-mode-e2e)
mkdir -p "$TMP_ROOT"

FRESH=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# new_spawn_case <name> <id>: sets CASE HOME_DIR PROJ WT FAKEBIN LAUNCH_LOG;
# an opencode home with fork policy minimally enabled (resource with no
# config file never refuses on its own) and a fake quota-axi beside the
# standard spawn fakes.
new_spawn_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" opencode
  fm_test_spawn_brief "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes opencode)
  fork_quota_fake "$FAKEBIN" "$CASE/quota"
  fork_policies "$HOME_DIR" resource
  : > "$LAUNCH_LOG"
}

spawn_ship() {  # <id>
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$1" "$PROJ" --mode no-mistakes --yolo off
}

# decide: run the real fm-budget-mode against the fake quota snapshot.
decide() {
  PATH="$FAKEBIN:$PATH" "$BUDGET" --config "$HOME_DIR/config" --quiet || \
    fail "fm-budget-mode failed: $?"
}

assert_launched() {  # <id> <output>
  [ -f "$HOME_DIR/state/$1.meta" ] || fail "expected $1 to launch, but no task record was written: $2"
  [ -s "$LAUNCH_LOG" ] || fail "expected $1 to launch, but nothing was sent to the endpoint: $2"
}

assert_refused() {  # <id> <rc> <output> <expected text>
  [ "$2" -ne 0 ] || fail "expected $1 to be refused, but fm-spawn exited 0: $3"
  [ ! -f "$HOME_DIR/state/$1.meta" ] || fail "a refused launch of $1 wrote a task record"
  [ ! -s "$HOME_DIR/data/$1/launch-brief.md" ] || fail "a refused launch of $1 rendered a launch brief"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused launch of $1 sent a launch command to the endpoint"
  assert_contains "$3" "$4" "the refusal for $1 must name its cause"
}

test_absent_marker_launches_as_today() {
  local out rc
  new_spawn_case absent t-absent
  out=$(spawn_ship t-absent); rc=$?
  assert_absent "$HOME_DIR/config/budget-mode" "this case must run without a marker"
  assert_launched t-absent "$out"
  pass "absent marker: with no config/budget-mode an opencode launch proceeds exactly as today"
}

test_claude_marker_refuses_opencode_launch() {
  local out rc
  new_spawn_case gated t-gated
  fork_quota_snapshot "$CASE/quota/out" 0 "$FRESH" 44 "$FRESH" "$FRESH"
  decide
  assert_grep 'harness=claude' "$HOME_DIR/config/budget-mode" \
    "the exhausted fixture must decide claude"
  out=$(spawn_ship t-gated); rc=$?
  assert_refused t-gated "$rc" "$out" "budget mode puts the fleet on the Claude plan"
  assert_contains "$out" "OpenCode Go is exhausted" "the refusal carries the marker's reason"
  pass "claude marker: a marker written from an exhausted reading refuses the opencode launch before any record or launch"
}

test_opencode_marker_launches() {
  local out rc
  new_spawn_case allowed t-allowed
  fork_quota_snapshot "$CASE/quota/out" 78 "$FRESH" 44 "$FRESH" "$FRESH"
  decide
  assert_grep 'harness=opencode' "$HOME_DIR/config/budget-mode" \
    "the headroom fixture must decide opencode"
  out=$(spawn_ship t-allowed); rc=$?
  assert_launched t-allowed "$out"
  pass "opencode marker: a marker written from a headroom reading lets the same launch through"
}

fork_run_tests
