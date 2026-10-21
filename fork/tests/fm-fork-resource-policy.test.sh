#!/usr/bin/env bash
# Resource policy: cross-project machine/model capacity, classified through
# upstream's own recovery-grade fm_backend_agent_state (bin/fm-backend.sh).
# Only a holder proven dead or missing frees a place; alive, ambiguous,
# unreadable, and unverified all hold one. The policy is called directly with
# the hook contract environment; fork_liveness_fakes (fork/tests/lib.sh) makes
# upstream's tmux adapter read each holder in the state under test.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-resource-policy)
mkdir -p "$TMP_ROOT"
MODEL_A='strata-local/qwen-test'

# new_resource_case <name>: sets CASE HOME_DIR FAKE FAKEBIN; capacity 1 for
# models starting with strata-local/.
new_resource_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKE="$CASE/fake"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  fork_liveness_fakes "$FAKEBIN" "$FAKE"
  fork_policies "$HOME_DIR" resource
  printf '%s\n' '{"strata":{"capacity":1,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
}

holder() { fork_holder "$HOME_DIR" "$FAKE" "$@"; }

# policy <id> <kind> <model> [raw-launch]: run the entry point as HK1 would.
policy() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_LP_PHASE=spawn FM_LP_TASK="$1" FM_LP_KIND="$2" FM_LP_PROJECT="$CASE/project" \
    FM_LP_HARNESS=pi FM_LP_MODEL="$3" FM_LP_EFFORT=default FM_LP_RAW_LAUNCH="${4-}" \
    FM_LP_HOME="$HOME_DIR" FM_LP_STATE="$HOME_DIR/state" FM_LP_DATA="$HOME_DIR/data" \
    FM_LP_CONFIG="$HOME_DIR/config" "$POLICY" 2>&1
}

upstream_state() {  # <id> -> upstream fm_backend_agent_state for that holder
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-backend.sh"; m="$2"; fm_backend_agent_state "$(fm_backend_of_meta "$m")" "$(fm_backend_target_of_meta "$m")"' \
    _ "$ROOT" "$HOME_DIR/state/$1.meta"
}

test_contract_upstream_states() {
  new_resource_case states
  holder h-alive "$MODEL_A" alive
  holder h-dead "$MODEL_A" dead
  holder h-amb "$MODEL_A" ambiguous
  holder h-gone "$MODEL_A" missing
  holder h-zellij "$MODEL_A" unverified
  assert_equals alive "$(upstream_state h-alive)" "an agent in the foreground must read alive"
  assert_equals dead "$(upstream_state h-dead)" "only shells in the foreground must read dead"
  assert_equals ambiguous "$(upstream_state h-amb)" "an unattributable foreground process must read ambiguous"
  assert_equals missing "$(upstream_state h-gone)" "a window absent from the inventory must read missing"
  assert_equals unverified "$(upstream_state h-zellij)" "a backend with no recovery classifier must read unverified"
  : > "$FAKE/inventory-broken"
  assert_equals unreadable "$(upstream_state h-alive)" "a failed inventory read must read unreadable"
  pass "contract: upstream fm_backend_agent_state yields alive/dead/ambiguous/missing/unverified/unreadable from the recorded endpoint"
}

test_live_holder_refuses_cross_project() {
  local out rc
  new_resource_case live
  holder other-project-task "$MODEL_A" alive
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "a second live run on a capacity-1 resource must be refused: $out"
  assert_contains "$out" "machine resource strata is at capacity (1 of 1 live)" "the refusal must name the resource"
  pass "resource: a live holder on a matching model refuses, whatever project it belongs to"
}

test_dead_or_missing_holder_frees_the_place() {
  local out rc
  new_resource_case exited
  holder h-dead "$MODEL_A" dead
  holder h-gone "$MODEL_A" missing
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "holders proven dead or missing must not hold the resource: $out"
  pass "resource: only a holder proven dead or missing frees its place"
}

test_unreadable_liveness_fails_closed() {
  local out rc
  new_resource_case unreadable
  holder h-live "$MODEL_A" alive
  : > "$FAKE/inventory-broken"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "an unreadable liveness read must hold the resource: $out"
  assert_contains "$out" "liveness could not be confirmed for: h-live(unreadable)" "the refusal must name the unconfirmed holder and state"
  pass "fail-closed: an unreadable liveness read holds the place and refuses the launch"
}

test_ambiguous_liveness_fails_closed() {
  local out rc
  new_resource_case ambiguous
  holder h-amb "$MODEL_A" ambiguous
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "an ambiguous liveness read must hold the resource: $out"
  assert_contains "$out" "h-amb(ambiguous)" "the refusal must name the ambiguous holder"
  pass "fail-closed: an ambiguous liveness read holds the place and refuses the launch"
}

