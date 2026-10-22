#!/usr/bin/env bash
# The ported ChatGPT loop against the fork consult gate, end to end: the REAL
# fork/chatgpt/fm-chatgpt-loop.sh dispatches through the REAL upstream
# bin/fm-spawn.sh (HK1), and its delivery proof is judged by the REAL upstream
# bin/fm-control.sh relaunch (HK2, then HK1 inside fm-spawn --relaunch), all in
# isolated fixture homes with config/fork-policies enabling consult-gate.
# The bridge consultation and the fm-send handoff are stubbed through the
# loop's own test seams; no bridge is contacted.
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
LOOP="$ROOT/fork/chatgpt/fm-chatgpt-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-chatgpt-gate)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
# shellcheck disable=SC2034 # appended to by the lifted add_ship_task
TASK_TMPS=()
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"

# The consultation stub answers every consult with a fixed generated prompt;
# the send stub records the handoff target and message.
cat > "$STUBS/consult" <<'SH'
#!/usr/bin/env bash
printf 'GENERATED-AUDIT-PROMPT: inspect the parser and report findings.\n'
SH
cat > "$STUBS/send" <<'SH'
#!/usr/bin/env bash
target=$1
shift
printf 'target: %s\nmessage:\n%s\n' "$target" "$*" > "$STUB_SEND_LOG"
SH
chmod +x "$STUBS/consult" "$STUBS/send"

# new_spawn_world <name> <id>: an isolated spawn home (upstream fixtures) with
# consult-gate on, a brief for <id>, and a spawn wrapper that runs the real
# fm-spawn.sh with the fixture environment. Sets W_HOME W_PROJ W_LAUNCH_LOG
# W_SPAWN W_SEND_LOG.
new_spawn_world() {
  local case="$TMP_ROOT/$1" wt fakebin
  W_HOME="$case/home"
  W_PROJ="$case/project"
  wt="$case/wt"
  W_LAUNCH_LOG="$case/launch.log"
  W_SEND_LOG="$case/send.log"
  W_SPAWN="$case/spawn"
  mkdir -p "$case"
  fm_test_spawn_home "$W_HOME" codex
  fm_test_spawn_brief "$W_HOME" "$2"
  fm_git_worktree "$W_PROJ" "$wt" "wt-$1"
  fakebin=$(fm_test_make_spawn_fakebin "$case" gh gh-axi no-mistakes)
  : > "$W_LAUNCH_LOG"
  mkdir -p "$W_HOME/user-home"
  fork_policies "$W_HOME" consult-gate
  cat > "$W_SPAWN" <<SH
#!/usr/bin/env bash
FM_ROOT_OVERRIDE='' FM_HOME='$W_HOME' HOME='$W_HOME/user-home' CLAUDE_CONFIG_DIR='' \\
  FM_STATE_OVERRIDE='$W_HOME/state' FM_DATA_OVERRIDE='$W_HOME/data' \\
  FM_PROJECTS_OVERRIDE='$W_HOME/projects' FM_CONFIG_OVERRIDE='$W_HOME/config' \\
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH='$wt' TMUX="\${TMUX:-fake,1,0}" \\
  FM_FAKE_LAUNCH_LOG='$W_LAUNCH_LOG' PATH='$fakebin':"\$PATH" \\
  exec '$ROOT/bin/fm-spawn.sh' "\$@"
SH
  chmod +x "$W_SPAWN"
}

# loop <home> <args...>: run the real loop against <home> with the stubs.
loop() {
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    FM_CHATGPT_LOOP_SPAWN="$W_SPAWN" FM_CHATGPT_LOOP_CONSULT="$STUBS/consult" \
    FM_CHATGPT_LOOP_SEND="$STUBS/send" STUB_SEND_LOG="$W_SEND_LOG" \
    bash "$LOOP" "$@"
}

# audit_ready <home> <loop-id>: a loop record at audit-dispatch with a
# generated audit prompt, reached through the loop's own init and consult.
audit_ready() {
  printf 'Audit the parser.\n' > "$1/objective.txt"
  loop "$1" init --task "$2" --objective-file "$1/objective.txt" >/dev/null || fail "loop init failed for $2"
  loop "$1" consult --stage audit --task "$2" >/dev/null || fail "audit consult failed for $2"
}

# A loop dispatch hands the prompt to a worker through the real fm-spawn with
# consult-gate on, writes the fork delivery proof, and writes no legacy
# consult_delivered= field. The worker task id is the loop's task id: that is
# the id whose own data/<id>/chatgpt-loop.json the gate reads.
DISPATCHED_HOME=
test_dispatch_through_gate_writes_fork_proof() {
  local out rc
  new_spawn_world dispatch lp-audit
  audit_ready "$W_HOME" lp-audit
  out=$(loop "$W_HOME" dispatch --stage audit --task lp-audit -- lp-audit "$W_PROJ" --mode no-mistakes --yolo off 2>&1); rc=$?
  expect_code 0 "$rc" "the loop dispatch must pass the gate and hand off"$'\n'"$out"
  [ -f "$W_HOME/state/lp-audit.meta" ] || fail "the real fm-spawn must publish the worker's task record: $out"
  [ -s "$W_LAUNCH_LOG" ] || fail "the real fm-spawn must send the launch to the endpoint: $out"
  assert_grep "target: lp-audit" "$W_SEND_LOG" "the stage prompt must be handed to the spawned worker"
  assert_grep "GENERATED-AUDIT-PROMPT" "$W_SEND_LOG" "the handed-off message must be the stored generated audit prompt"
  [ "$(jq -c . "$W_HOME/data/lp-audit/fork-consult-delivered.json")" = '{"stage":"audit"}' ] \
    || fail "the loop must write data/<worker>/fork-consult-delivered.json as {\"stage\":\"audit\"}"
  assert_no_grep "consult_delivered" "$W_HOME/state/lp-audit.meta" "no legacy consult_delivered= may be written to the upstream task record"
  [ "$(jq -r .phase "$W_HOME/data/lp-audit/chatgpt-loop.json")" = audit-worker ] || fail "the dispatch must advance to audit-worker"
  DISPATCHED_HOME=$W_HOME
  pass "gate on: loop dispatch passes HK1, hands off the prompt, writes the fork proof, no consult_delivered="
}

