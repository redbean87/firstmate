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

# --- reservations through the real fm-spawn ----------------------------------

# second_project <name>: another project and worktree in the same case home;
# sets PROJ2 WT2.
second_project() {
  PROJ2="$CASE/project-$1"
  WT2="$CASE/wt-$1"
  fm_git_worktree "$PROJ2" "$WT2" "wt2-$1"
  fm_test_spawn_brief "$HOME_DIR" "$2"
}

spawn_in() {  # <id> <project> <worktree>
  FM_FAKE_LAUNCH_LOG="$CASE/launch-$1.log" fm_test_run_spawn "$HOME_DIR" "$3" "$FAKEBIN" \
    "$1" "$2" --mode no-mistakes --yolo off --model "$MODEL_A"
}

# move_endpoint_to_holders <id> <comm>: model <id>'s recorded endpoint as a
# window in the liveness fixture's holder session whose foreground is <comm>
# (pi = agent running, zsh = only a shell, agent not started). Upstream's spawn
# stub keeps serving the spawn's own session untouched.
move_endpoint_to_holders() {
  local meta="$HOME_DIR/state/$1.meta"
  sed "s/^window=.*/window=$FORK_HOLDER_SESSION:fm-$1/" "$meta" > "$meta.new" && mv "$meta.new" "$meta"
  printf '%s\n' "fm-$1" > "$FAKE/windows"
  printf '%s\n' "$2" > "$FAKE/comm.fm-$1"
  printf '%s\n' 43001 > "$FAKE/pid.fm-$1"
}

reservation_of() {  # <id> -> reservation file for <id>
  find "$(cd "$HOME_DIR/state" && pwd -P)/fork-reservations/strata" -name "$1.*.json" 2>/dev/null | head -1
}

test_second_launch_refused_while_first_is_starting() {
  local out rc f
  new_e2e_case starting t-first
  second_project starting t-second
  out=$(spawn_on_resource t-first)
  [ -f "$HOME_DIR/state/t-first.meta" ] || fail "the first launch must succeed: $out"
  f=$(reservation_of t-first)
  [ -n "$f" ] || fail "the first launch must leave a reservation"
  if LC_ALL=C ps -p "$(jq -r .owner_pid "$f")" >/dev/null 2>&1; then
    fail "the reservation owner must be the fm-spawn that has now exited"
  fi
  # The first endpoint exists but its agent has not started: only a shell runs
  # there, so its record reads dead and only the reservation holds the place.
  move_endpoint_to_holders t-first zsh
  out=$(spawn_in t-second "$PROJ2" "$WT2"); rc=$?
  [ "$rc" -ne 0 ] || fail "a second launch while the first agent is still starting must be refused: $out"
  assert_absent "$HOME_DIR/state/t-second.meta" "the refused second launch wrote a task record"
  assert_contains "$out" "t-first(starting" "the refusal must name the first launch as still starting"
  pass "e2e: a second real launch is refused while the first launch's agent is still starting (reservation grace)"
}

test_second_launch_refused_while_first_is_running() {
  local out rc f
  new_e2e_case running t-first
  second_project running t-second
  out=$(spawn_on_resource t-first)
  [ -f "$HOME_DIR/state/t-first.meta" ] || fail "the first launch must succeed: $out"
  f=$(reservation_of t-first)
  jq '.created -= 3600' "$f" > "$f.new" && mv "$f.new" "$f"
  # The first agent is now running in its recorded endpoint.
  move_endpoint_to_holders t-first pi
  out=$(spawn_in t-second "$PROJ2" "$WT2"); rc=$?
  [ "$rc" -ne 0 ] || fail "a second launch while the first agent runs must be refused even after its reservation expired: $out"
  assert_contains "$out" "(1 of 1 live)" "the running first task must hold the place through its record"
  printf 'zsh\n' > "$FAKE/comm.fm-t-first"
  out=$(spawn_in t-second "$PROJ2" "$WT2")
  [ -f "$HOME_DIR/state/t-second.meta" ] || fail "once the first agent is proven gone the second launch must proceed: $out"
  pass "e2e: a second real launch is refused while the first runs, and admitted once it is proven gone"
}

test_simultaneous_real_launches_admit_one() {
  local admitted=0 id
  new_e2e_case simultaneous t-a
  second_project simultaneous t-b
  spawn_on_resource t-a > "$CASE/a.out" 2>&1 &
  local pa=$!
  spawn_in t-b "$PROJ2" "$WT2" > "$CASE/b.out" 2>&1 &
  local pb=$!
  wait "$pa"; wait "$pb"
  for id in t-a t-b; do [ ! -f "$HOME_DIR/state/$id.meta" ] || admitted=$((admitted + 1)); done
  assert_equals 1 "$admitted" "exactly one of two simultaneous real launches in different projects may start (a: $(tail -1 "$CASE/a.out"); b: $(tail -1 "$CASE/b.out"))"
  pass "e2e: two simultaneous real launches in different projects on one single-slot resource admit exactly one"
}

fork_run_tests