test_unverified_backend_fails_closed() {
  local out rc
  new_resource_case unverified
  holder h-zellij "$MODEL_A" unverified
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "a holder on a backend with no liveness classifier must hold the resource: $out"
  assert_contains "$out" "h-zellij(unverified)" "the refusal must name the unverified holder"
  pass "fail-closed: a holder whose backend cannot prove liveness holds the place"
}

test_unreadable_holder_record_fails_closed() {
  local out rc
  new_resource_case badrecord
  holder h-locked "$MODEL_A" dead
  chmod 000 "$HOME_DIR/state/h-locked.meta"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  chmod 644 "$HOME_DIR/state/h-locked.meta"
  expect_code 1 "$rc" "an unreadable holder record must hold the resource: $out"
  assert_contains "$out" "h-locked(record unreadable)" "the refusal must name the unreadable record"
  pass "fail-closed: a holder record that cannot be read holds the place"
}

test_capacity_two_counts_unconfirmed_holders() {
  local out rc
  new_resource_case cap2
  printf '%s\n' '{"strata":{"capacity":2,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  holder h1 "$MODEL_A" alive
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "one live holder leaves room under capacity 2: $out"
  holder h2 "$MODEL_A" ambiguous
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "a live and an ambiguous holder fill capacity 2: $out"
  pass "resource: capacity counts live and unconfirmed holders up to the declared number"
}

test_other_models_and_own_record_are_ignored() {
  local out rc
  new_resource_case ignore
  holder h-other 'opencode-go/mimo' ambiguous
  holder t-self "$MODEL_A" alive
  out=$(policy t-self ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "a non-matching model and the task's own record must not count: $out"
  out=$(policy t-new ship 'opencode-go/mimo'); rc=$?
  expect_code 0 "$rc" "a launch on a model no resource matches is not limited: $out"
  pass "resource: other models and the task's own record are not counted"
}

test_raw_launch_model() {
  local out rc
  new_resource_case raw
  holder h-live "$MODEL_A" alive
  out=$(policy t-raw ship '' "pi --model $MODEL_A --thinking low"); rc=$?
  expect_code 1 "$rc" "a raw launch's own --model must be checked: $out"
  out=$(policy t-raw2 ship '' 'pi --thinking low'); rc=$?
  expect_code 1 "$rc" "a raw launch with no --model cannot be checked and must be refused: $out"
  assert_contains "$out" "must name its --model" "the refusal must say why"
  pass "resource: a raw launch is judged by its own --model, and refused without one"
}

test_secondmates_are_not_exempt() {
  local out rc
  new_resource_case secondmate
  holder h-live "$MODEL_A" alive
  out=$(policy sm-new secondmate "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "the physical limit applies to secondmates too: $out"
  pass "resource: secondmates are not exempt from a machine limit"
}

test_malformed_resources_fail_closed() {
  local out rc
  new_resource_case malformed
  printf '%s\n' '{"strata":{"capacity":0,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 2 "$rc" "capacity 0 is malformed and must refuse: $out"
  printf '%s\n' '{"strata":{"capacity":1,"match":{}}}' > "$HOME_DIR/config/fork-resources.json"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 2 "$rc" "a resource with no model match is malformed and must refuse: $out"
  printf 'not json\n' > "$HOME_DIR/config/fork-resources.json"
  out=$(policy t-new ship 'opencode-go/mimo'); rc=$?
  expect_code 2 "$rc" "an unreadable resources file refuses even for unrelated models: $out"
  pass "fail-closed: malformed or unreadable fork-resources.json refuses"
}

test_unreadable_state_directory_fails_closed() {
  local out rc
  new_resource_case statedir
  chmod 000 "$HOME_DIR/state"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  chmod 755 "$HOME_DIR/state"
  expect_code 2 "$rc" "a state directory that cannot be listed must refuse: $out"
  pass "fail-closed: an unreadable state directory refuses instead of counting zero holders"
}

test_missing_contract_values_fail_closed() {
  local out rc
  new_resource_case contract
  out=$(FM_LP_TASK=x FM_LP_KIND=ship "$POLICY" 2>&1); rc=$?
  expect_code 2 "$rc" "missing hook contract values must refuse: $out"
  out=$(FM_LP_PHASE=spawn FM_LP_TASK='../x' FM_LP_KIND=ship FM_LP_HOME="$HOME_DIR" FM_LP_STATE="$HOME_DIR/state" \
    FM_LP_DATA="$HOME_DIR/data" FM_LP_CONFIG="$HOME_DIR/config" "$POLICY" 2>&1); rc=$?
  expect_code 2 "$rc" "a task id that is not a firstmate id must refuse: $out"
  pass "fail-closed: missing contract values or an invalid task id refuse"
}

fork_run_tests
