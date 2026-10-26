#!/usr/bin/env bash
# Plan breakdown (fork/chatgpt/fm-chatgpt-breakdown.sh): one worker per plan
# task in dependency order, under launch grants the REAL fork consult gate
# judges. A stub fm-spawn runs the real fork/bin/fm-launch-policy (spawn
# phase, consult-gate on) before it publishes the worker's record, so every
# dispatch is admitted or refused by the real gate; fm-send is stubbed. Worker
# worktrees are real git clones so code-change checks run on real commits.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BD="$ROOT/fork/chatgpt/fm-chatgpt-breakdown.sh"
LOOP="$ROOT/fork/chatgpt/fm-chatgpt-loop.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-chatgpt-breakdown)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# A three-task plan: T1 and T2 are independent, T3 needs both.
PLAN=$(jq -c -n '{v: 1, summary: "s", assumptions: [], out_of_scope: [], stop_conditions: ["stop"],
  tasks: [
    {id: "T1", title: "one", basis: ["A1"], depends_on: [], steps: ["a"], acceptance_criteria: ["b"], verification: [{command: "check one", expect: "ok"}]},
    {id: "T2", title: "two", basis: ["A1"], depends_on: [], steps: ["a"], acceptance_criteria: ["b"], verification: [{command: "check two", expect: "ok"}]},
    {id: "T3", title: "three", basis: ["A1"], depends_on: ["T1", "T2"], steps: ["a"], acceptance_criteria: ["b"], verification: [{command: "check three", expect: "ok"}]}]}')

# world <name>: an isolated home with the feature on, consult-gate on, a loop
# record L at plan-dispatch holding PLAN, a project repo, and stub spawn/send.
world() {
  W="$TMP_ROOT/$1"
  H="$W/home"
  mkdir -p "$H/state" "$H/data/L" "$H/config" "$W/stub"
  : > "$H/config/chatgpt-breakdown"
  printf 'consult-gate\n' > "$H/config/fork-policies"
  jq -n --arg p "$PLAN" '{task_id: "L", objective: "o", context: "", thread: "t", phase: "plan-dispatch", iteration: 1,
    audit_prompt: "", audit_result: "", findings: "A1 a finding", findings_source: "", findings_origin: "worker",
    worker_task: "", plan: $p, plan_raw: "", plan_refusal: "", worker_result: "", result_report: "",
    result_report_sha256: "", completion: "", fix_rounds_used: 0, previous_plan: "", previous_result: "",
    terminal_reason: "", last_error: "", updated_at: "x"}' > "$H/data/L/chatgpt-loop.json"
  git init -q -b main "$W/proj"
  git -C "$W/proj" -c user.email=t@x.invalid -c user.name=t commit -q --allow-empty -m base
  cat > "$W/stub/spawn" <<SH
#!/usr/bin/env bash
id=\$1
printf '%s\n' "\$*" >> '$W/stub/spawns'
FM_LP_PHASE=spawn FM_LP_TASK=\$id FM_LP_KIND=ship FM_LP_HOME='$H' FM_LP_STATE='$H/state' \\
  FM_LP_DATA='$H/data' FM_LP_CONFIG='$H/config' '$ROOT/fork/bin/fm-launch-policy' 2>> '$W/stub/gate.err' || exit 1
[ -z "\${STUB_SPAWN_EXIT:-}" ] || exit "\$STUB_SPAWN_EXIT"
wt='$W'/wt-\$id
git clone -q '$W/proj' "\$wt"
printf 'window=stub:%s\nkind=ship\nworktree=%s\n' "\$id" "\$wt" > '$H/state'/\$id.meta
SH
  cat > "$W/stub/send" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> '$W/stub/sends'
printf '%s\n' "\$2" > '$W/stub/msg-'"\$1"
SH
  chmod +x "$W/stub/spawn" "$W/stub/send"
  export FM_HOME="$H" FM_DATA_OVERRIDE="$H/data" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config"
  export FM_CHATGPT_LOOP_SPAWN="$W/stub/spawn" FM_CHATGPT_LOOP_SEND="$W/stub/send"
}

bd() { "$BD" "$@" 2>&1; }
task_field() { jq -r --arg t "$1" ".tasks[\$t].$2" "$H/data/L/chatgpt-breakdown.json"; }
dispatch() { bd dispatch --task L --plan-task "$1" -- proj --mode no-mistakes; }

