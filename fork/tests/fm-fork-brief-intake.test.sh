#!/usr/bin/env bash
# brief-intake dispatch preflight: fork/bin/fm-brief-intake-check's own rules
# (side tests), the brief-intake policy's scope (kind, phase, opt-in), and one
# integration point that drives the REAL upstream bin/fm-spawn.sh through HK1
# and proves the dispatch path refuses an unfilled brief and launches a
# correctly filled one.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-brief-intake)
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

# The correct firstmate fill of a scaffolded brief: the two placeholders get
# their real bodies, and - when given - the intake markers land in the
# Firstmate spec as their own lines.
fill_and_mark() { # <brief> <spec> [markers-block]
  local b=$1 spec=$2 tmp="$1.fill"
  if [ "$#" -ge 3 ] && [ -n "$3" ]; then
    spec="$spec
$3"
  fi
  INTENT='Add the green-wake latch (slice T1 only).' SPEC="$spec" \
    awk '
      /^\{TASK\}$/ { print ENVIRON["INTENT"]; next }
      /^\{FIRSTMATE_SPEC\}$/ { print ENVIRON["SPEC"]; next }
      { print }' "$b" > "$tmp" \
    || { rm -f "$tmp"; fail "could not fill the scaffolded brief $b"; }
  mv "$tmp" "$b" || fail "could not write the filled brief $b"
}

MARKERS='Delivers: the adapter, its registration, and silence by design.
Defers: the wake payload redesign (plan T2).
Checks: npm run test, npm run typecheck, npm run lint, npm run format:check
Bound: one advisory wake per PR head
Bound: watcher spend stays under the shared daily budget
Composition: the latch admits one wake per head while the budget gates first-time heads only; tests/fm-pr-green-promise.test.sh pins that combined promise.'

# --- side tests: the checker's own rules -----------------------------------

test_scaffold_and_correct_fill_pass() {
  local home="$TMP_ROOT/scaffold/home" b
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" t-scaffold some-proj --mode direct-PR >/dev/null \
    || fail "bin/fm-brief.sh could not scaffold the today-scaffold brief"
  b="$home/data/t-scaffold/brief.md"
  [ -f "$b" ] || fail "scaffold wrote no brief at $b"
  fill_and_mark "$b" "Slice T1 only; the plan reference stays in the brief body." "$MARKERS"
  run_intake "$b"
  assert_equals 0 "$RC" "today's scaffold plus a correct firstmate fill must pass the preflight: $OUT"
  pass "preflight: today's scaffold plus a correct fill carries every intake element"
}

test_tolerant_marker_shapes_pass() {
  local b="$TMP_ROOT/tolerant/brief.md"
  write_brief "$b" <<'EOF'
# Task
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
  - Delivers: the adapter and its registration.
  * Defers: nothing.
+ Checks: npm test, npm run format:check
EOF
  run_intake "$b"
  assert_equals 0 "$RC" "indented and bulleted marker lines must still count: $OUT"
  pass "preflight: markers written as indented list items are accepted"
}

test_missing_scope_refused_with_exact_lines() {
  local b="$TMP_ROOT/scope/brief.md"
  write_brief "$b" <<'EOF'
# Task
## Captain's intent
Ship the latch.

## Firstmate spec
Checks: npm test
EOF
  run_intake "$b"
  assert_equals 1 "$RC" "a brief without slice scope must be refused: $OUT"
  assert_contains "$OUT" "slice scope" "the refusal must name the slice-scope defect"
  assert_contains "$OUT" "Delivers: <what this slice delivers>" "the refusal must show the exact Delivers line to add"
  assert_contains "$OUT" "Defers: <what this slice defers, or nothing>" "the refusal must show the exact Defers line to add"
  assert_not_contains "$OUT" "project check set" "the check set is named, so it must not be reported missing"
  assert_not_contains "$OUT" "promise composition" "zero bounded promises need no composition, so it must not be reported missing"
  pass "preflight: a brief with no slice scope is refused with the exact lines to add"
}

test_missing_check_set_refused_by_name() {
  local b="$TMP_ROOT/checks/brief.md"
  write_brief "$b" <<'EOF'
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
Delivers: the adapter and its registration.
Defers: nothing.
EOF
  run_intake "$b"
  assert_equals 1 "$RC" "a brief with no named check set must be refused: $OUT"
  assert_contains "$OUT" "project check set" "the refusal must name the check-set defect"
  assert_contains "$OUT" "Checks: <the project's full check set" "the refusal must show the exact Checks line to add"
  assert_not_contains "$OUT" "slice scope" "slice scope is stated, so it must not be reported missing"
  pass "preflight: a brief that names no project check set is refused with the exact line to add"
}

