#!/usr/bin/env bash
# brief write-scope refusal (side tests): fork/bin/fm-brief-intake-check's
# two write-scope rules - a declaration that still carries the standard
# containment sentence, and an undeclared absolute write target outside the
# home - plus one integration point that drives the REAL fork launch policy
# so the refusal reaches the dispatch seam end to end.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-brief-write-scope)
INTAKE="$ROOT/fork/bin/fm-brief-intake-check"

# run_intake <brief>: sets RC and OUT from the checker.
run_intake() {
  OUT=$("$INTAKE" "$1" 2>&1)
  RC=$?
}

# write_brief <path>: write the body from stdin (side-test fixtures).
write_brief() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

# scope_home <name>: a canonical fixture home; sets SCOPE_HOME and
# SCOPE_BRIEF (<home>/data/t-scope/brief.md), so the checker's path-derived
# home, data, and state roots are exercised exactly as at dispatch.
scope_home() {
  SCOPE_HOME=$TMP_ROOT/$1
  SCOPE_BRIEF=$SCOPE_HOME/data/t-scope/brief.md
  mkdir -p "$SCOPE_HOME/data/t-scope"
}

MARKERS='Delivers: the declared write-scope refusal.
Defers: every other checker rule.
Checks: fork/tests/run'

# The standard containment sentence exactly as the scaffold renders it, with
# its real trailing clause, so the fixed-string match is tested against the
# real line and not a paraphrase.
# shellcheck disable=SC2016 # the backticks are literal scaffold text, never expanded
CONTAINMENT='2. Stay inside this worktree; outside it, write only the report and status file below, except for the task'"'"'s empty-inventory attestation through `fm-captain-hold.sh complete --none`, exactly as specified under Definition of done.'

# --- side tests: the two write-scope refusals -------------------------------

test_declaration_with_containment_refused_naming_both_lines() {
  scope_home containment
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Rewrite the persona canon.

## Firstmate spec
Write outside worktree: /Users/persona-shared/canon/
$MARKERS

# Rules
$CONTAINMENT
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 1 "$RC" "a declaration that still carries the containment sentence must be refused: $OUT"
  assert_contains "$OUT" "write scope conflict" "the refusal must name the contradiction"
  assert_contains "$OUT" "Write outside worktree: /Users/persona-shared/canon/" "the refusal must quote the declaration line itself"
  assert_contains "$OUT" "Stay inside this worktree; outside it, write only the report and status file" "the refusal must quote the containment line itself"
  assert_contains "$OUT" "remove that containment line" "the refusal must print the exact line to remove"
  assert_not_contains "$OUT" "undeclared write target" "a declared brief is not judged by the undeclared-target scan"
  assert_not_contains "$OUT" "project check set" "the intake markers are present, so no element violation is reported"
  pass "write scope: a declaration plus the standard containment sentence is refused with both lines named"
}

test_declaration_with_containment_replaced_passes() {
  scope_home replaced
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Rewrite the persona canon.

## Firstmate spec
Write outside worktree: /Users/persona-shared/canon/
$MARKERS

# Rules
2. Outside this worktree, edit only the paths named on the 'Write outside worktree:' line above, plus the report and status file below.
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 0 "$RC" "a declaration whose containment line was replaced must pass: $OUT"
  assert_not_contains "$OUT" "write scope conflict" "the replacement removed the contradiction"
  pass "write scope: a declaration with the containment line replaced passes"
}

test_files_line_outside_path_with_write_verb_refused() {
  scope_home fileswithverb
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Refresh the canon blocks.

## Firstmate spec
Slice T1 only.
$MARKERS
Files: /Users/persona-shared/canon/nyx.md - edit the Canon block
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 1 "$RC" "an undeclared outside write target must be refused: $OUT"
  assert_contains "$OUT" "undeclared write target" "the refusal must name the undeclared-target defect"
  assert_contains "$OUT" "add one line 'Write outside worktree: /Users/persona-shared/canon/nyx.md'" "the refusal must print the exact declaration line to add"
  assert_not_contains "$OUT" "write scope conflict" "no declaration exists, so no contradiction is reported"
  assert_not_contains "$OUT" "project check set" "the intake markers are present, so no element violation is reported"
  pass "write scope: a Files: line with an outside path and a write verb is refused with the exact line to add"
}

