#!/usr/bin/env bash
# fm-self-restart: refuses outside a herdr pane and, in dry-run, makes no
# harness choice. The exit-and-relaunch path drives a live herdr pane and is
# verified by hand against the real harnesses (fork/README), not here.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RESTART="$ROOT/fork/bin/fm-self-restart"
test_requires_a_pane() {
  out=$(env -u HERDR_PANE_ID "$RESTART" --dry-run 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "must refuse outside a herdr pane"
  assert_contains "$out" "not running inside a herdr pane" "names the cause"
  pass "refuses outside a pane"
}
test_dry_run_chooses_nothing() {
  out=$(HERDR_PANE_ID=p1 "$RESTART" --dry-run 2>&1); rc=$?
  expect_code 0 "$rc" "dry run succeeds: $out"
  assert_contains "$out" "relaunch the same harness" "relaunches what it ran under"
  pass "dry run relaunches the same harness"
}
fork_run_tests
