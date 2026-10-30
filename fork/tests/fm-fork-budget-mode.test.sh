#!/usr/bin/env bash
# fm-budget-mode: the decision script writes exactly one marker from live
# quota evidence - headroom, exhausted, tight, rejected credential,
# unmeasurable and missing readings, and an unageable reading - with
# uncertainty recorded and a stated fallback, never silently read as "plenty
# left" or as "exhausted". A fake quota-axi serves fixtures; no vendor is
# contacted.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUDGET="$ROOT/fork/bin/fm-budget-mode"
TMP_ROOT=$(fm_test_tmproot fm-fork-budget-mode)
mkdir -p "$TMP_ROOT"

# new_case <name>: sets CASE FAKEBIN FAKE CONFIG and an empty quota input.
new_case() {
  CASE="$TMP_ROOT/$1"
  FAKEBIN="$CASE/bin"
  FAKE="$CASE/fake"
  CONFIG="$CASE/config"
  mkdir -p "$CONFIG"
  fork_quota_fake "$FAKEBIN" "$FAKE"
}

FRESH=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# serve <opencode> <opcref> <claude> <cldref> [generated-at]:
# point the fake's output at one snapshot (default generated-at: now).
serve() {
  fork_quota_snapshot "$FAKE/out" "$1" "$2" "$3" "$4" "${5-$FRESH}"
}

# run_budget [args...]: run the real script against the fake; prints output.
run_budget() {
  PATH="$FAKEBIN:$PATH" "$BUDGET" --config "$CONFIG" "$@" 2>&1
}

marker_get() { sed -n "s/^$1=//p" "$CONFIG/budget-mode"; }

assert_marker_shape() {
  assert_equals 7 "$(grep -c . "$CONFIG/budget-mode")" "the marker holds exactly its seven fields"
  assert_equals 1 "$(grep -c '^harness=' "$CONFIG/budget-mode")" "the marker names its harness once"
  assert_equals 1 "$(grep -c '^reason=' "$CONFIG/budget-mode")" "the marker carries its reason once"
  assert_equals 1 "$(grep -c '^reading=' "$CONFIG/budget-mode")" "the marker carries its reading once"
  assert_equals 1 "$(grep -c '^reading_age_seconds=' "$CONFIG/budget-mode")" "the marker carries its reading age once"
  assert_equals 1 "$(grep -c '^uncertainty=' "$CONFIG/budget-mode")" "the marker carries its uncertainty once"
}

test_headroom_keeps_opencode() {
  local out rc age
  new_case headroom
  serve 78 "$FRESH" 44 "$FRESH"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "a headroom reading must produce a marker: $out"
  assert_equals opencode "$(marker_get harness)" "headroom keeps the fleet on the OpenCode Go plan"
  assert_equals none "$(marker_get uncertainty)" "a fully measured decision records no uncertainty"
  assert_contains "$(marker_get reason)" "headroom" "the reason says headroom"
  assert_contains "$(marker_get reason)" "78%" "the reason quotes the reading"
  assert_contains "$(marker_get reading)" "rolling 98%, weekly 78%, monthly 89%" "the reading records all three OpenCode Go windows"
  assert_contains "$(marker_get reading)" "limiting: weekly" "the reading names the limiting window"
  assert_contains "$(marker_get reading)" "claude session 100%, week 44%" "the reading records the Claude window"
  age=$(marker_get reading_age_seconds)
  case "$age" in ''|*[!0-9]*) fail "reading_age_seconds must be an age in seconds, got '$age'" ;; esac
  [ "$age" -lt 3600 ] || fail "a fresh reading must age under an hour, got ${age}s"
  assert_marker_shape
  assert_equals budget-mode "$(ls -A "$CONFIG")" "the script writes exactly one marker file and leaves no temp files"
  pass "headroom: OpenCode Go above the floor keeps the plan, with windows, age, and no uncertainty"
}

test_exhausted_moves_to_claude() {
  local out rc
  new_case exhausted
  serve 0 "$FRESH" 44 "$FRESH"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "an exhausted reading must produce a marker: $out"
  assert_equals claude "$(marker_get harness)" "an exhausted OpenCode Go moves the fleet to Claude"
  assert_contains "$(marker_get reason)" "exhausted" "the reason says exhausted"
  assert_contains "$(marker_get reason)" "moves to Claude" "the reason states the destination plan"
  assert_equals none "$(marker_get uncertainty)" "exhaustion is measured, not uncertain"
  pass "exhausted: 0% left moves the fleet to Claude with a plain-words reason"
}

test_tight_moves_to_claude() {
  local out rc
  new_case tight
  serve 5 "$FRESH" 44 "$FRESH"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "a tight reading must produce a marker: $out"
  assert_equals claude "$(marker_get harness)" "a reading below the floor moves the fleet to Claude"
  assert_contains "$(marker_get reason)" "tight" "the reason says tight"
  assert_contains "$(marker_get reason)" "10% floor" "the reason names the floor"
  pass "tight: below the default floor moves the fleet to Claude"
}

test_tight_floor_is_configurable() {
  local out rc
  new_case floor
  serve 40 "$FRESH" 44 "$FRESH"
  out=$(FM_BUDGET_TIGHT_PERCENT=50 run_budget); rc=$?
  expect_code 0 "$rc" "a floor run must produce a marker: $out"
  assert_equals claude "$(marker_get harness)" "40% is tight against a 50% floor"
  assert_contains "$(marker_get reason)" "50% floor" "the reason names the configured floor"
  pass "floor: FM_BUDGET_TIGHT_PERCENT sets the tight floor"
}

