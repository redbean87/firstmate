#!/usr/bin/env bash
# Shared helpers for the fork's own test suite (fork/tests/*.test.sh).
#
# Fork tests drive the REAL upstream bin/fm-spawn.sh and bin/fm-control.sh so
# they prove the hook wiring, not a copy of it. They reuse upstream's shared
# test libraries (tests/lib.sh, tests/fixtures.sh), which CONTRIBUTING.md
# documents as the helpers suites source, and never edit upstream tests.
# Relaunch tests additionally lift four fixture functions from upstream's
# relaunch suite (fork_lift_relaunch_fixture); a renamed or removed function
# stops the suite with FIXTURE-DRIFT instead of silently testing less.

FORK_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/fixtures.sh
. "$FORK_TESTS_DIR/../../tests/fixtures.sh"
# shellcheck disable=SC2034 # read by the test files that source this library
POLICY="$ROOT/fork/bin/fm-launch-policy"

# fork_run_tests: run every test_* function in its own subshell so one failure
# reports and the rest still run; exit non-zero if any failed.
fork_run_tests() {
  local t rc=0
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    ( "$t" ) || rc=1
  done
  return "$rc"
}

# fork_policies <home> <policy...>: activate fork policy in a fixture home.
fork_policies() {
  local home=$1
  shift
  mkdir -p "$home/config"
  printf '%s\n' "$@" > "$home/config/fork-policies"
}

# fork_loop_record <home> <id> <phase> <field> <text>: a ChatGPT loop record.
fork_loop_record() {
  mkdir -p "$1/data/$2"
  jq -n --arg phase "$3" --arg field "$4" --arg text "$5" '{phase: $phase} + {($field): $text}' \
    > "$1/data/$2/chatgpt-loop.json"
}

# fork_waiver <home> <id> <origin> [reason]
fork_waiver() {
  mkdir -p "$1/data/$2"
  jq -n --arg origin "$3" --arg reason "${4-bridge unavailable, captain approved proceeding}" \
    '{origin: $origin, reason: $reason}' > "$1/data/$2/fork-consult-waiver.json"
}

# fork_lift_relaunch_fixture: define upstream's relaunch-suite fixture
# functions (tmux lifecycle stub, case builder, live ship task, control runner).
fork_lift_relaunch_fixture() {
  local suite="$ROOT/tests/fm-control-relaunch.test.sh" fn body
  for fn in make_tmux_stub new_case add_ship_task run_control; do
    body=$(sed -n "/^$fn() {/,/^}/p" "$suite")
    if [ -z "$body" ]; then
      printf 'not ok - FIXTURE-DRIFT: %s no longer defines %s(); update fork/tests/lib.sh\n' "${suite#"$ROOT"/}" "$fn" >&2
      exit 3
    fi
    eval "$body"
  done
}
