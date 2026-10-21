#!/usr/bin/env bash
# HK1: fork launch policy through the REAL upstream bin/fm-spawn.sh.
# A refused launch must leave no task record, no launch brief, and no launch;
# a home without config/fork-policies must spawn exactly as upstream does.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-spawn-policy)
mkdir -p "$TMP_ROOT"

# new_spawn_case <name> <id>: sets CASE HOME_DIR PROJ WT FAKEBIN LAUNCH_LOG.
new_spawn_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  mkdir -p "$CASE"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes)
  : > "$LAUNCH_LOG"
}

spawn_ship() {  # <id> [extra fm-spawn args...]
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

assert_launched() {  # <id> <output>
  [ -f "$HOME_DIR/state/$1.meta" ] || fail "expected $1 to launch, but no task record was written: $2"
  [ -s "$LAUNCH_LOG" ] || fail "expected $1 to launch, but nothing was sent to the endpoint: $2"
}

assert_refused() {  # <id> <rc> <output> <expected text>
  [ "$2" -ne 0 ] || fail "expected $1 to be refused, but fm-spawn exited 0: $3"
  assert_absent "$HOME_DIR/state/$1.meta" "a refused launch of $1 wrote a task record"
  assert_absent "$HOME_DIR/data/$1/launch-brief.md" "a refused launch of $1 rendered a launch brief"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused launch of $1 sent a launch command to the endpoint"
  assert_contains "$3" "$4" "the refusal for $1 must name its cause"
}

test_inactive_home_spawns_as_upstream() {
  local out
  new_spawn_case inactive t-inactive
  out=$(spawn_ship t-inactive)
  assert_launched t-inactive "$out"
  pass "inactive: without config/fork-policies a launch with no consultation record proceeds as upstream"
}

test_consult_gate_refuses_without_record() {
  local out rc
  new_spawn_case gate-none t-none
  fork_policies "$HOME_DIR" consult-gate
  out=$(spawn_ship t-none); rc=$?
  assert_refused t-none "$rc" "$out" "no stored ChatGPT prompt"
  pass "consult-gate: a ship with no stored prompt or waiver is refused before any record or launch"
}

test_consult_gate_allows_stored_stage_prompt() {
  local out
  new_spawn_case gate-ok t-ok
  fork_policies "$HOME_DIR" consult-gate
  fork_loop_record "$HOME_DIR" t-ok audit-dispatch audit_prompt "Audit the parser."
  out=$(spawn_ship t-ok)
  assert_launched t-ok "$out"
  pass "consult-gate: a stored prompt for the phase's stage allows the launch"
}

test_consult_gate_refuses_phase_without_prompt() {
  local out rc
  new_spawn_case gate-phase t-phase
  fork_policies "$HOME_DIR" consult-gate
  fork_loop_record "$HOME_DIR" t-phase audit-consult audit_prompt ""
  out=$(spawn_ship t-phase); rc=$?
  assert_refused t-phase "$rc" "$out" "no prompt for the stage"
  pass "consult-gate: a record still at its consult phase does not satisfy the gate"
}

test_consult_gate_refuses_delivery_proof_on_fresh_spawn() {
  local out rc
  new_spawn_case gate-dlv t-dlv
  fork_policies "$HOME_DIR" consult-gate
  printf '%s\n' '{"stage":"plan"}' > "$HOME_DIR/data/t-dlv/fork-consult-delivered.json"
  out=$(spawn_ship t-dlv); rc=$?
  assert_refused t-dlv "$rc" "$out" "no stored ChatGPT prompt"
  pass "consult-gate: delivery proof counts only for a relaunch, never a fresh spawn"
}

test_local_waiver_allows_discord_waiver_refuses() {
  local out rc
  new_spawn_case waiver-local t-local
  fork_policies "$HOME_DIR" consult-gate
  fork_waiver "$HOME_DIR" t-local local
  out=$(spawn_ship t-local)
  assert_launched t-local "$out"
  new_spawn_case waiver-discord t-discord
  fork_policies "$HOME_DIR" consult-gate
  fork_waiver "$HOME_DIR" t-discord discord
  out=$(spawn_ship t-discord); rc=$?
  assert_refused t-discord "$rc" "$out" "did not originate locally"
  pass "consult-gate: a local recorded waiver allows; a Discord-origin waiver is refused"
}

test_waiver_needs_one_line_reason() {
  local out rc
  new_spawn_case waiver-reason t-reason
  fork_policies "$HOME_DIR" consult-gate
  fork_waiver "$HOME_DIR" t-reason local "   "
  out=$(spawn_ship t-reason); rc=$?
  assert_refused t-reason "$rc" "$out" "one-line reason"
  pass "consult-gate: a local waiver with a blank reason is refused"
}

test_malformed_records_fail_closed() {
  local out rc
  new_spawn_case bad-loop t-badloop
  fork_policies "$HOME_DIR" consult-gate
  printf '{not json\n' > "$HOME_DIR/data/t-badloop/chatgpt-loop.json"
  out=$(spawn_ship t-badloop); rc=$?
  assert_refused t-badloop "$rc" "$out" "is not a JSON object"
  pass "fail-closed: an unreadable consultation record refuses the launch"
}

test_project_pin() {
  local out rc
  new_spawn_case pin-bad t-pinbad
  fork_policies "$HOME_DIR" project-pin
  printf '%s\n' '{"projects":{"project":{"harness":"pi"}}}' > "$HOME_DIR/config/fork-project-pins.json"
  out=$(spawn_ship t-pinbad); rc=$?
  assert_refused t-pinbad "$rc" "$out" "pinned to harness pi"
  new_spawn_case pin-ok t-pinok
  fork_policies "$HOME_DIR" project-pin
  printf '%s\n' '{"projects":{"project":{"harness":"codex"}}}' > "$HOME_DIR/config/fork-project-pins.json"
  out=$(spawn_ship t-pinok)
  assert_launched t-pinok "$out"
  pass "project-pin: a launch off the pin is refused; a launch on the pin proceeds"
}

test_project_pin_refuses_raw_launch() {
  local out rc
  new_spawn_case pin-raw t-pinraw
  fork_policies "$HOME_DIR" project-pin
  printf '%s\n' '{"projects":{"project":{"harness":"codex"}}}' > "$HOME_DIR/config/fork-project-pins.json"
  out=$(spawn_ship t-pinraw --harness "codex --model x"); rc=$?
  assert_refused t-pinraw "$rc" "$out" "raw launch command"
  pass "project-pin: a raw launch command on a pinned project is refused"
}

test_malformed_policy_configuration_fails_closed() {
  local out rc
  new_spawn_case cfg-unknown t-unknown
  fork_policies "$HOME_DIR" consult-gate bogus
  fork_loop_record "$HOME_DIR" t-unknown plan-dispatch plan "Do it."
  out=$(spawn_ship t-unknown); rc=$?
  assert_refused t-unknown "$rc" "$out" "unknown policy 'bogus'"
  new_spawn_case cfg-empty t-empty
  printf '# nothing enabled\n' > "$HOME_DIR/config/fork-policies"
  out=$(spawn_ship t-empty); rc=$?
  assert_refused t-empty "$rc" "$out" "enables no policy"
  new_spawn_case cfg-pins t-badpins
  fork_policies "$HOME_DIR" project-pin
  printf '%s\n' '{"projects":["not","an","object"]}' > "$HOME_DIR/config/fork-project-pins.json"
  out=$(spawn_ship t-badpins); rc=$?
  assert_refused t-badpins "$rc" "$out" "fork-project-pins.json is malformed"
  pass "fail-closed: unknown policy, empty policy list, and malformed pins all refuse"
}

test_unexecutable_policy_script_refuses() {
  local out rc
  new_spawn_case cfg-noexec t-noexec
  fork_policies "$HOME_DIR" consult-gate
  fork_loop_record "$HOME_DIR" t-noexec plan-dispatch plan "Do it."
  chmod -x "$POLICY"
  out=$(spawn_ship t-noexec); rc=$?
  chmod +x "$POLICY"
  assert_refused t-noexec "$rc" "$out" "fm-launch-policy"
  pass "fail-closed: an active home whose policy script cannot run refuses the launch"
}

test_hook_passes_contract_values() {
  local out trace
  new_spawn_case contract t-contract
  fork_policies "$HOME_DIR" consult-gate
  fork_loop_record "$HOME_DIR" t-contract plan-dispatch plan "Do it."
  out=$(FM_FORK_POLICY_TRACE="$CASE/trace" spawn_ship t-contract --model gpt-test --effort high)
  assert_launched t-contract "$out"
  trace="$CASE/trace.spawn"
  assert_grep "FM_LP_TASK=t-contract" "$trace" "HK1 must pass the task id"
  assert_grep "FM_LP_KIND=ship" "$trace" "HK1 must pass the task kind"
  assert_grep "FM_LP_PHASE=spawn" "$trace" "HK1 must report a fresh spawn"
  assert_grep "FM_LP_HARNESS=codex" "$trace" "HK1 must pass the resolved harness"
  assert_grep "FM_LP_MODEL=gpt-test" "$trace" "HK1 must pass the model"
  assert_grep "FM_LP_EFFORT=high" "$trace" "HK1 must pass the effort"
  assert_grep "FM_LP_PROJECT=$PROJ" "$trace" "HK1 must pass the project directory"
  assert_grep "FM_LP_CONFIG=$HOME_DIR/config" "$trace" "HK1 must pass the home's config directory"
  assert_grep "FM_LP_STATE=$HOME_DIR/state" "$trace" "HK1 must pass the home's state directory"
  if grep -q '^FM_LP_RAW_LAUNCH=.' "$trace"; then fail "HK1 must not pass a raw launch for a named harness"; fi
  assert_grep "project=" "$HOME_DIR/state/t-contract.meta" "upstream must record project= in the task record (HK2 reads it)"
  pass "contract: HK1 passes the resolved task, kind, phase, harness, model, effort, project and home paths"
}

fork_run_tests