test_one_bounded_promise_needs_no_composition() {
  local b="$TMP_ROOT/onebound/brief.md"
  write_brief "$b" <<'EOF'
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
Delivers: the adapter and its registration.
Defers: nothing.
Checks: npm test, npm run format:check
Bound: one advisory wake per PR head
EOF
  run_intake "$b"
  assert_equals 0 "$RC" "a single bounded promise must not demand a composition line: $OUT"
  pass "preflight: one Bound line with no composition is accepted"
}

test_two_bounded_promises_require_composition() {
  local b="$TMP_ROOT/twobound/brief.md"
  write_brief "$b" <<'EOF'
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
Delivers: the adapter and its registration.
Defers: nothing.
Checks: npm test, npm run format:check
Bound: one advisory wake per PR head
Bound: watcher spend stays under the shared daily budget
EOF
  run_intake "$b"
  assert_equals 1 "$RC" "two bounded promises with no composition must be refused: $OUT"
  assert_contains "$OUT" "promise composition" "the refusal must name the promise-composition defect"
  assert_contains "$OUT" "Composition: <how those bounded promises compose" "the refusal must show the exact Composition line to add"
  pass "preflight: two Bound lines with no Composition line are refused with the exact line to add"
}

test_every_missing_element_reported_in_one_refusal() {
  local b="$TMP_ROOT/all/brief.md"
  write_brief "$b" <<'EOF'
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
EOF
  run_intake "$b"
  assert_equals 1 "$RC" "an empty brief must be refused: $OUT"
  assert_contains "$OUT" "slice scope" "the combined refusal must list the slice-scope defect"
  assert_contains "$OUT" "project check set" "the combined refusal must list the check-set defect"
  assert_not_contains "$OUT" "promise composition" "no bounded promises means no composition clause"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c '^brief intake refused ')" "all missing elements must arrive in one refusal line"
  pass "preflight: every missing element is named in a single refusal"
}

test_absent_brief_is_not_judged_here() {
  run_intake "$TMP_ROOT/absent/brief.md"
  assert_equals 2 "$RC" "an absent brief must exit 2 for the caller to route: $OUT"
  assert_contains "$OUT" "no such file" "the exit-2 message must say the file is absent"
  pass "preflight: an absent brief exits 2 so bin/fm-spawn.sh's own brief check owns absence"
}

test_unreadable_brief_exits_2() {
  local b="$TMP_ROOT/unreadable/brief.md"
  write_brief "$b" <<'EOF'
Delivers: x.
EOF
  chmod 000 "$b"
  if [ -r "$b" ]; then
    chmod 644 "$b"
    pass "preflight: unreadable-brief case skipped (this user can read mode-000 files)"
    return 0
  fi
  run_intake "$b"
  chmod 644 "$b"
  assert_equals 2 "$RC" "a brief that exists but cannot be read must exit 2: $OUT"
  assert_contains "$OUT" "not a readable regular file" "the exit-2 message must say the file is unreadable"
  pass "preflight: a brief that exists but cannot be read refuses with exit 2"
}

# --- policy scope: kind, phase, opt-in -------------------------------------

# run_policy <home> <phase> <kind> <task>: invoke the launch policy directly
# with the hook contract env, capturing stdout+stderr into OUT and rc into RC.
run_policy() {
  OUT=$(FM_LP_PHASE="$2" FM_LP_TASK="$4" FM_LP_KIND="$3" FM_LP_HOME="$1" \
    FM_LP_STATE="$1/state" FM_LP_DATA="$1/data" FM_LP_CONFIG="$1/config" \
    bash "$POLICY" 2>&1)
  RC=$?
}

# policy_home <name>: a home whose config enables brief-intake and whose
# data/t-probe/brief.md is the given body on stdin.
policy_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data/t-probe"
  printf '%s\n' brief-intake > "$home/config/fork-policies"
  cat > "$home/data/t-probe/brief.md"
  printf '%s' "$home"
}