# result <worker> <Tn> <status> [commit]: write a contract result and report;
# with commit, also commit a change in the worker's worktree.
result() {
  local w=$1 t=$2 s=$3 cmd
  cmd="check $(case "$t" in T1) echo one ;; T2) echo two ;; T3) echo three ;; esac)"
  mkdir -p "$H/data/$w"
  printf 'report for %s\n' "$t" > "$H/data/$w/report.md"
  jq -n --arg t "$t" --arg s "$s" --arg c "$cmd" '{v: 1, report: "report.md",
    tasks: [{id: $t, status: $s, evidence: [{command: $c, exit_code: (if $s == "pass" then 0 else 1 end), summary: "ran"}]}]}' \
    > "$H/data/$w/plan-result.json"
  if [ "${4:-}" = commit ]; then
    printf '%s\n' "$t" > "$W/wt-$w/$t.txt"
    git -C "$W/wt-$w" add "$t.txt"
    git -C "$W/wt-$w" -c user.email=t@x.invalid -c user.name=t commit -q -m "$t"
  fi
}

# land <worker>: push the worker's commits to the project, as a merge would.
land() { git -C "$W/proj" pull -q --ff-only "$W/wt-$1" HEAD; }

test_disabled_by_default() {
  local out rc
  world disabled
  rm -f "$H/config/chatgpt-breakdown"
  out=$(bd start --task L); rc=$?
  expect_code 1 "$rc" "breakdown must refuse without config/chatgpt-breakdown"
  assert_contains "$out" "disabled in this home" "the refusal names the switch"
  assert_equals plan-dispatch "$(jq -r .phase "$H/data/L/chatgpt-loop.json")" "nothing changed"
  pass "breakdown: off unless the home opts in"
}

test_dependency_order_and_parallel_dispatch() {
  local out rc
  world order
  out=$(bd start --task L); rc=$?
  expect_code 0 "$rc" "start$out"
  assert_equals plan-worker "$(jq -r .phase "$H/data/L/chatgpt-loop.json")" "start moves the loop to plan-worker"
  assert_equals "T1 T2" "$(bd ready --task L | tr '\n' ' ' | sed 's/ $//')" "only tasks without unmet dependencies are ready"
  out=$(dispatch T3); rc=$?
  [ "$rc" -ne 0 ] || fail "T3 must not dispatch before T1 and T2 pass"
  assert_contains "$out" "before its dependency T1 has reported pass" "the refusal names the unmet dependency"
  [ ! -e "$W/stub/spawns" ] || fail "an out-of-order dispatch must launch nothing"
  dispatch T1 >/dev/null || fail "T1 dispatch"
  dispatch T2 >/dev/null || fail "T2 dispatch, alongside T1"
  assert_equals "running running" "$(task_field T1 status) $(task_field T2 status)" "independent tasks run at once"
  assert_contains "$(cat "$W/stub/msg-L-r1-t1")" "Your task is T1" "the handoff carries only its own task"
  assert_not_contains "$(cat "$W/stub/msg-L-r1-t1")" "check two" "another task's commands are not in the handoff"
  pass "breakdown: dependency order is enforced, independent tasks dispatch in parallel, each handoff holds one task"
}

