#!/usr/bin/env bash
# Behavioral coverage for fork/bin/fm-step-metrics: the counting rules proven
# against fixture records - first-pass landing, rework (recorded relaunches
# plus paused-to-working returns), escalations, elapsed time, and the report
# column - plus the rolling window (stamped events, then the mtime fallback),
# skip-and-name for missing or unreadable records, dash rendering for facts
# absent from the records, the by-kind rollup and totals, the documented
# header, status-grammar edges (key/corr tags and prose that only looks like
# an event), the fm-step-metrics.v1 JSON document, and usage refusals. All
# fixtures are plain state/<id>.meta and state/<id>.status files under a
# throwaway FM_HOME; nothing here touches the network or a project clone.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

METRICS="$ROOT/fork/bin/fm-step-metrics"
NOW=$(date +%s)
TMP_ROOT=$(fm_test_tmproot fm-step-metrics)

# The counting rules are asserted through the --json document; without jq
# there is no precise surface to assert them on.
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required for the json assertions)"; exit 0; }

new_home() { # -> path of a fresh empty fixture home
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX") || fail "cannot create a fixture home"
  mkdir -p "$h/state" "$h/data"
  printf '%s' "$h"
}

run_metrics() { # <home> [args...] -> stdout, exit status preserved by caller
  local h=$1
  shift
  FM_HOME="$h" bash "$METRICS" "$@"
}

jq_ok() { # <json> <jq-expr> <label>
  printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1 || fail "$3"$'\n'"json: $1"
}

row_of() { # <human-output> <task-id> -> the row, whitespace collapsed
  printf '%s\n' "$1" | grep "^$2 " | awk '{$1=$1; print}' | head -1
}

test_clean_done_task_is_first_pass_with_elapsed_and_report() {
  local h out row
  h=$(new_home)
  fm_write_meta "$h/state/alpha.meta" "kind=ship" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 120)).111.1"
  {
    printf 'working [at=%s]: building\n' "$((NOW - 120))"
    printf 'working [at=%s]: assembled\n' "$((NOW - 90))"
    printf 'done [at=%s]: PR https://example.invalid/p/1\n' "$((NOW - 60))"
  } > "$h/state/alpha.status"

  out=$(run_metrics "$h") || fail "metrics must exit 0"
  assert_contains "$out" "task records for the last 7 days" "header names the window"
  assert_contains "$out" "first-pass  yes = reached done with no recorded relaunch" \
    "header explains what first-pass counts"
  assert_contains "$out" "rework      recorded relaunches" "header explains what rework counts"
  assert_contains "$out" "escalations needs-decision plus blocked events" \
    "header explains what escalations count"
  assert_contains "$out" "totals: 1 tasks, 1 done, 0 failed, 0 in-flight, 1 first-pass, 0 rework, 0 escalations, 1m elapsed" \
    "totals line carries the counts"

  row=$(row_of "$out" alpha)
  [ "$row" = "alpha ship firstmate done yes 0 0 1m no" ] \
    || fail "unexpected alpha row: '$row'"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks | length == 1' "one task in the document"
  jq_ok "$out" '.tasks[0] | .state == "done" and .first_pass == "yes" and .rework == 0 and .escalations == 0 and .elapsed_seconds == 60 and .report == false' \
    "json counts match the counting rules"
  pass "a clean done task is first-pass with elapsed time and a report column"
}

