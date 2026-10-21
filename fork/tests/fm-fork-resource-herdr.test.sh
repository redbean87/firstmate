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

# Residual-risk evidence, not desired behaviour: upstream classifies an
# unregistered pane as dead without reading its processes, so a Pi that is
# running but has not registered with Herdr is invisible to the policy once
# its reservation's grace has passed. See fork/README "Known limits".
test_characterize_unregistered_running_pi_reads_dead() {
  new_case unregistered-pi
  holder no-agent-pi
  assert_equals dead "$(upstream_state)" "upstream reads an unregistered pane as dead even with a Pi process in it"
  stop_owners
  pass "herdr (characterization): an unregistered pane reads dead even while a Pi process runs in it"
}

fork_run_tests