test_outside_path_with_write_verb_but_no_files_heading_refused() {
  scope_home verbonly
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Refresh the canon blocks.

## Firstmate spec
$MARKERS
Edit /Users/persona-shared/canon/nyx.md in place.
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 1 "$RC" "an undeclared outside write target on a plain line must be refused: $OUT"
  assert_contains "$OUT" "add one line 'Write outside worktree: /Users/persona-shared/canon/nyx.md'" "the refusal must print the exact declaration line to add"
  pass "write scope: a write verb plus an outside path on an ordinary line is refused"
}

test_read_source_path_passes() {
  scope_home readonly
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Align the scene brief with the canon.

## Firstmate spec
$MARKERS
Sources: /Users/persona-shared/canon/nyx.md (reference copy, read only).
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 0 "$RC" "an outside path named only as a read source must pass: $OUT"
  assert_not_contains "$OUT" "undeclared write target" "a read mention is not a write target"
  pass "write scope: an outside path mentioned only as a read source passes"
}

test_paths_inside_data_or_state_pass() {
  scope_home exemptions
  write_brief "$SCOPE_BRIEF" <<EOF
# Task
## Captain's intent
Draft the report alongside the corpus.

## Firstmate spec
$MARKERS
Edit $SCOPE_HOME/data/t-scope/draft.md in place.
Create $SCOPE_HOME/state/t-scope-notes.md as needed.
EOF
  run_intake "$SCOPE_BRIEF"
  assert_equals 0 "$RC" "paths inside the task's data and state directories must pass: $OUT"
  assert_not_contains "$OUT" "undeclared write target" "the data, state, and home roots are exempt"
  pass "write scope: the same path inside the data or state directory passes"
}

# --- integration: the REAL launch policy refuses and allows -----------------

# run_policy <home> <phase> <kind> <task>: invoke the real launch policy with
# the hook contract env, capturing stdout+stderr into OUT and rc into RC.
run_policy() {
  OUT=$(FM_LP_PHASE="$2" FM_LP_TASK="$4" FM_LP_KIND="$3" FM_LP_HOME="$1" \
    FM_LP_STATE="$1/state" FM_LP_DATA="$1/data" FM_LP_CONFIG="$1/config" \
    bash "$POLICY" 2>&1)
  RC=$?
}

test_policy_refuses_contradiction_then_allows_fixed_brief() {
  local home="$TMP_ROOT/policy"
  mkdir -p "$home/config" "$home/state" "$home/data/t-probe"
  printf '%s\n' brief-intake > "$home/config/fork-policies"
  cat > "$home/data/t-probe/brief.md" <<EOF
# Task
## Captain's intent
Rewrite the persona canon.

## Firstmate spec
Write outside worktree: /Users/persona-shared/canon/
$MARKERS

# Rules
$CONTAINMENT
EOF
  run_policy "$home" spawn scout t-probe
  assert_equals 1 "$RC" "the launch policy must refuse the contradiction through the real dispatch seam: $OUT"
  assert_contains "$OUT" "brief intake refused" "the refusal must arrive through the launch policy"
  assert_contains "$OUT" "write scope conflict" "the refusal must carry the write-scope finding"
  # The exact fix the refusal asked for: drop the containment line, dispatch again.
  cat > "$home/data/t-probe/brief.md" <<EOF
# Task
## Captain's intent
Rewrite the persona canon.

## Firstmate spec
Write outside worktree: /Users/persona-shared/canon/
$MARKERS
EOF
  run_policy "$home" spawn scout t-probe
  assert_equals 0 "$RC" "the corrected brief must be allowed by the real launch policy: $OUT"
  pass "policy: the real launch policy refuses the contradiction and allows the corrected brief"
}

fork_run_tests