# A worker with an id other than the loop's has no record of its own, so the
# gate refuses its fresh spawn: the loop records the spawn failure, stays at
# audit-dispatch, hands nothing off, and writes no proof.
test_different_id_worker_is_refused() {
  local out rc
  new_spawn_world otherid lp-other
  fm_test_spawn_brief "$W_HOME" lp-other-worker
  audit_ready "$W_HOME" lp-other
  out=$(loop "$W_HOME" dispatch --stage audit --task lp-other -- lp-other-worker "$W_PROJ" --mode no-mistakes --yolo off 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a different-id worker must be refused while consult-gate is on: $out"
  assert_contains "$out" "no stored ChatGPT prompt" "the refusal must be the gate's"
  assert_absent "$W_HOME/state/lp-other-worker.meta" "a refused worker must have no task record"
  [ ! -s "$W_LAUNCH_LOG" ] || fail "a refused worker must not be launched"
  assert_absent "$W_SEND_LOG" "a refused worker must be handed nothing"
  assert_absent "$W_HOME/data/lp-other-worker/fork-consult-delivered.json" "a refused worker must get no delivery proof"
  [ "$(jq -r .phase "$W_HOME/data/lp-other/chatgpt-loop.json")" = audit-dispatch ] || fail "a refused dispatch must stay at audit-dispatch"
  pass "gate on: a worker id other than the loop's is refused at spawn and leaves the loop retryable"
}

# relaunch_case <name> <id> <phase>: a running ship task <id> in an upstream
# relaunch fixture with consult-gate on, carrying the loop record and the
# delivery proof the dispatch above wrote, with the loop record moved to
# <phase>. Echoes the case directory.
relaunch_case() {
  local dir
  dir=$(new_case "$1" "$2")
  add_ship_task "$dir" "$2" claude
  fork_policies "$dir/home" consult-gate
  cp "$DISPATCHED_HOME/data/lp-audit/chatgpt-loop.json" "$DISPATCHED_HOME/data/lp-audit/fork-consult-delivered.json" "$dir/home/data/$2/"
  jq --arg p "$3" '.phase = $p' "$dir/home/data/$2/chatgpt-loop.json" > "$dir/loop.tmp" \
    && mv "$dir/loop.tmp" "$dir/home/data/$2/chatgpt-loop.json"
  printf '%s\n' "$dir"
}

# Relaunch of the dispatched worker passes HK2 and HK1. At plan-consult the
# loop record names no prompt the gate accepts, so the delivery proof alone
# admits it; without the proof the same relaunch is refused before the agent
# stops.
test_relaunch_passes_on_fork_proof() {
  local dir out rc before
  [ -n "$DISPATCHED_HOME" ] || test_dispatch_through_gate_writes_fork_proof >/dev/null
  dir=$(relaunch_case worker lp-audit audit-worker)
  out=$(FM_FORK_POLICY_TRACE="$dir/trace" run_control "$dir" lp-audit relaunch --note "resume"); rc=$?
  expect_code 0 "$rc" "the dispatched worker's relaunch must pass the gate"$'\n'"$out"
  [ -f "$dir/trace.relaunch-preflight" ] && [ -f "$dir/trace.relaunch" ] || fail "HK2 and HK1 must both judge the relaunch"

  dir=$(relaunch_case proofonly lp-audit plan-consult)
  out=$(FM_FORK_POLICY_TRACE="$dir/trace" run_control "$dir" lp-audit relaunch --note "resume"); rc=$?
  expect_code 0 "$rc" "with the loop record past its worker phase, the delivery proof must admit the relaunch"$'\n'"$out"
  [ -f "$dir/trace.relaunch-preflight" ] && [ -f "$dir/trace.relaunch" ] || fail "HK2 and HK1 must both judge the relaunch"
  assert_grep "/exit" "$dir/fake/literal" "an admitted relaunch replaces the agent"
  assert_no_grep "consult_delivered" "$dir/home/state/lp-audit.meta" "no legacy consult_delivered= after relaunch"

  dir=$(relaunch_case noproof lp-audit plan-consult)
  rm -f "$dir/home/data/lp-audit/fork-consult-delivered.json"
  before=$(cat "$dir/home/state/lp-audit.meta")
  out=$(run_control "$dir" lp-audit relaunch --note "resume"); rc=$?
  [ "$rc" -ne 0 ] || fail "without the delivery proof the same relaunch must be refused: $out"
  assert_contains "$out" "no prompt for the stage its phase puts in play" "the refusal must be the gate's"
  if grep -q '/exit' "$dir/fake/literal"; then fail "a refused relaunch must not stop the running agent"; fi
  [ "$before" = "$(cat "$dir/home/state/lp-audit.meta")" ] || fail "a refused relaunch must not change the task record"
  pass "gate on: the dispatched worker's relaunch passes HK2 and HK1 on the fork proof, and is refused without it"
}

test_dispatch_through_gate_writes_fork_proof
test_different_id_worker_is_refused
test_relaunch_passes_on_fork_proof