test_rework_escalations_and_first_pass_rules() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/beta.meta" "kind=scout" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 600)).222.2" "control_relaunch_tx=42.20261106T000000Z.9"
  {
    printf 'working [at=%s]: start\n' "$((NOW - 600))"
    printf 'needs-decision [at=%s]: pick A or B\n' "$((NOW - 500))"
    printf 'resolved [at=%s]: picked A\n' "$((NOW - 450))"
    printf 'working [at=%s]: resumed\n' "$((NOW - 440))"
    printf 'blocked [at=%s]: waiting on upstream\n' "$((NOW - 300))"
    printf 'resolved [at=%s]: upstream moved\n' "$((NOW - 250))"
    printf 'paused [at=%s]: declared wait\n' "$((NOW - 200))"
    printf 'working [at=%s]: back\n' "$((NOW - 100))"
    printf 'done [at=%s]: report ready\n' "$((NOW - 60))"
  } > "$h/state/beta.status"
  mkdir -p "$h/data/beta"
  printf '# findings\n' > "$h/data/beta/report.md"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[] | select(.task == "beta") | .first_pass == "no"' \
    "a recorded relaunch or escalation disqualifies first-pass"
  jq_ok "$out" '.tasks[] | select(.task == "beta") | .rework == 2' \
    "rework = 1 recorded relaunch + 1 paused-to-working return"
  jq_ok "$out" '.tasks[] | select(.task == "beta") | .escalations == 2' \
    "escalations = needs-decision + blocked events"
  jq_ok "$out" '.tasks[] | select(.task == "beta") | .elapsed_seconds == 540 and .elapsed == "9m"' \
    "elapsed spans spawn to the terminal event"
  jq_ok "$out" '.tasks[] | select(.task == "beta") | .report == true' \
    "an existing report file reads yes"
  pass "rework, escalations, and first-pass follow the documented rules"
}

test_in_flight_and_failed_states() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/gamma.meta" "kind=ship" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 300)).333.3"
  {
    printf 'working [at=%s]: start\n' "$((NOW - 300))"
    printf 'working [at=%s]: still going\n' "$((NOW - 100))"
  } > "$h/state/gamma.status"
  fm_write_meta "$h/state/delta.meta" "kind=ship" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 400)).444.4"
  {
    printf 'working [at=%s]: start\n' "$((NOW - 400))"
    printf 'failed [at=%s]: daemon refused\n' "$((NOW - 50))"
  } > "$h/state/delta.status"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[] | select(.task == "gamma") | .state == "in-flight" and .first_pass == null and (.elapsed_seconds >= 300) and (.elapsed_seconds <= 330)' \
    "an in-flight task is timed to now and has no first-pass verdict"
  jq_ok "$out" '.tasks[] | select(.task == "delta") | .state == "failed" and .first_pass == null and .elapsed_seconds == 350' \
    "a failed task is finished but never first-pass"
  jq_ok "$out" '.totals | .tasks == 2 and .in_flight == 1 and .failed == 1' \
    "totals separate in-flight from failed"
  pass "in-flight and failed rows are classified from the last work event"
}

test_missing_records_are_skipped_and_named_once() {
  local h out row eta_lines zeta_lines
  h=$(new_home)
  fm_write_meta "$h/state/eta.meta" "kind=ship" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 60)).555.5"
  printf 'working [at=%s]: no meta for me\n' "$((NOW - 60))" > "$h/state/zeta.status"
  fm_write_meta "$h/state/theta.meta" "kind=ship" "project=/repos/firstmate" \
    "spawn_gen=s$((NOW - 60)).666.6"
  printf 'done [at=%s]: fine\n' "$((NOW - 30))" > "$h/state/theta.status"

  out=$(run_metrics "$h") || fail "a skipped record must not fail the report"
  row=$(row_of "$out" theta)
  [ "$row" = "theta ship firstmate done yes 0 0 0m no" ] \
    || fail "unexpected theta row: '$row'"
  [ -z "$(row_of "$out" eta)" ] || fail "the meta-only task must not appear as a row"
  [ -z "$(row_of "$out" zeta)" ] || fail "the status-only task must not appear as a row"
  assert_contains "$out" "skipped (missing or unreadable record):" \
    "the skip section is printed"
  eta_lines=$(printf '%s\n' "$out" | grep -c 'eta: missing or unreadable state/eta.status')
  [ "$eta_lines" = 1 ] || fail "eta must be named exactly once, got $eta_lines"
  zeta_lines=$(printf '%s\n' "$out" | grep -c 'zeta: missing or unreadable state/zeta.meta')
  [ "$zeta_lines" = 1 ] || fail "zeta must be named exactly once, got $zeta_lines"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.skipped | length == 2' "both skips are in the document"
  jq_ok "$out" '.tasks | length == 1' "only the healthy task is rowed"
  pass "missing records are skipped, named once, and never fail the report"
}

