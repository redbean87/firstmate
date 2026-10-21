#!/usr/bin/env bash
# HK2: fork launch policy through the REAL upstream bin/fm-control.sh relaunch.
# A refused relaunch must leave the running agent untouched (no exit sent, task
# record unchanged); an allowed relaunch must run the full upstream transaction,
# with HK1 then judging the replacement launch inside fm-spawn --relaunch.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
fork_lift_relaunch_fixture

# Read by the fixture functions lifted from upstream's relaunch suite.
# shellcheck disable=SC2034
CONTROL="$ROOT/bin/fm-control.sh"
# shellcheck disable=SC2034
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-relaunch-policy)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
# shellcheck disable=SC2034 # appended to by the lifted add_ship_task
TASK_TMPS=()

agent_untouched() {  # <case-dir> <id> <meta-before>
  if grep -q '/exit' "$1/fake/literal"; then fail "a refused relaunch of $2 sent the running agent an exit"; fi
  [ "$3" = "$(cat "$1/home/state/$2.meta")" ] || fail "a refused relaunch of $2 changed its task record"
  assert_absent "$1/home/state/$2.control-relaunch" "a refused relaunch of $2 opened a relaunch transaction"
}

test_inactive_relaunch_is_upstream() {
  local dir out rc
  dir=$(new_case inactive r-inactive)
  add_ship_task "$dir" r-inactive claude
  out=$(run_control "$dir" r-inactive relaunch --note "resume the refactor"); rc=$?
  expect_code 0 "$rc" "without config/fork-policies a relaunch must behave as upstream"$'\n'"$out"
  assert_grep "/exit" "$dir/fake/literal" "an inactive relaunch should replace the agent"
  pass "HK2 inactive: relaunch runs the upstream transaction unchanged"
}

test_consult_gate_refuses_before_agent_stops() {
  local dir out rc before
  dir=$(new_case gate r-none)
  add_ship_task "$dir" r-none claude
  fork_policies "$dir/home" consult-gate
  before=$(cat "$dir/home/state/r-none.meta")
  out=$(run_control "$dir" r-none relaunch --note "resume"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch with no consultation evidence must be refused"$'\n'"$out"
  agent_untouched "$dir" r-none "$before"
  assert_contains "$out" "the running agent was not stopped" "the refusal must say the agent kept running"
  assert_contains "$out" "no stored ChatGPT prompt" "the refusal must name its cause"
  pass "HK2 consult-gate: refused before the running agent is stopped; record and agent untouched"
}

test_delivery_proof_allows_relaunch_and_hk1_rejudges() {
  local dir out rc
  dir=$(new_case delivered r-dlv)
  add_ship_task "$dir" r-dlv claude
  fork_policies "$dir/home" consult-gate
  printf '%s\n' '{"stage":"plan"}' > "$dir/home/data/r-dlv/fork-consult-delivered.json"
  out=$(FM_FORK_POLICY_TRACE="$dir/trace" run_control "$dir" r-dlv relaunch --note "resume"); rc=$?
  expect_code 0 "$rc" "delivery proof must allow the relaunch"$'\n'"$out"
  assert_grep "/exit" "$dir/fake/literal" "an allowed relaunch should replace the agent"
  [ -f "$dir/trace.relaunch-preflight" ] || fail "HK2 did not run before the agent was stopped"
  [ -f "$dir/trace.relaunch" ] || fail "HK1 did not judge the replacement launch inside fm-spawn --relaunch"
  pass "HK2 consult-gate: delivery proof allows; HK2 runs before the stop and HK1 re-judges the replacement"
}

test_discord_waiver_refuses_relaunch() {
  local dir out rc before
  dir=$(new_case discord r-discord)
  add_ship_task "$dir" r-discord claude
  fork_policies "$dir/home" consult-gate
  fork_waiver "$dir/home" r-discord discord
  before=$(cat "$dir/home/state/r-discord.meta")
  out=$(run_control "$dir" r-discord relaunch --note "resume"); rc=$?
  [ "$rc" -ne 0 ] || fail "a Discord-origin waiver must not allow a relaunch"$'\n'"$out"
  agent_untouched "$dir" r-discord "$before"
  pass "HK2 consult-gate: a Discord-origin waiver is refused before the agent stops"
}

test_pin_refuses_harness_switch_before_agent_stops() {
  local dir out rc before
  dir=$(new_case pin r-pin)
  add_ship_task "$dir" r-pin claude
  fork_policies "$dir/home" project-pin
  printf '%s\n' '{"projects":{"proj":{"harness":"claude"}}}' > "$dir/home/config/fork-project-pins.json"
  before=$(cat "$dir/home/state/r-pin.meta")
  out=$(run_control "$dir" r-pin relaunch --harness codex --note "switch"); rc=$?
  [ "$rc" -ne 0 ] || fail "relaunching a pinned project onto another harness must be refused"$'\n'"$out"
  agent_untouched "$dir" r-pin "$before"
  assert_contains "$out" "pinned to harness claude" "the refusal must name the pin"
  pass "HK2 project-pin: a harness switch off the pin is refused before the agent stops"
}

test_malformed_policy_refuses_before_agent_stops() {
  local dir out rc before
  dir=$(new_case malformed r-bad)
  add_ship_task "$dir" r-bad claude
  fork_policies "$dir/home" consult-gate nonsense
  before=$(cat "$dir/home/state/r-bad.meta")
  out=$(run_control "$dir" r-bad relaunch --note "resume"); rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed policy list must refuse the relaunch"$'\n'"$out"
  agent_untouched "$dir" r-bad "$before"
  pass "HK2 fail-closed: a malformed policy list refuses before the agent stops"
}

test_hk2_passes_contract_values() {
  local dir out trace
  dir=$(new_case contract r-contract)
  add_ship_task "$dir" r-contract claude
  fork_policies "$dir/home" consult-gate
  fork_waiver "$dir/home" r-contract local
  out=$(FM_FORK_POLICY_TRACE="$dir/trace" run_control "$dir" r-contract relaunch --note "resume") \
    || fail "contract relaunch failed: $out"
  trace="$dir/trace.relaunch-preflight"
  assert_grep "FM_LP_PHASE=relaunch-preflight" "$trace" "HK2 must report the preflight phase"
  assert_grep "FM_LP_TASK=r-contract" "$trace" "HK2 must pass the task id"
  assert_grep "FM_LP_KIND=ship" "$trace" "HK2 must pass the recorded kind"
  assert_grep "FM_LP_PROJECT=$dir/proj" "$trace" "HK2 must pass the recorded project (meta project=)"
  assert_grep "FM_LP_HARNESS=claude" "$trace" "HK2 must pass the relaunch target harness"
  assert_grep "FM_LP_MODEL=default" "$trace" "HK2 must pass the relaunch target model"
  assert_grep "FM_LP_CONFIG=$dir/home/config" "$trace" "HK2 must pass the home's config directory"
  pass "contract: HK2 passes phase, task, recorded kind and project, and the relaunch target profile"
}

fork_run_tests
