#!/usr/bin/env bash
# Resource accounting for Herdr-backed holders, classified by upstream's REAL
# Herdr adapter (bin/backends/herdr.sh fm_backend_herdr_agent_state) against a
# fake `herdr` client (fork_herdr_fake). This validates how upstream's Herdr
# states feed the reservation policy; it is not a real-Herdr test.
#
# Upstream mapping under test (herdr.sh fm_backend_herdr_agent_state):
#   pane_not_found                         -> missing     (frees)
#   pane exists, agent_not_found           -> dead        (frees; no process check)
#   registered + shell-only process view   -> dead        (stale-agent; frees)
#   registered + agent or other process    -> alive       (holds)
#   any failed read, server running        -> unreadable  (holds)
#   any failed read, server stopped        -> missing     (frees)
# The policy then re-checks every Herdr `dead` through upstream's
# fm_backend_herdr_pane_process_state: only its exact `shell` verdict (positive
# proof of a shell-only pane) frees the place; agent, other, unreadable, empty,
# or unexpected output holds it.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-resource-herdr)
mkdir -p "$TMP_ROOT"
MODEL_A='strata-local/qwen-test'
OWNERS=()
SESSION=fmherdr
PANE='w1:p1'

new_case() {  # <name>: sets CASE HOME_DIR FAKE FAKEBIN SHELL_PID RES
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKE="$CASE/fake"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  fork_herdr_fake "$FAKEBIN" "$FAKE"
  fork_policies "$HOME_DIR" resource
  printf '%s\n' '{"strata":{"capacity":1,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  sleep 600 >/dev/null 2>&1 &
  SHELL_PID=$!
  OWNERS+=("$SHELL_PID")
  RES="$(cd "$HOME_DIR/state" && pwd -P)/fork-reservations/strata"
}
stop_owners() { local p; for p in "${OWNERS[@]}"; do kill "$p" 2>/dev/null; done; OWNERS=(); }

