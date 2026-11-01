#!/usr/bin/env bash
# fm-launch-harness: the primary launch chooses pi or claude from the same
# quota marker that drives dispatch, records the choice, honours an explicit
# FM_LAUNCH_HARNESS, and falls back to the recorded harness (never blocking)
# when the evidence is missing or unreadable. A fake quota-axi serves fixtures.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAUNCH="$ROOT/fork/bin/fm-launch-harness"
TMP_ROOT=$(fm_test_tmproot fm-fork-launch-harness)
mkdir -p "$TMP_ROOT"
FRESH=$(date -u +%Y-%m-%dT%H:%M:%SZ)

new_case() {  # <name> [recorded]
  CASE="$TMP_ROOT/$1"; FAKEBIN="$CASE/bin"; FAKE="$CASE/fake"; CONFIG="$CASE/config"
  mkdir -p "$CONFIG"
  fork_quota_fake "$FAKEBIN" "$FAKE"
  [ -z "${2-}" ] || printf '%s\n' "$2" >"$CONFIG/primary-harness"
}
serve() { fork_quota_snapshot "$FAKE/out" "$1" "$FRESH" "$2" "$FRESH" "$FRESH"; }
run_launch() { PATH="$FAKEBIN:$PATH" "$LAUNCH" --config "$CONFIG" 2>/dev/null; }
recorded() { cat "$CONFIG/primary-harness"; }

test_headroom_picks_pi() {
  new_case headroom claude; serve 78 44
  assert_equals pi "$(run_launch)" "OpenCode Go headroom launches pi"
  assert_equals pi "$(recorded)" "the choice is recorded"
  pass "headroom -> pi, recorded"
}
test_exhausted_picks_claude() {
  new_case exhausted pi; serve 0 44
  assert_equals claude "$(run_launch)" "exhausted OpenCode Go launches claude"
  assert_equals claude "$(recorded)" "the choice is recorded"
  pass "exhausted -> claude, recorded"
}
test_tight_and_rejected_pick_claude() {
  new_case tight; serve 4 44
  assert_equals claude "$(run_launch)" "below the floor launches claude"
  new_case rejected; serve rejected 44
  assert_equals claude "$(run_launch)" "a rejected credential launches claude"
  pass "tight and rejected -> claude"
}
test_unreadable_falls_back() {
  new_case none-pi; echo 1 >"$FAKE/rc"
  assert_equals pi "$(run_launch)" "no reading and nothing recorded launches pi"
  new_case none-claude claude; echo 1 >"$FAKE/rc"
  assert_equals claude "$(run_launch)" "no reading keeps the recorded claude"
  new_case garbage pi; echo 'not json' >"$FAKE/out"
  assert_equals pi "$(run_launch)" "an unparseable reading keeps the recorded harness"
  new_case noquota claude; PATH="/usr/bin:/bin" "$LAUNCH" --config "$CONFIG" >"$CASE/o" 2>/dev/null
  assert_equals claude "$(cat "$CASE/o")" "a missing quota tool never blocks the launch"
  pass "missing or unreadable evidence falls back to the recorded harness"
}
test_unmeasurable_opencode_keeps_recorded() {
  new_case unmeasurable pi; serve absent 44
  assert_equals pi "$(run_launch)" "an absent OpenCode Go row is not read as exhausted"
  pass "unmeasurable OpenCode Go keeps the recorded harness"
}
test_stale_marker_is_not_trusted() {
  new_case stale pi; echo 1 >"$FAKE/rc"
  fork_budget_marker "$CONFIG" claude
  sed -i.bak 's/^decided_at=.*/decided_at=1000/' "$CONFIG/budget-mode"; rm -f "$CONFIG/budget-mode.bak"
  assert_equals pi "$(run_launch)" "an old marker left by a failed refresh is not trusted"
  pass "stale marker ignored"
}
test_explicit_override_wins() {
  new_case override; serve 0 44
  out=$(FM_LAUNCH_HARNESS=pi PATH="$FAKEBIN:$PATH" "$LAUNCH" --config "$CONFIG" 2>/dev/null)
  assert_equals pi "$out" "an explicit FM_LAUNCH_HARNESS beats the quota signal"
  assert_equals pi "$(recorded)" "and is recorded"
  pass "explicit harness wins"
}

fork_run_tests
