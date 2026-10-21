#!/usr/bin/env bash
# Resource policy end to end: a launch attempt through the REAL upstream
# bin/fm-spawn.sh (HK1) while another task already holds the machine resource.
# Upstream's spawn stub serves the launch path; fork_liveness_fakes answers only
# the holder's endpoint, so upstream's fm_backend_agent_state classifies it.
# A refused launch must leave no task record, launch brief, or launch.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-resource-e2e)
mkdir -p "$TMP_ROOT"
MODEL_A='strata-local/qwen-test'

# new_e2e_case <name> <id>: sets CASE HOME_DIR PROJ WT FAKEBIN FAKE LAUNCH_LOG.
new_e2e_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKE="$CASE/fake"
  LAUNCH_LOG="$CASE/launch.log"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes)
  fork_liveness_fakes "$FAKEBIN" "$FAKE"
  fork_policies "$HOME_DIR" resource
  printf '%s\n' '{"strata":{"capacity":1,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  : > "$LAUNCH_LOG"
}

spawn_on_resource() {  # <id>
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$1" "$PROJ" --mode no-mistakes --yolo off --model "$MODEL_A"
}

assert_nothing_created() {  # <id> <rc> <output>
  [ "$2" -ne 0 ] || fail "expected the launch of $1 to be refused, but fm-spawn exited 0: $3"
  assert_absent "$HOME_DIR/state/$1.meta" "a refused launch of $1 wrote a task record"
  assert_absent "$HOME_DIR/data/$1/launch-brief.md" "a refused launch of $1 rendered a launch brief"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused launch of $1 sent a launch command to the endpoint"
}

test_live_holder_refuses_real_spawn() {
  local out rc
  new_e2e_case live t-second
  fork_holder "$HOME_DIR" "$FAKE" t-first "$MODEL_A" alive
  out=$(spawn_on_resource t-second); rc=$?
  assert_nothing_created t-second "$rc" "$out"
  assert_contains "$out" "machine resource strata is at capacity (1 of 1 live)" "the refusal must name the resource"
  pass "e2e: a real spawn on a single-slot resource is refused while another task's agent is live"
}

test_unreadable_holder_refuses_real_spawn() {
  local out rc
  new_e2e_case unreadable t-second
  fork_holder "$HOME_DIR" "$FAKE" t-first "$MODEL_A" alive
  : > "$FAKE/inventory-broken"
  out=$(spawn_on_resource t-second); rc=$?
  assert_nothing_created t-second "$rc" "$out"
  assert_contains "$out" "t-first(unreadable)" "the refusal must name the holder whose liveness is unconfirmed"
  pass "e2e: a real spawn is refused when the holder's liveness cannot be read"
}

test_ambiguous_holder_refuses_real_spawn() {
  local out rc
  new_e2e_case ambiguous t-second
  fork_holder "$HOME_DIR" "$FAKE" t-first "$MODEL_A" ambiguous
  out=$(spawn_on_resource t-second); rc=$?
  assert_nothing_created t-second "$rc" "$out"
  assert_contains "$out" "t-first(ambiguous)" "the refusal must name the ambiguous holder"
  pass "e2e: a real spawn is refused when the holder's process cannot be attributed"
}

test_exited_holder_allows_real_spawn() {
  local out
  new_e2e_case exited t-second
  fork_holder "$HOME_DIR" "$FAKE" t-first "$MODEL_A" dead
  out=$(spawn_on_resource t-second)
  [ -f "$HOME_DIR/state/t-second.meta" ] || fail "a holder proven dead must not block the launch: $out"
  [ -s "$LAUNCH_LOG" ] || fail "the allowed launch sent nothing to the endpoint: $out"
  assert_grep "model=$MODEL_A" "$HOME_DIR/state/t-second.meta" "the launched task must record the resource model"
  pass "e2e: a real spawn proceeds once the previous holder's agent is proven gone"
}

fork_run_tests