holder() { fork_herdr_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" "$SESSION" "$PANE" "$1" "$SHELL_PID"; }

policy() {  # <id>
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    FM_LP_PHASE=spawn FM_LP_TASK="$1" FM_LP_KIND=ship FM_LP_PROJECT="$CASE/project" \
    FM_LP_HARNESS=pi FM_LP_MODEL="$MODEL_A" FM_LP_EFFORT=default \
    FM_LP_HOME="$HOME_DIR" FM_LP_STATE="$HOME_DIR/state" FM_LP_DATA="$HOME_DIR/data" \
    FM_LP_CONFIG="$HOME_DIR/config" FM_LP_OWNER_PID=$$ "$POLICY" 2>&1
}

upstream_state() {  # upstream fm_backend_agent_state for holder h1
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 bash -c \
    '. "$1/bin/fm-backend.sh"; m="$2"; fm_backend_agent_state "$(fm_backend_of_meta "$m")" "$(fm_backend_target_of_meta "$m")"' \
    _ "$ROOT" "$HOME_DIR/state/h1.meta"
}

upstream_process_state() {  # upstream fm_backend_herdr_pane_process_state for holder h1's pane
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_process_state "$2" "$3"' \
    _ "$ROOT" "$SESSION" "$PANE"
}

expect_holder() {  # <herdr-state> <upstream-state> <policy-exit> <label>
  local out rc
  new_case "$1"
  holder "$1"
  assert_equals "$2" "$(upstream_state)" "upstream Herdr classification for $1"
  out=$(policy t-new); rc=$?
  expect_code "$3" "$rc" "policy verdict for a Herdr holder in state $1: $out"
  stop_owners
  pass "herdr: $4"
}

test_live_agent_holds() { expect_holder live alive 1 "a registered agent with a Pi process reads alive and holds the place"; }
test_registered_other_holds() { expect_holder live-other alive 1 "a registered agent with a non-shell foreground reads alive and holds"; }
test_process_info_failure_holds() { expect_holder proc-fail unreadable 1 "a registered agent whose process view fails reads unreadable and holds (fail closed)"; }
test_garbage_answer_holds() { expect_holder garbage unreadable 1 "an unparseable Herdr answer with the server running reads unreadable and holds"; }
test_gone_pane_frees() { expect_holder gone missing 0 "a pane Herdr reports not found reads missing and frees the place"; }
test_unregistered_shell_frees() { expect_holder no-agent dead 0 "a pane with nothing registered and only a shell reads dead and frees"; }
test_stale_registration_frees() { expect_holder stale-agent dead 0 "a registration lingering over a shell-only pane reads dead and frees"; }

test_stopped_server_frees_only_with_positive_evidence() {
  local out rc
  new_case stopped
  holder garbage
  printf 'stopped\n' > "$FAKE/herdr/$SESSION/server"
  assert_equals missing "$(upstream_state)" "a failed read on a positively stopped server reads missing"
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "a holder whose Herdr server is positively stopped frees the place: $out"
  printf 'garbage\n' > "$FAKE/herdr/$SESSION/server"
  assert_equals unreadable "$(upstream_state)" "a failed read whose server state is also unreadable stays unreadable"
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "an unconfirmable server state must hold the place: $out"
  stop_owners
  pass "herdr: a failed read frees only when the server is positively stopped; otherwise it holds"
}

test_reservation_covers_unregistered_startup_within_grace() {
  local out rc gone
  new_case startup
  holder no-agent
  sleep 0 & gone=$!; wait "$gone" 2>/dev/null
  mkdir -p "$RES"
  jq -n --arg home "$(cd "$HOME_DIR/state" && pwd -P)" --argjson pid "$gone" --argjson created "$(( $(date +%s) - 60 ))" \
    '{v: 1, task: "h1", home_state: $home, resource: "strata", model: "strata-local/qwen-test", phase: "spawn",
      owner_pid: $pid, owner_start: "Wed Jan  1 00:00:00 2025", created: $created}' > "$RES/h1.test.json"
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "inside the grace a reservation must hold for an agent Herdr does not yet show: $out"
  assert_contains "$out" "h1(starting, " "the refusal must name the starting launch"
  jq '.created -= 120' "$RES/h1.test.json" > "$RES/h1.next" && mv "$RES/h1.next" "$RES/h1.test.json"
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "past the grace, an unregistered pane no longer holds (the documented residual risk): $out"
  stop_owners
  pass "herdr: the reservation holds an unregistered starting pane only for the 120s grace"
}

# --- the unregistered-pane re-check (upstream process-state contract) --------

# expect_unregistered <fixture-state> <process-verdict> <policy-exit> <label>:
# upstream reads the pane `dead` (no registered agent); the policy's verdict
# follows upstream's process view of that pane.
expect_unregistered() {
  local out rc
  new_case "$1"
  holder "$1"
  assert_equals dead "$(upstream_state)" "upstream must read an unregistered pane ($1) as dead"
  assert_equals "$2" "$(upstream_process_state)" "upstream process view for $1"
  out=$(policy t-new); rc=$?
  expect_code "$3" "$rc" "policy verdict for an unregistered Herdr pane ($1): $out"
  if [ "$3" -ne 0 ]; then
    assert_contains "$out" "h1(herdr pane has no registered agent but its processes read $2)" "the refusal must name the process verdict"
  fi
  stop_owners
  pass "herdr re-check: $4"
}

test_unregistered_running_pi_holds() { expect_unregistered no-agent-pi agent 1 "an unregistered pane with a running Pi holds (closes the startup race)"; }
test_unregistered_shell_only_frees() { expect_unregistered no-agent shell 0 "an unregistered pane proven shell-only frees"; }
test_unregistered_other_process_holds() { expect_unregistered no-agent-other other 1 "an unregistered pane running a non-shell process holds"; }
test_unregistered_process_info_failure_holds() { expect_unregistered no-agent-procfail unreadable 1 "an unregistered pane whose process-info fails holds"; }
test_unregistered_malformed_process_info_holds() { expect_unregistered no-agent-malformed unreadable 1 "an unregistered pane whose process-info is malformed holds"; }

