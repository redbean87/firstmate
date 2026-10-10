#!/usr/bin/env bash
# Contract tests for bin/fm-test-shard-tripwire.sh.
#
# A CI shard killed by its job cap emits no FM_TEST_END and no FM_TEST_SUMMARY:
# the check is cancelled with no verdict and no timing artifact, and readers
# misread that silence as flakiness. The tripwire step survives the kill and
# annotates the step summary from the teed log instead, naming the script that
# was running (its last FM_TEST_BEGIN) and its modeled-versus-actual runtime.
# These tests hold that contract: a cut-off log produces the annotation, a
# completed run and a missing log stay silent, and the step never decides the
# shard's verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIPWIRE="$ROOT/bin/fm-test-shard-tripwire.sh"

assert_present "$TRIPWIRE" "bin/fm-test-shard-tripwire.sh is missing"

# Run the tripwire against <log-body> with GITHUB_STEP_SUMMARY pointed at a
# fresh file; echo "<rc>|<summary-file-contents>|<stdout>". The summary file
# stands in for GitHub's per-step markdown surface.
run_tripwire() {  # <name> <log-body> [extra-args...]
  local name=$1 body=$2
  shift 2
  local dir summary rc out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-shard-tripwire.XXXXXX")
  summary="$dir/summary.md"
  : >"$summary"
  printf '%s' "$body" >"$dir/shard.log"
  set +e
  GITHUB_STEP_SUMMARY="$summary" "$TRIPWIRE" "$dir/shard.log" "$@" \
    >"$dir/stdout" 2>"$dir/stderr"
  rc=$?
  set -e
  out=$(cat "$dir/stdout")
  printf '%s|%s|%s\n' "$rc" "$(cat "$summary")" "$out"
  rm -rf "$dir"
  : "${name:?}"
}

# A shard cut off mid-script: one BEGIN stamped with the runner's modeled
# weight, script output, no END, no SUMMARY. This is the shape a job-cap kill
# leaves behind.
CUT_OFF_LOG='FM_TEST_BEGIN 2026-10-10T12:00:00Z tests/fm-wedge.test.sh family=unclassified expected_gate_skip=none weight_ms=45000
ok - fixture started
'

COMPLETE_LOG="${CUT_OFF_LOG}FM_TEST_END 2026-10-10T12:00:05Z tests/fm-wedge.test.sh exit=0 duration_ms=5000 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=5100
"

test_cut_off_log_annotates_the_running_script() {
  local result
  result=$(run_tripwire cut-off "$CUT_OFF_LOG")
  [ "${result%%|*}" = 0 ] \
    || fail "the tripwire must exit 0 on a cut-off log, got ${result%%|*}"
  case "$result" in
    *'Shard cut off before its summary'*) ;;
    *) fail "cut-off log produced no step-summary annotation: $result" ;;
  esac
  # shellcheck disable=SC2016 # Literal markdown backticks in the annotation.
  case "$result" in
    *'`tests/fm-wedge.test.sh`'*) ;;
    *) fail "annotation must name the running script: $result" ;;
  esac
  case "$result" in
    *'FM_TEST_BEGIN 2026-10-10T12:00:00Z tests/fm-wedge.test.sh'*) ;;
    *) fail "annotation must quote the last FM_TEST_BEGIN verbatim: $result" ;;
  esac
  case "$result" in
    *'Modeled runtime: 45000 ms'*) ;;
    *) fail "annotation must carry the modeled weight from the marker: $result" ;;
  esac
  case "$result" in
    *'::warning::shard cut off mid-script: tests/fm-wedge.test.sh'*) ;;
    *) fail "annotation must also surface as a ::warning:: line: $result" ;;
  esac
  pass "a cut-off shard log is annotated with the running script and its weight"
}

test_completed_run_stays_silent() {
  local result
  result=$(run_tripwire complete "$COMPLETE_LOG")
  [ "${result%%|*}" = 0 ] \
    || fail "the tripwire must exit 0 on a completed log, got ${result%%|*}"
  case "$result" in
    *'Shard cut off'*)
      fail "a completed run must not be annotated as cut off: $result" ;;
  esac
  case "$result" in
    *'::warning::'*)
      fail "a completed run must not emit a warning line: $result" ;;
  esac
  # Middle field (the step summary file) is empty.
  [ "$(printf '%s' "$result" | cut -d'|' -f2)" = "" ] \
    || fail "a completed run must write nothing to the step summary: $result"
  pass "a completed run is annotated with nothing"
}

test_missing_log_stays_silent() {
  local dir summary rc out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-shard-tripwire.XXXXXX")
  summary="$dir/summary.md"
  : >"$summary"
  set +e
  GITHUB_STEP_SUMMARY="$summary" "$TRIPWIRE" "$dir/absent.log" \
    >"$dir/stdout" 2>"$dir/stderr"
  rc=$?
  set -e
  out=$(cat "$dir/stdout")
  [ "$rc" -eq 0 ] || fail "a missing log must exit 0, got $rc: $(cat "$dir/stderr")"
  [ ! -s "$summary" ] || fail "a missing log must write no annotation: $(cat "$summary")"
  [ -z "$out" ] || fail "a missing log must print nothing: $out"
  rm -rf "$dir"
  pass "a missing shard log stays silent"
}

test_log_cut_off_before_any_begin() {
  local result
  result=$(run_tripwire no-begin 'setup output with no markers
')
  [ "${result%%|*}" = 0 ] \
    || fail "the tripwire must exit 0 with no BEGIN lines, got ${result%%|*}"
  case "$result" in
    *'Shard cut off before any script began'*) ;;
    *) fail "a marker-less cut-off log must be annotated as setup-only: $result" ;;
  esac
  case "$result" in
    *'Running script:'*)
      fail "a marker-less log must not invent a running script: $result" ;;
  esac
  pass "a shard cut off before its first script is annotated without a script"
}

test_weightless_begin_marker_still_names_the_script() {
  # An FM_TEST_BEGIN without weight_ms (a stale or foreign log) still names
  # the running script; only the modeled figure degrades to "unknown".
  local result
  result=$(run_tripwire weightless \
    'FM_TEST_BEGIN 2026-10-10T12:00:00Z tests/fm-wedge.test.sh family=unclassified expected_gate_skip=none
ok - fixture started
')
  [ "${result%%|*}" = 0 ] || fail "weightless marker must exit 0, got ${result%%|*}"
  # shellcheck disable=SC2016 # Literal markdown backticks in the annotation.
  case "$result" in
    *'`tests/fm-wedge.test.sh`'*) ;;
    *) fail "a weightless marker must still name the running script: $result" ;;
  esac
  case "$result" in
    *'Modeled runtime: unknown'*) ;;
    *) fail "a weightless marker must degrade the modeled figure to unknown: $result" ;;
  esac
  pass "a weightless FM_TEST_BEGIN degrades only the modeled figure"
}

test_usage_errors_are_refused() {
  local dir rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-shard-tripwire.XXXXXX")
  set +e
  "$TRIPWIRE" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "no arguments must be a usage error (exit 2), got $rc"
  grep -Fq 'usage: fm-test-shard-tripwire.sh <shard-log>' "$dir/err" \
    || fail "usage error must state the usage: $(cat "$dir/err")"
  rm -rf "$dir"
  pass "invoking the tripwire without a log is a usage error"
}

test_cut_off_log_annotates_the_running_script
test_completed_run_stays_silent
test_missing_log_stays_silent
test_log_cut_off_before_any_begin
test_weightless_begin_marker_still_names_the_script
test_usage_errors_are_refused
