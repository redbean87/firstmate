#!/usr/bin/env bash
# budget-mode launch policy: fork/bin/fm-launch-policy follows the plan
# marker fork/bin/fm-budget-mode writes. An absent marker leaves today's
# behaviour intact; a marker deciding claude refuses an opencode launch with
# the marker's own reason; a malformed or unreadable marker refuses loudly
# (exit 2) rather than guessing the plan. Cases call the policy with the hook
# contract directly, as the other unit suites do.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-budget-mode-policy)
mkdir -p "$TMP_ROOT"

# new_case <name>: sets CASE HOME_DIR with fork policy minimally enabled
# (resource with no config file never refuses on its own).
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$CASE/project"
  fork_policies "$HOME_DIR" resource
}

# run_policy <harness> [raw-launch] [phase]: prints output, returns rc.
run_policy() {
  FM_LP_PHASE=${3:-spawn} FM_LP_TASK=t-bm FM_LP_KIND=ship FM_LP_PROJECT="$CASE/project" \
    FM_LP_HARNESS="$1" FM_LP_MODEL='' FM_LP_EFFORT='' FM_LP_RAW_LAUNCH="${2-}" \
    FM_LP_HOME="$HOME_DIR" FM_LP_STATE="$HOME_DIR/state" FM_LP_DATA="$HOME_DIR/data" \
    FM_LP_CONFIG="$HOME_DIR/config" "$POLICY" 2>&1
}

# raw_marker <line...>: overwrite the marker with exactly these lines.
raw_marker() { printf '%s\n' "$@" > "$HOME_DIR/config/budget-mode"; }

test_absent_marker_behaves_as_today() {
  local out rc
  new_case absent
  out=$(run_policy opencode); rc=$?
  expect_code 0 "$rc" "without a marker an opencode launch proceeds as today: $out"
  out=$(run_policy claude); rc=$?
  expect_code 0 "$rc" "without a marker a claude launch proceeds as today: $out"
  out=$(run_policy ''); rc=$?
  expect_code 0 "$rc" "without a marker a raw launch proceeds as today: $out"
  pass "absent marker: no marker leaves every launch exactly as today"
}

test_claude_decision_refuses_opencode_launch() {
  local out rc
  new_case claude-opencode
  fork_budget_marker "$HOME_DIR/config" claude 'OpenCode Go is exhausted: 0% left; the fleet moves to Claude'
  out=$(run_policy opencode); rc=$?
  expect_code 1 "$rc" "a claude decision must refuse an opencode launch: $out"
  assert_contains "$out" "budget mode puts the fleet on the Claude plan" "the refusal names the decision"
  assert_contains "$out" "OpenCode Go is exhausted" "the refusal carries the marker's own reason"
  out=$(run_policy opencode '' relaunch-preflight); rc=$?
  expect_code 1 "$rc" "the relaunch preflight must refuse an opencode relaunch: $out"
  pass "claude decision: an opencode launch and relaunch are refused with the marker's reason"
}

test_claude_decision_still_allows_other_launches() {
  local out rc
  new_case claude-others
  fork_budget_marker "$HOME_DIR/config" claude
  for harness in claude pi codex; do
    out=$(run_policy "$harness"); rc=$?
    expect_code 0 "$rc" "the marker gates only opencode, so a $harness launch proceeds: $out"
  done
  out=$(run_policy '' 'claude --model x'); rc=$?
  expect_code 0 "$rc" "a raw claude launch proceeds under a claude decision: $out"
  pass "claude decision: only opencode launches are gated; claude and other harnesses proceed"
}

test_opencode_decision_gates_nothing() {
  local out rc
  new_case opencode-decision
  fork_budget_marker "$HOME_DIR/config" opencode
  out=$(run_policy opencode); rc=$?
  expect_code 0 "$rc" "an opencode decision lets opencode launches through: $out"
  out=$(run_policy claude); rc=$?
  expect_code 0 "$rc" "an opencode decision never refuses a claude launch: $out"
  pass "opencode decision: OpenCode Go headroom gates nothing, claude stays available"
}