test_stale_registration_proven_shell_still_frees() {
  local out rc
  new_case stale-recheck
  holder stale-agent
  assert_equals shell "$(upstream_process_state)" "a stale registration's pane is shell-only"
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "the re-check must not change a stale registration proven shell-only: $out"
  stop_owners
  pass "herdr re-check: a stale registration over a proven shell-only pane still frees"
}

test_harness_descendant_of_pane_shell_holds() {
  local out rc shell child
  new_case descendant
  # The pane shell's foreground shows only a shell, but a harness still runs
  # beneath it in the real process table (backgrounded or suspended).
  bash -c '(exec -a pi sleep 600) & wait' >/dev/null 2>&1 &
  shell=$!
  OWNERS+=("$shell")
  child=''
  for _ in $(seq 1 50); do child=$(pgrep -P "$shell" 2>/dev/null | head -1); [ -n "$child" ] && break; sleep 0.05; done
  [ -n "$child" ] || fail "could not start the descendant harness fixture"
  OWNERS+=("$child")
  fork_herdr_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" "$SESSION" "$PANE" no-agent "$shell"
  assert_equals agent "$(upstream_process_state)" "upstream must find a harness descending from the pane shell"
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "a harness beneath the pane shell must hold the place: $out"
  stop_owners
  pass "herdr re-check: a harness running beneath an idle-looking pane shell holds (real process table)"
}

test_shell_pid_missing_from_process_table_holds() {
  local out rc gone
  new_case shellgone
  sleep 0 & gone=$!; wait "$gone" 2>/dev/null
  fork_herdr_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" "$SESSION" "$PANE" no-agent "$gone"
  assert_equals unreadable "$(upstream_process_state)" "a pane shell absent from the process table is unreadable"
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "an unverifiable pane shell must hold the place: $out"
  stop_owners
  pass "herdr re-check: a pane shell that is not in the process table holds"
}

test_process_check_unavailable_holds() {
  local out rc
  new_case nops
  holder no-agent
  assert_equals unreadable "$(FM_HERDR_PS_BIN=/nonexistent/ps upstream_process_state)" "an unavailable process table read is unreadable"
  out=$(FM_HERDR_PS_BIN=/nonexistent/ps policy t-new); rc=$?
  expect_code 1 "$rc" "an unavailable process check must hold the place: $out"
  stop_owners
  pass "herdr re-check: an unavailable process check holds"
}

test_reservation_past_grace_with_unregistered_pi_holds() {
  local out rc gone
  new_case startup-pi
  holder no-agent-pi
  sleep 0 & gone=$!; wait "$gone" 2>/dev/null
  mkdir -p "$RES"
  jq -n --arg home "$(cd "$HOME_DIR/state" && pwd -P)" --argjson pid "$gone" --argjson created "$(( $(date +%s) - 600 ))" \
    '{v: 1, task: "h1", home_state: $home, resource: "strata", model: "strata-local/qwen-test", phase: "spawn",
      owner_pid: $pid, owner_start: "Wed Jan  1 00:00:00 2025", created: $created}' > "$RES/h1.test.json"
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "past the grace, a running but unregistered Pi must still hold the place: $out"
  assert_contains "$out" "processes read agent" "the hold must come from the process re-check"
  [ ! -e "$RES/h1.test.json" ] || fail "the expired reservation itself must still be cleaned up"
  stop_owners
  pass "herdr re-check: after the grace expires, a running unregistered Pi still holds through its process view"
}

# Upstream evidence the re-check depends on: upstream itself still reads an
# unregistered pane as dead even with a Pi process in it.
test_characterize_upstream_unregistered_running_pi_reads_dead() {
  new_case unregistered-pi
  holder no-agent-pi
  assert_equals dead "$(upstream_state)" "upstream reads an unregistered pane as dead even with a Pi process in it"
  stop_owners
  pass "herdr (characterization): upstream reads an unregistered pane dead even while a Pi process runs in it"
}

fork_run_tests
