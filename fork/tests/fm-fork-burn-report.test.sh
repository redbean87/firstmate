#!/usr/bin/env bash
# fm-burn-report: both plans, the weekly-versus-monthly asymmetry stated, and
# an unreadable reading degrading to one line instead of failing.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPORT="$ROOT/fork/bin/fm-burn-report"
TMP_ROOT=$(fm_test_tmproot fm-fork-burn-report)
mkdir -p "$TMP_ROOT"
FRESH=$(date -u +%Y-%m-%dT%H:%M:%SZ)

test_report_states_both_plans() {
  fork_quota_snapshot "$TMP_ROOT/ok.json" 78 "$FRESH" 44 "$FRESH" "$FRESH"
  out=$("$REPORT" --json-file "$TMP_ROOT/ok.json"); rc=$?
  expect_code 0 "$rc" "report exits 0"
  assert_contains "$out" "unused capacity is LOST at reset" "Claude weekly loss is stated"
  assert_contains "$out" "unused days carry" "OpenCode Go monthly carry-over is stated"
  assert_contains "$out" "week: 44% left" "Claude week window"
  assert_contains "$out" "monthly: 89% left" "OpenCode Go monthly window"
  pass "both plans reported with the asymmetry"
}
test_unreadable_reading_degrades() {
  echo 'not json' >"$TMP_ROOT/bad.json"
  out=$("$REPORT" --json-file "$TMP_ROOT/bad.json"); rc=$?
  expect_code 0 "$rc" "unreadable evidence still exits 0"
  assert_contains "$out" "burn report unavailable" "one honest line"
  out=$(PATH="/usr/bin:/bin" "$REPORT"); rc=$?
  expect_code 0 "$rc" "missing quota-axi still exits 0"
  pass "unreadable evidence degrades to one line"
}
fork_run_tests