test_raw_opencode_launch_is_gated() {
  local out rc
  new_case raw
  fork_budget_marker "$HOME_DIR/config" claude
  out=$(run_policy '' 'opencode --prompt "go"'); rc=$?
  expect_code 1 "$rc" "a raw opencode launch must be refused under a claude decision: $out"
  assert_contains "$out" "budget mode puts the fleet on the Claude plan" "the refusal names the decision"
  pass "raw launch: a raw opencode command is judged by its first word and refused"
}

test_malformed_markers_refuse_loudly() {
  local out rc
  new_case malformed
  # Each case is a marker that violates exactly one part of schema v1.
  raw_marker 'nonsense'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a line that is not key=value must refuse as unusable: $out"
  assert_contains "$out" "config/budget-mode" "the refusal names the marker"

  fork_budget_marker "$HOME_DIR/config" claude
  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none' 'frobnicate=1'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an unknown field must refuse: $out"
  assert_contains "$out" "unknown field" "the refusal names the unknown field"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a missing field must refuse: $out"
  assert_contains "$out" "missing its reason" "the refusal names the missing field"

  raw_marker 'version=1' 'harness=gemini' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an unknown harness must refuse: $out"
  assert_contains "$out" "not opencode or claude" "the refusal names the bad harness"

  raw_marker 'version=1' 'harness=claude' 'harness=opencode' 'decided_at=1' 'reason=r' \
    'reading=x' 'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a repeated field must refuse: $out"
  assert_contains "$out" "repeats field" "the refusal names the repeated field"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reason=' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an empty reason must refuse: $out"
  assert_contains "$out" "reason is empty" "the refusal names the empty field"

  raw_marker 'version=2' 'harness=claude' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an unknown version must refuse: $out"

  raw_marker 'version=1' 'harness=claude' 'decided_at=noon' 'reason=r' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a non-numeric decided_at must refuse: $out"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=soon' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an unusable reading age must refuse: $out"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=unknown' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "an unknown age with no uncertainty must refuse: $out"
  assert_contains "$out" "unknown reading age but no uncertainty" "the refusal names the contradiction"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' $'reason=bad\ttab' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a tab inside a value must refuse: $out"

  raw_marker 'version=1' 'harness=claude' 'decided_at=1' 'reason=r' 'reading=x' \
    'reading_age_seconds=1' 'uncertainty=none'
  out=$(run_policy claude); rc=$?
  expect_code 0 "$rc" "the repaired base marker proceeds: $out"
  pass "fail-closed: every malformed or contradictory marker refuses as unusable (exit 2)"
}

test_unreadable_marker_refuses_loudly() {
  local out rc
  new_case unreadable
  mkdir -p "$HOME_DIR/config/budget-mode"
  out=$(run_policy claude); rc=$?
  expect_code 2 "$rc" "a marker that is not a readable regular file must refuse: $out"
  assert_contains "$out" "not a readable regular file" "the refusal says why the marker cannot be read"
  pass "unreadable: a marker that is not a readable regular file refuses rather than guessing"
}

test_marker_written_by_the_real_script_is_followed() {
  local out rc fakebin
  new_case writer-consumer
  fakebin="$CASE/bin"
  fork_quota_fake "$fakebin" "$CASE/quota"
  fork_quota_snapshot "$CASE/quota/out" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    44 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PATH="$fakebin:$PATH" "$ROOT/fork/bin/fm-budget-mode" --config "$HOME_DIR/config" --quiet \
    || fail "fm-budget-mode could not write the fixture marker"
  out=$(run_policy opencode); rc=$?
  expect_code 1 "$rc" "the real script's claude marker must gate an opencode launch: $out"
  assert_contains "$out" "OpenCode Go is exhausted" "the refusal carries the reason the real script wrote"
  out=$(run_policy claude); rc=$?
  expect_code 0 "$rc" "the real script's claude marker still allows claude launches: $out"
  pass "round trip: a marker written by real fm-budget-mode is validated and followed by the policy"
}

fork_run_tests