test_absent_facts_render_dash() {
  local h out row
  h=$(new_home)
  printf 'harness=pi\n' > "$h/state/kappa.meta"
  {
    printf 'working: tinkering\n'
    printf 'done: finished without a stamp\n'
  } > "$h/state/kappa.status"

  out=$(run_metrics "$h") || fail "metrics must exit 0"
  row=$(row_of "$out" kappa)
  [ "$row" = "kappa - - done yes 0 0 - no" ] \
    || fail "absent facts must render as dashes: '$row'"
  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[0] | .kind == null and .repo == null and .elapsed_seconds == null and .first_pass == "yes"' \
    "absent facts are null in json"
  pass "facts absent from the records render as dash or null"
}

test_window_uses_last_stamp_then_mtime() {
  local h out
  h=$(new_home)
  # Fresh: stamped inside the default window.
  fm_write_meta "$h/state/fresh.meta" "kind=ship" "spawn_gen=s$((NOW - 60)).701.1"
  printf 'done [at=%s]: fresh\n' "$((NOW - 30))" > "$h/state/fresh.status"
  # Old stamps: outside 7 days, inside 40.
  fm_write_meta "$h/state/old.meta" "kind=ship" "spawn_gen=s$((NOW - 30 * 86400)).702.2"
  printf 'done [at=%s]: old\n' "$((NOW - 30 * 86400 + 60))" > "$h/state/old.status"
  # No stamps at all: the status file's mtime decides (set to ~97 days ago).
  fm_write_meta "$h/state/oldun.meta" "kind=ship" "spawn_gen=s$((NOW - 97 * 86400)).703.3"
  printf 'done: unstamped legacy record\n' > "$h/state/oldun.status"
  touch -t 202608010000 "$h/state/oldun.status"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '(.tasks | length) == 1 and .tasks[0].task == "fresh"' \
    "the default 7-day window keeps only the fresh task"

  out=$(run_metrics "$h" --days 40 --json) || fail "--days 40 must exit 0"
  jq_ok "$out" '(.tasks | map(.task) | sort) == ["fresh", "old"]' \
    "--days 40 adds the stamped old task but not the mtime-old one"

  out=$(run_metrics "$h" --days 400 --json) || fail "--days 400 must exit 0"
  jq_ok "$out" '(.tasks | map(.task) | sort) == ["fresh", "old", "oldun"]' \
    "a wide window adds the mtime-windowed record"
  pass "the window reads the last stamp first and the status mtime as fallback"
}

test_rollup_groups_by_kind_including_absent_kind() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/one.meta" "kind=ship" "spawn_gen=s$((NOW - 200)).801.1"
  printf 'done [at=%s]: one\n' "$((NOW - 100))" > "$h/state/one.status"
  fm_write_meta "$h/state/two.meta" "kind=ship" "spawn_gen=s$((NOW - 200)).802.2"
  printf 'working [at=%s]: two\n' "$((NOW - 50))" > "$h/state/two.status"
  fm_write_meta "$h/state/three.meta" "kind=scout" "spawn_gen=s$((NOW - 200)).803.3"
  {
    printf 'needs-decision [at=%s]: choose\n' "$((NOW - 150))"
    printf 'resolved [at=%s]: chose\n' "$((NOW - 140))"
    printf 'done [at=%s]: three\n' "$((NOW - 90))"
  } > "$h/state/three.status"
  printf 'harness=pi\n' > "$h/state/four.meta"
  printf 'done [at=%s]: four\n' "$((NOW - 80))" > "$h/state/four.status"

  out=$(run_metrics "$h") || fail "metrics must exit 0"
  assert_contains "$out" "by kind:" "the rollup section exists"
  assert_contains "$out" "totals: 4 tasks, 3 done, 0 failed, 1 in-flight, 2 first-pass, 0 rework, 1 escalations" \
    "totals aggregate every kind"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.by_kind[] | select(.kind == "ship") | .tasks == 2 and .done == 1 and .in_flight == 1 and .first_pass == 1' \
    "ship rollup counts its rows"
  jq_ok "$out" '.by_kind[] | select(.kind == "scout") | .tasks == 1 and .escalations == 1 and .first_pass == 0' \
    "scout rollup counts its escalations and first-pass"
  jq_ok "$out" '.by_kind[] | select(.kind == null) | .tasks == 1' \
    "a record without kind rolls up under null"
  pass "the rollup groups rows by kind and totals every row"
}