test_grant_isolation_by_the_real_gate() {
  local out rc g
  world grants
  bd start --task L >/dev/null
  dispatch T1 >/dev/null || fail "T1 dispatch"
  g="$H/data/L-r1-t1/fork-consult-grant.json"
  # The worker is running now, so the same grant must not admit a fresh spawn.
  gate() {
    FM_LP_PHASE=$1 FM_LP_TASK=$2 FM_LP_KIND=ship FM_LP_HOME="$H" FM_LP_STATE="$H/state" \
      FM_LP_DATA="$H/data" FM_LP_CONFIG="$H/config" "$ROOT/fork/bin/fm-launch-policy" 2>&1
  }
  [ -f "$g" ] || fail "a running worker keeps its grant"
  out=$(gate spawn L-r1-t1); rc=$?
  [ "$rc" -ne 0 ] || fail "a grant must not admit a second fresh spawn of a running worker"
  out=$(gate relaunch L-r1-t1); rc=$?
  expect_code 0 "$rc" "the grant admits a relaunch of its running worker$out"
  mkdir -p "$H/data/intruder" && cp "$g" "$H/data/intruder/fork-consult-grant.json"
  out=$(gate spawn intruder); rc=$?
  [ "$rc" -ne 0 ] || fail "a copied grant must not admit another worker"
  assert_contains "$out" "names a different worker" "the refusal names the mismatch"
  jq '.worker = "intruder"' "$g" > "$H/data/intruder/fork-consult-grant.json"
  out=$(gate relaunch intruder); rc=$?
  [ "$rc" -ne 0 ] || fail "a grant rewritten for another worker must not match the loop's record"
  jq '.attempt = 2' "$g" > "$g.tmp" && cp "$g" "$g.orig" && mv "$g.tmp" "$g"
  out=$(gate relaunch L-r1-t1); rc=$?
  [ "$rc" -ne 0 ] || fail "a grant for another attempt must be refused"
  mv "$g.orig" "$g"
  jq '.plan = (.plan | fromjson | .summary = "changed" | tojson)' "$H/data/L/chatgpt-loop.json" > "$W/lp" && cp "$H/data/L/chatgpt-loop.json" "$W/lp.orig" && mv "$W/lp" "$H/data/L/chatgpt-loop.json"
  out=$(gate relaunch L-r1-t1); rc=$?
  [ "$rc" -ne 0 ] || fail "a grant must be refused once the loop's plan changed"
  assert_contains "$out" "plan changed" "the refusal names the changed plan"
  mv "$W/lp.orig" "$H/data/L/chatgpt-loop.json"
  out=$(gate spawn L); rc=$?
  [ "$rc" -ne 0 ] || fail "the loop id itself must not launch while its plan runs task by task"
  assert_contains "$out" "only granted per-task workers" "the refusal names the reason"
  pass "breakdown grants: bound to worker, attempt, plan, and task state; copies, rewrites, and the loop id are refused"
}

test_code_changes_must_reach_dependents() {
  local out rc
  world code
  bd start --task L >/dev/null
  dispatch T1 >/dev/null || fail "dispatch T1"
  dispatch T2 >/dev/null || fail "dispatch T2"
  result L-r1-t1 T1 pass commit
  printf 'dirty\n' > "$W/wt-L-r1-t2/scratch.txt"
  result L-r1-t2 T2 pass
  out=$(bd record-task-result --task L --plan-task T2); rc=$?
  expect_code 2 "$rc" "a pass with uncommitted changes must be refused"
  rm -f "$W/wt-L-r1-t2/scratch.txt"
  bd record-task-result --task L --plan-task T1 >/dev/null || fail "record T1"
  bd record-task-result --task L --plan-task T2 >/dev/null || fail "record T2"
  assert_equals "true false" "$(task_field T1 changed) $(task_field T2 changed)" "code change is recorded from the worktree"
  [ ! -e "$H/data/L-r1-t1/fork-consult-grant.json" ] || fail "a recorded task loses its grant"
  git clone -q "$W/proj" "$W/projclone"
  out=$(bd dispatch --task L --plan-task T3 -- "$W/projclone" --mode no-mistakes); rc=$?
  expect_code 4 "$rc" "the pre-check must refuse when origin's base provably lacks T1's commit"
  assert_contains "$out" "no attempt charged" "the pre-check refusal is free"
  assert_equals "pending 0" "$(task_field T3 status) $(task_field T3 attempts)" "nothing was charged or spawned"
  out=$(dispatch T3); rc=$?
  expect_code 3 "$rc" "T3 must not start on a base without T1's commit"
  assert_contains "$out" "does not contain the dependency commits T1@" "the refusal names the missing commit"
  [ ! -e "$W/stub/msg-L-r1-t3" ] || fail "the prompt must not be sent to a worker missing its dependencies"
  assert_equals "pending 1" "$(task_field T3 status) $(task_field T3 attempts)" "T3 is pending again with the attempt charged once"
  [ ! -e "$H/data/L-r1-t3/fork-consult-grant.json" ] || fail "the refused worker's grant is withdrawn"
  land L-r1-t1
  out=$(dispatch T3); rc=$?
  expect_code 0 "$rc" "T3 starts once T1's commit is on its base$out"
  assert_equals "running 2 L-r1-t3-a2" "$(task_field T3 status) $(task_field T3 attempts) $(task_field T3 worker)" "the retry is a new worker id"
  pass "breakdown: dependents must start from a base holding their dependencies' commits, and dirty passes are refused"
}

