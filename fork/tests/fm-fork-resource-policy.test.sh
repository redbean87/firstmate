#!/usr/bin/env bash
# Resource policy: cross-project machine/model capacity, counted through
# upstream's own live-agent check (fm_backend_agent_alive in bin/fm-backend.sh).
# The policy is called directly with the hook contract environment; a small
# fake tmux and ps make upstream's tmux adapter read each holder as alive,
# dead (shell in the foreground), missing, or unreadable.
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
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$FAKE" "$FAKEBIN"
  : > "$FAKE/windows"
  fork_policies "$HOME_DIR" resource
  printf '%s\n' '{"strata":{"capacity":1,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    if [ -f "$FORK_FAKE/inventory-broken" ]; then echo 'lost server' >&2; exit 1; fi
    cat "$FORK_FAKE/windows"; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *:*) printf '/dev/fk-%s\n' "${a#*:}"; exit 0 ;; esac; done
    exit 1 ;;
esac
exit 0
SH
  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -t) win=${2#fk-}; [ -f "$FORK_FAKE/comm.$win" ] || exit 0
      printf '4242 4242 4242 %s\n' "$(cat "$FORK_FAKE/comm.$win")" ;;
  -p) for f in "$FORK_FAKE"/comm.*; do [ -f "$f" ] && { cat "$f"; exit 0; }; done ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux" "$FAKEBIN/ps"
}

# holder <id> <model> <alive|dead|missing> [kind]: a recorded task on <model>.
holder() {
  local id=$1 model=$2 state=$3 kind=${4:-ship}
  printf '%s\n' "kind=$kind" "harness=pi" "model=$model" "window=fmses:fm-$id" > "$HOME_DIR/state/$id.meta"
  case "$state" in
    alive) printf '%s\n' "fm-$id" >> "$FAKE/windows"; printf 'pi\n' > "$FAKE/comm.fm-$id" ;;
    dead) printf '%s\n' "fm-$id" >> "$FAKE/windows"; printf 'zsh\n' > "$FAKE/comm.fm-$id" ;;
    missing) ;;
  esac
}

# policy <id> <kind> <model> [raw-launch]: run the entry point as HK1 would.
policy() {
  FORK_FAKE="$FAKE" PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" \
    FM_LP_PHASE=spawn FM_LP_TASK="$1" FM_LP_KIND="$2" FM_LP_PROJECT="$CASE/project" \
    FM_LP_HARNESS=pi FM_LP_MODEL="$3" FM_LP_EFFORT=default FM_LP_RAW_LAUNCH="${4-}" \
    FM_LP_HOME="$HOME_DIR" FM_LP_STATE="$HOME_DIR/state" FM_LP_DATA="$HOME_DIR/data" \
    FM_LP_CONFIG="$HOME_DIR/config" "$POLICY" 2>&1
}

test_upstream_liveness_reads_fakes() {
  new_resource_case liveness
  holder h-live "$MODEL_A" alive
  holder h-dead "$MODEL_A" dead
  holder h-gone "$MODEL_A" missing
  local alive dead gone
  alive=$(FORK_FAKE="$FAKE" PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive tmux fmses:fm-h-live' _ "$ROOT")
  dead=$(FORK_FAKE="$FAKE" PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive tmux fmses:fm-h-dead' _ "$ROOT")
  gone=$(FORK_FAKE="$FAKE" PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive tmux fmses:fm-h-gone' _ "$ROOT")
  assert_equals alive "$alive" "upstream liveness must read an agent foreground as alive"
  assert_equals dead "$dead" "upstream liveness must read a shell foreground as dead"
  assert_equals dead "$gone" "upstream liveness must read an absent window as dead"
  pass "contract: upstream fm_backend_agent_alive answers alive/dead from the recorded endpoint"
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

test_exited_or_missing_holder_does_not_block() {
  local out rc
  new_resource_case exited
  holder h-dead "$MODEL_A" dead
  holder h-gone "$MODEL_A" missing
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "an exited or vanished holder must not hold the resource: $out"
  pass "resource: a holder whose agent exited or whose endpoint is gone does not block"
}

test_unreadable_liveness_does_not_block() {
  local out rc
  new_resource_case unreadable
  holder h-live "$MODEL_A" alive
  : > "$FAKE/inventory-broken"
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "an unknown liveness read is counted as free, matching the current fork gate: $out"
  pass "resource: an unreadable liveness read does not hold the resource (documented semantics)"
}

test_other_models_and_own_record_are_ignored() {
  local out rc
  new_resource_case ignore
  holder h-other 'opencode-go/mimo' alive
  holder t-self "$MODEL_A" alive
  out=$(policy t-self ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "a non-matching model and the task's own record must not count: $out"
  out=$(policy t-new ship 'opencode-go/mimo'); rc=$?
  expect_code 0 "$rc" "a launch on a model no resource matches is not limited: $out"
  pass "resource: other models and the task's own record are not counted"
}

test_capacity_two() {
  local out rc
  new_resource_case cap2
  printf '%s\n' '{"strata":{"capacity":2,"match":{"model_prefix":"strata-local/"}}}' > "$HOME_DIR/config/fork-resources.json"
  holder h1 "$MODEL_A" alive
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 0 "$rc" "one live holder leaves room under capacity 2: $out"
  holder h2 "$MODEL_A" alive
  out=$(policy t-new ship "$MODEL_A"); rc=$?
  expect_code 1 "$rc" "two live holders fill capacity 2: $out"
  pass "resource: capacity counts live holders up to the declared number"
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
  holder h-live "$MODEL_A" alive secondmate
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
