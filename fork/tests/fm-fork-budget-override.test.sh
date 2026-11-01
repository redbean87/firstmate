#!/usr/bin/env bash
# Precedence: an explicit captain per-task harness choice (firstmate sets
# FM_BUDGET_MODE_OVERRIDE=1 on that one spawn) beats a claude budget marker;
# without it the marker still refuses an opencode launch. Real fm-spawn and
# the real fork launch policy, the standard fake spawn world.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-budget-override)
mkdir -p "$TMP_ROOT"

new_case() {  # <name> <id>
  CASE="$TMP_ROOT/$1"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" opencode
  fm_test_spawn_brief "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes opencode)
  fork_policies "$HOME_DIR" resource
  fork_budget_marker "$HOME_DIR/config" claude "OpenCode Go is exhausted"
  : > "$LAUNCH_LOG"
}
spawn() {  # <id>
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$1" "$PROJ" --mode no-mistakes --yolo off
}

test_marker_refuses_without_override() {
  new_case plain t-plain
  out=$(spawn t-plain); rc=$?
  [ "$rc" -ne 0 ] || fail "claude marker must refuse an opencode launch: $out"
  assert_contains "$out" "budget mode puts the fleet on the Claude plan" "refusal names the marker"
  pass "no override: the marker refuses"
}
test_explicit_override_launches() {
  new_case override t-override
  out=$(FM_BUDGET_MODE_OVERRIDE=1 spawn t-override); rc=$?
  expect_code 0 "$rc" "an explicit captain per-task override must launch: $out"
  [ -f "$HOME_DIR/state/t-override.meta" ] || fail "override launch wrote no task record"
  pass "override: the captain's explicit harness wins over the marker"
}
fork_run_tests