test_rejected_credential_moves_to_claude() {
  local out rc age
  new_case rejected
  serve rejected "$FRESH" 44 "$FRESH"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "a rejected credential must produce a marker: $out"
  assert_equals claude "$(marker_get harness)" "a rejected credential moves the fleet to Claude"
  assert_contains "$(marker_get reason)" "credential was rejected" "the reason names the rejection"
  assert_contains "$(marker_get reading)" "opencode-go credential rejected" "the reading records the rejected credential"
  assert_equals none "$(marker_get uncertainty)" "a rejection is concrete evidence, not uncertainty"
  age=$(marker_get reading_age_seconds)
  case "$age" in ''|*[!0-9]*) fail "the snapshot's age must still be recorded, got '$age'" ;; esac
  pass "rejected credential: auth refusal moves the fleet to Claude without counting as uncertainty"
}

test_unmeasurable_reading_falls_back_with_uncertainty() {
  local out rc
  new_case unmeasurable
  printf 'this is not json\n' > "$FAKE/out"
  printf '1\n' > "$FAKE/rc"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "an unmeasurable reading still writes its marker: $out"
  assert_equals claude "$(marker_get harness)" "an unreadable reading falls back to Claude"
  assert_contains "$(marker_get reason)" "falls back to Claude" "the reason states the fallback"
  assert_contains "$(marker_get reason)" "unreadable window cannot leave the fleet idling" "the reason states why"
  assert_contains "$(marker_get uncertainty)" "unmeasurable" "the uncertainty records the unmeasurable reading"
  assert_contains "$(marker_get uncertainty)" "fell back to Claude" "the uncertainty records the fallback"
  assert_contains "$(marker_get uncertainty)" "age could not be established" "the unknown age is uncertainty, not a silent fresh reading"
  assert_equals unknown "$(marker_get reading_age_seconds)" "no parseable evidence means an unknown age"
  assert_contains "$out" "warning: recorded uncertainty" "uncertainty is surfaced loudly on stderr"
  pass "unmeasurable: an unreadable quota read falls back to Claude with the uncertainty written down"
}

test_missing_opencode_reading_is_uncertainty() {
  local out rc
  new_case missing-row
  serve absent "" 44 "$FRESH"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "a missing row still writes its marker: $out"
  assert_equals claude "$(marker_get harness)" "a missing OpenCode Go reading falls back to Claude"
  assert_contains "$(marker_get uncertainty)" "no opencode-go reading" "the uncertainty records the missing reading"
  assert_contains "$(marker_get reading)" "opencode-go reading absent" "the reading records the absence"
  pass "missing reading: no opencode-go row is written down as uncertainty and falls back to Claude"
}

test_invalid_snapshot_is_unmeasurable() {
  local out rc
  new_case invalid
  printf '{"schemaVersion":9,"providers":[]}\n' > "$FAKE/out"
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "an invalid snapshot still writes its marker: $out"
  assert_equals claude "$(marker_get harness)" "a schema-invalid snapshot falls back to Claude"
  assert_contains "$(marker_get uncertainty)" "did not validate" "the uncertainty records the invalid snapshot"
  pass "invalid snapshot: a schema-invalid read falls back to Claude with the reason recorded"
}

test_missing_claude_reading_does_not_flip_the_decision() {
  local out rc
  new_case claude-missing
  serve 78 "$FRESH" absent ""
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "a missing Claude reading still writes its marker: $out"
  assert_equals opencode "$(marker_get harness)" "the Claude window never flips the decision"
  assert_contains "$(marker_get uncertainty)" "claude reading is missing" "the missing Claude reading is still uncertainty"
  assert_contains "$(marker_get reading)" "claude reading absent" "the reading records the missing Claude window"
  pass "claude absent: a missing Claude window is uncertainty but never flips the decision"
}

test_unageable_reading_falls_back_to_claude() {
  local out rc
  new_case unageable
  serve 78 "" 44 "$FRESH" ""
  out=$(run_budget); rc=$?
  expect_code 0 "$rc" "an unageable reading still writes its marker: $out"
  assert_equals claude "$(marker_get harness)" "a reading that cannot be aged never counts as headroom"
  assert_contains "$(marker_get reason)" "age is unknown" "the reason names the unageable reading"
  assert_equals unknown "$(marker_get reading_age_seconds)" "no timestamp means an unknown age"
  assert_contains "$(marker_get reading)" "refreshed unknown" "the reading records the missing timestamp"
  pass "unageable: headroom with no usable timestamp falls back to Claude as uncertainty"
}

test_quiet_suppresses_stdout_and_bad_config_dies() {
  local out rc
  new_case quiet
  serve 78 "$FRESH" 44 "$FRESH"
  out=$(run_budget --quiet 2>"$CASE/err"); rc=$?
  expect_code 0 "$rc" "a quiet run still writes the marker: $out"
  assert_equals "" "$out" "--quiet prints nothing"
  assert_present "$CONFIG/budget-mode" "--quiet still writes the marker"
  out=$(run_budget --config "$CASE/no-such-config"); rc=$?
  expect_code 2 "$rc" "a missing config directory must refuse loudly: $out"
  assert_contains "$out" "does not exist or is not writable" "the refusal names the unusable config directory"
  pass "interface: --quiet writes silently; an unusable config directory exits 2"
}

fork_run_tests