test_status_grammar_edges_do_not_distort_counts() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/edge.meta" "kind=ship" "spawn_gen=s$((NOW - 300)).901.1"
  {
    printf 'needs-decision [key=api-shape] [at=%s]: REST or gRPC?\n' "$((NOW - 250))"
    printf 'resolved [key=api-shape] [at=%s]: REST\n' "$((NOW - 240))"
    printf 'note: Reason: the client already speaks it\n'
    printf 'Working on the parser: half done\n'
    printf 'done [corr=abcd1234abcd1234] [at=%s]: shipped\n' "$((NOW - 100))"
  } > "$h/state/edge.status"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[0] | .escalations == 1' \
    "the keyed needs-decision counts once; its resolve does not"
  jq_ok "$out" '.tasks[0] | .state == "done" and .first_pass == "no"' \
    "a corr-tagged done closes the task and disqualifies first-pass"
  jq_ok "$out" '.tasks[0] | .rework == 0' \
    "prose that starts with a capital Working is not a working event"
  pass "key, corr, note, and prose lines do not distort the counts"
}

test_json_document_shape_and_legend() {
  local h out
  command -v jq >/dev/null 2>&1 || { pass "json document (skipped: jq not found)"; return 0; }
  h=$(new_home)
  fm_write_meta "$h/state/shape.meta" "kind=ship" "spawn_gen=s$((NOW - 100)).951.1"
  printf 'done [at=%s]: shaped\n' "$((NOW - 50))" > "$h/state/shape.status"

  out=$(run_metrics "$h" --json) || fail "json mode must exit 0"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "output must parse as one json document"
  jq_ok "$out" '.schema == "fm-step-metrics.v1"' "the schema tag is present"
  jq_ok "$out" '.columns["first-pass"] | contains("no blocked or needs-decision")' \
    "the json legend explains first-pass"
  jq_ok "$out" '.columns["rework"] | contains("paused back to working")' \
    "the json legend explains rework"
  jq_ok "$out" '.generated_at > 0 and .days == 7 and .cutoff_epoch > 0' \
    "the window metadata is present"
  jq_ok "$out" '.totals.tasks == 1 and .totals.first_pass == 1 and .totals.elapsed_seconds == 50' \
    "totals are recomputed from the rows"
  jq_ok "$out" '.skipped == []' "no skips for a complete record"
  pass "the json document carries the schema, legend, and totals"
}

test_usage_refusals() {
  local h rc
  h=$(new_home)
  run_metrics "$h" --days 0 >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "--days 0 must be refused"
  run_metrics "$h" --days soon >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a non-numeric --days must be refused"
  run_metrics "$h" --bogus >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown argument must be refused"
  run_metrics "$TMP_ROOT/absent-home" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "a missing state directory must be refused loudly"
  out=$(bash "$METRICS" --help) || fail "--help must exit 0"
  assert_contains "$out" "Usage:" "--help prints the usage block"
  pass "usage refusals exit with the documented codes"
}

fork_run_tests