test_policy_judges_ship_and_scout_at_every_phase() {
  local home phase
  home=$(policy_home unmarked <<'EOF'
## Captain's intent
Ship the latch.

## Firstmate spec
Slice T1 only.
EOF
)
  for phase in spawn relaunch relaunch-preflight; do
    run_policy "$home" "$phase" ship t-probe
    assert_equals 1 "$RC" "phase $phase must refuse an unmarked ship brief: $OUT"
    assert_contains "$OUT" "brief intake refused" "phase $phase must refuse through the launch policy"
    assert_contains "$OUT" "Delivers: <what this slice delivers>" "phase $phase must name the missing slice scope"
  done
  run_policy "$home" spawn scout t-probe
  assert_equals 1 "$RC" "a scout brief is judged too: $OUT"
  pass "policy: ship launches at every phase and scout launches judge the brief"
}

test_policy_exempts_secondmate_charters() {
  local home
  home=$(policy_home mate <<'EOF'
# Secondmate charter
Replace {TASK} with the charter.
EOF
)
  run_policy "$home" spawn secondmate t-probe
  assert_equals 0 "$RC" "a secondmate charter must never be judged: $OUT"
  run_policy "$home" relaunch-preflight secondmate t-probe
  assert_equals 0 "$RC" "a secondmate relaunch must never be judged: $OUT"
  pass "policy: secondmate charters are exempt at spawn and at relaunch preflight"
}

test_policy_skips_a_missing_brief() {
  local home="$TMP_ROOT/nobrief"
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' brief-intake > "$home/config/fork-policies"
  run_policy "$home" spawn ship t-probe
  assert_equals 0 "$RC" "a missing brief must be left to upstream's own brief check: $OUT"
  pass "policy: a missing brief is skipped so upstream prints its own refusal"
}

test_policy_stays_off_unless_enabled() {
  local home="$TMP_ROOT/notenabled"
  mkdir -p "$home/config" "$home/state" "$home/data/t-probe"
  printf '%s\n' project-pin > "$home/config/fork-policies"
  printf '%s\n' "## Captain's intent" "Ship it." > "$home/data/t-probe/brief.md"
  run_policy "$home" spawn ship t-probe
  assert_equals 0 "$RC" "an unmarked brief must pass while brief-intake is not enabled: $OUT"
  pass "policy: brief-intake judges nothing until its name is in config/fork-policies"
}

# --- integration: the REAL dispatch path through HK1 ------------------------

# new_spawn_case <name> <id>: fixture home, project worktree, fake tools, and
# a brief scaffolded by the REAL bin/fm-brief.sh with its placeholders filled
# but no intake markers yet. Sets CASE HOME_DIR PROJ WT FAKEBIN LAUNCH_LOG BRIEF.
new_spawn_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  BRIEF="$HOME_DIR/data/$2/brief.md"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" codex
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$2" some-proj --mode direct-PR >/dev/null \
    || fail "bin/fm-brief.sh could not scaffold $2"
  fill_and_mark "$BRIEF" "Slice T1 only; the plan reference stays in the brief body."
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes)
  : > "$LAUNCH_LOG"
}

spawn_ship() { # <id> [extra fm-spawn args...]
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$id" "$PROJ" --mode direct-PR --yolo off "$@"
}

test_dispatch_refuses_then_launches_on_markers() {
  local out rc
  new_spawn_case intake t-intake
  fork_policies "$HOME_DIR" brief-intake
  out=$(spawn_ship t-intake); rc=$?
  [ "$rc" -ne 0 ] || fail "the dispatch path must refuse a brief missing its intake markers: $out"
  assert_contains "$out" "brief intake refused" "the refusal must come from the intake preflight"
  assert_contains "$out" "Delivers: <what this slice delivers>" "the refusal must show the exact line to add"
  assert_absent "$HOME_DIR/state/t-intake.meta" "a refused dispatch must write no task record"
  assert_absent "$HOME_DIR/data/t-intake/launch-brief.md" "a refused dispatch must render no launch brief"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused dispatch must send nothing to the endpoint"
  # The exact fix the refusal asked for: add the markers, dispatch again.
  printf '%s\n' "$MARKERS" >> "$BRIEF"
  out=$(spawn_ship t-intake); rc=$?
  [ "$rc" -eq 0 ] || fail "today's scaffold plus the corrected fill must launch: $out"
  [ -f "$HOME_DIR/state/t-intake.meta" ] || fail "the corrected dispatch must write a task record: $out"
  [ -s "$LAUNCH_LOG" ] || fail "the corrected dispatch must launch the endpoint: $out"
  pass "dispatch: HK1 refuses the defective brief by name, and the corrected fill launches"
}

fork_run_tests