test_worker_failures_retries_partial_completion_and_cleanup() {
  local out rc
  world partial
  bd start --task L >/dev/null
  dispatch T1 >/dev/null || fail "dispatch T1"
  dispatch T2 >/dev/null || fail "dispatch T2"
  out=$(STUB_SPAWN_EXIT=75 bd dispatch --task L --plan-task T2 -- proj); rc=$?
  [ "$rc" -ne 0 ] || fail "T2 is running, so a second dispatch is refused"
  bd record-task-failure --task L --plan-task T2 --reason "pane died" >/dev/null || fail "first failure"
  assert_equals "pending 1" "$(task_field T2 status) $(task_field T2 attempts)" "a failed worker returns its task to pending"
  out=$(STUB_SPAWN_EXIT=75 dispatch T2); rc=$?
  expect_code 75 "$rc" "a capacity deferral passes through"
  assert_equals "pending 1" "$(task_field T2 status) $(task_field T2 attempts)" "a capacity deferral is not charged"
  dispatch T2 >/dev/null || fail "retry T2"
  assert_equals L-r1-t2-a2 "$(task_field T2 worker)" "the retry gets its own worker id"
  bd record-task-failure --task L --plan-task T2 --reason "pane died again" >/dev/null || fail "second failure"
  assert_equals fail "$(task_field T2 status)" "attempts exhausted makes the task fail"
  out=$(bd finish --task L); rc=$?
  [ "$rc" -ne 0 ] || fail "finish must wait for T1, which is still running"
  assert_contains "$out" "still in flight: T1" "finish names what is in flight"
  printf '{}\n' > "$W/any-result.json"
  out=$("$LOOP" record-result --task L --file "$W/any-result.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the loop's own record-result is refused while the breakdown is open"
  assert_contains "$out" "running its plan task by task" "the loop names the open breakdown"
  result L-r1-t1 T1 pass commit
  bd record-task-result --task L --plan-task T1 >/dev/null || fail "record T1"
  out=$(bd finish --task L); rc=$?
  expect_code 0 "$rc" "finish with a partial completion$out"
  assert_equals plan-consult "$(jq -r .phase "$H/data/L/chatgpt-loop.json")" "a failed task opens the loop's fix round"
  assert_equals "pass fail fail" "$(jq -r '[.tasks[].status] | join(" ")' "$H/data/L/breakdown-result.json")" "T3 was never reached and is reported fail"
  assert_contains "$(jq -r '.tasks[2].evidence[0].summary' "$H/data/L/breakdown-result.json")" "T2 (fail)" "T3's evidence names the failed dependency"
  assert_equals closed "$(jq -r .state "$H/data/L/chatgpt-breakdown.json")" "finish closes the breakdown"
  [ -z "$(find "$H/data" -name fork-consult-grant.json)" ] || fail "finish withdraws every grant"
  [ ! -e "$H/data/L-r1-t2-a2/fork-consult-delivered.json" ] || fail "a failed worker keeps no delivery proof"
  [ -e "$H/data/L-r1-t1/fork-consult-delivered.json" ] || fail "a passed worker keeps its proof so it can be relaunched to land"
  pass "breakdown: worker failures retry once on a new id, capacity deferrals are free, partial completion aggregates into the loop's fix round, and cleanup withdraws every grant"
}

test_all_pass_completes_the_loop() {
  local out rc t
  world allpass
  bd start --task L >/dev/null
  dispatch T1 >/dev/null || fail "dispatch T1"
  dispatch T2 >/dev/null || fail "dispatch T2"
  result L-r1-t1 T1 pass
  result L-r1-t2 T2 pass
  for t in T1 T2; do bd record-task-result --task L --plan-task "$t" >/dev/null || fail "record $t"; done
  dispatch T3 >/dev/null || fail "T3 dispatch after T1 and T2 pass without code changes"
  result L-r1-t3 T3 pass
  bd record-task-result --task L --plan-task T3 >/dev/null || fail "record T3"
  out=$(bd finish --task L); rc=$?
  expect_code 0 "$rc" "finish$out"
  assert_equals "complete reported" "$(jq -r '.phase + " " + .completion' "$H/data/L/chatgpt-loop.json")" "the loop completes through its own result contract"
  out=$(bd start --task L); rc=$?
  [ "$rc" -ne 0 ] || fail "a completed loop cannot start another breakdown"
  pass "breakdown: three workers in dependency order complete the loop through its unchanged result contract"
}

fork_run_tests
