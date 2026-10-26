#!/usr/bin/env bash
# shellcheck disable=SC2016 # every single-quoted $name below is a jq variable
# fm-chatgpt-breakdown.sh - run a validated ChatGPT plan task by task: one
# worker per plan task, dispatched in dependency order, each under a launch
# grant bound to its loop, plan task, worker id, attempt, and plan.
# Usage: fm-chatgpt-breakdown.sh start --task L
#        fm-chatgpt-breakdown.sh ready --task L
#        fm-chatgpt-breakdown.sh dispatch --task L --plan-task Tn [--effort E] -- <fm-spawn args after the task id>
#        fm-chatgpt-breakdown.sh record-task-result --task L --plan-task Tn [--file FILE]
#        fm-chatgpt-breakdown.sh record-task-failure --task L --plan-task Tn --reason TEXT
#        fm-chatgpt-breakdown.sh finish --task L
#        fm-chatgpt-breakdown.sh status --task L
#
# This is the worker-construction step of the ChatGPT channel, not the
# bridge: it never consults ChatGPT. It takes the plan the loop
# (fm-chatgpt-loop.sh) already validated against plan-contract.template and
# replaces the loop's single plan worker; the loop's own phases, fix round,
# and terminal outcomes are unchanged, and finish hands them one aggregated
# result checked against result-contract.template as usual.
#
# Disabled by default: every command refuses unless the home has
# config/chatgpt-breakdown (FM_CONFIG_OVERRIDE honoured). Turn it on only
# after a real multi-task run has passed end to end.
#
# State: data/L/chatgpt-breakdown.json, one JSON object {v, loop, iteration,
# round, plan_sha256, state open|closed, max_attempts, tasks: {Tn: {depends_on,
# status, attempts, worker, workers, base_commit, head_commit, changed, result,
# report, last_error}}, outcome, updated_at}, written under the lock
# data/L/.chatgpt-breakdown.lock (upstream's fm_lock primitive). A closed
# record is archived to data/L/chatgpt-breakdown.<round>.json by the next start.
#
# start     loop at plan-dispatch with a stored plan: re-checks that every
#           depends_on names an earlier task, opens the record, and moves the
#           loop to plan-worker with worker_task L. While it is open the loop
#           refuses record-result and plan record-worker-failure.
# ready     prints the plan tasks that may be dispatched now: pending, with
#           every dependency reported pass. Several ready tasks may run at once.
# dispatch  Tn must be ready (a dependency that has not reported pass refuses
#           the order) and below max_attempts (2). The worker id is
#           L-r<round>-t<n>, with -a<attempt> after the first attempt; the
#           caller supplies its brief and backlog item as for any spawn, and
#           the args after -- (project, --mode, ...) without the id. Each
#           attempt is charged once, when Tn moves to dispatching and its
#           grant data/<worker>/fork-consult-grant.json is written; a spawn
#           deferred for capacity (exit 75) is not charged. Before that, a
#           read-only pre-check (git ls-remote in the project directory, the
#           first arg after --) refuses uncharged, exit 4, when the base the
#           worker would start from (--base-branch, else origin's HEAD) is a
#           known commit that lacks a dependency's change. After the spawn,
#           every dependency that changed code must have its recorded head
#           commit in the worker's worktree HEAD, or the prompt is not sent,
#           the grant is withdrawn, and the spawned worker must be cleaned up
#           (fm-teardown); the attempt stays charged. On success the single
#           task handoff (fm-chatgpt-loop.sh render_plan_message) is sent with
#           fm-send and the relaunch delivery proof is written.
# record-task-result
#           checks data/<worker>/plan-result.json (or --file) against the
#           result contract with Tn as the only planned task, refuses a pass
#           while the worker's worktree has uncommitted changes, and records
#           status, result, head commit, and whether code changed. The grant
#           is withdrawn; a non-pass also loses its delivery proof.
# record-task-failure
#           the worker died or gave up without a result: proof and grant are
#           withdrawn and Tn returns to pending, or after max_attempts becomes
#           fail with the reason as evidence.
# finish    when nothing is dispatching or running and no pending task is
#           ready: tasks never reached become fail (or blocked, when a blocked
#           task is upstream) "not dispatched", an aggregated result and
#           report are written in data/L/, and the loop records them through
#           its own record-result (complete, fix round, or failed). The record
#           closes and every grant is withdrawn.
# status    prints the record.
#
# The consult gate (fork/bin/fm-launch-policy, policy consult-gate) admits a
# worker with a grant only while this record is open, names that worker for
# that plan task at that attempt, the task is dispatching (fresh spawn) or
# dispatching/running (relaunch), and the loop's plan still hashes to the
# grant's plan_sha256; it refuses a fresh spawn of L itself while the record
# is open.
#
# Test seams: those of fm-chatgpt-loop.sh (FM_CHATGPT_LOOP_SPAWN,
# FM_CHATGPT_LOOP_SEND).
set -u

BD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fork/chatgpt/fm-chatgpt-loop.sh
. "$BD_DIR/fm-chatgpt-loop.sh"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# Disabled unless the home opts in; checked before anything else is loaded.
if [ ! -f "$CONFIG_DIR/chatgpt-breakdown" ]; then
  case "${1:-}" in -h|--help) sed -n '3,78p' "$BD_DIR/fm-chatgpt-breakdown.sh" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
  printf 'fm-chatgpt-breakdown: plan breakdown is disabled in this home (create config/chatgpt-breakdown to enable it)\n' >&2
  exit 1
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_BIN/fm-wake-lib.sh"
MAX_ATTEMPTS=2
BD_LOCK=

bd_die() { printf 'fm-chatgpt-breakdown: %s\n' "$1" >&2; bd_unlock; exit "${2:-1}"; }
bd_usage() { sed -n '6,12p' "$BD_DIR/fm-chatgpt-breakdown.sh" | sed 's/^# \{0,1\}//' >&2; exit 2; }
bd_file() { printf '%s/%s/chatgpt-breakdown.json' "$DATA" "$1"; }
grant_file() { printf '%s/%s/fork-consult-grant.json' "$DATA" "$1"; }
plan_sha() { jq -j '.plan' "$1" | file_sha256 /dev/stdin; }

bd_lock() {
  BD_LOCK="$DATA/$1/.chatgpt-breakdown.lock"
  fm_lock_acquire_wait_max "$BD_LOCK" 10 || { BD_LOCK=; bd_die "the breakdown record for $1 is busy; retry"; }
}
bd_unlock() {
  [ -z "$BD_LOCK" ] || fm_lock_release "$BD_LOCK" || true
  BD_LOCK=
}

# bd_update <task> <jq program> [jq args...]: rewrite the record atomically.
# The jq program is the last argument; $now is always bound.
bd_update() {
  local f tmp
  f=$(bd_file "$1")
  shift
  tmp=$(mktemp "$(dirname "$f")/.chatgpt-breakdown.XXXXXX") || return 1
  if jq --arg now "$(now_iso)" "$@" "$f" > "$tmp"; then :; else rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$f"
}

bd_get() { jq -r "$2" "$(bd_file "$1")"; }

need_open() {  # <task>: the loop record path; the breakdown must be open
  local file
  file=$(need_state "$1") || exit 1
  [ -f "$(bd_file "$1")" ] || bd_die "task $1 has no breakdown record (run start)"
  [ "$(bd_get "$1" .state)" = open ] || bd_die "the breakdown for $1 is closed"
  printf '%s\n' "$file"
}

need_plan_task() {  # <task> <Tn>
  case "$2" in T[1-9]|T[1-9][0-9]) ;; *) bd_die "not a plan task id: $2" 2 ;; esac
  jq -e --arg t "$2" '.tasks[$t] | type == "object"' "$(bd_file "$1")" >/dev/null 2>&1 \
    || bd_die "the plan for $1 has no task $2" 2
}

meta_worktree() { sed -n 's/^worktree=//p' "$STATE/$1.meta" 2>/dev/null | head -1; }

withdraw_grant() {  # <worker>
  local g
  g=$(grant_file "$1")
  rm -f -- "$g" 2>/dev/null
  [ ! -e "$g" ] && [ ! -L "$g" ]
}

cmd_bd_start() {
  local task=$1 file bd prev round tmp
  file=$(need_state "$task") || exit 1
  require_phase "$file" plan-dispatch "$task" || exit 1
  [ -n "$(read_field "$file" plan)" ] || bd_die "task $task has no validated plan"
  jq -e '.plan | fromjson | .tasks as $t | [range(0; $t | length) as $i | $t[$i].depends_on[]
         | . as $d | ([$t[:$i][].id] | index($d)) != null] | all' "$file" >/dev/null 2>&1 \
    || bd_die "the plan for $task has a dependency on a task that is not earlier; refusing that execution order"
  bd_lock "$task"
  bd=$(bd_file "$task")
  round=1
  if [ -f "$bd" ]; then
    [ "$(jq -r .state "$bd")" = closed ] || bd_die "task $task already has an open breakdown"
    prev=$(jq -r '.round // 1' "$bd")
    round=$((prev + 1))
    [ ! -e "$DATA/$task/chatgpt-breakdown.$prev.json" ] || bd_die "archive chatgpt-breakdown.$prev.json already exists"
    mv -- "$bd" "$DATA/$task/chatgpt-breakdown.$prev.json" || bd_die "could not archive the previous breakdown"
  fi
  tmp=$(mktemp "$DATA/$task/.chatgpt-breakdown.XXXXXX") || bd_die "could not write the breakdown record"
  jq --arg sha "$(plan_sha "$file")" --argjson round "$round" --argjson max "$MAX_ATTEMPTS" --arg now "$(now_iso)" '
    {v: 1, loop: .task_id, iteration: .iteration, round: $round, plan_sha256: $sha, state: "open",
     max_attempts: $max, outcome: "", updated_at: $now,
     tasks: ((.plan | fromjson).tasks | map({key: .id, value: {depends_on: .depends_on, status: "pending",
       attempts: 0, worker: "", workers: [], base_commit: "", head_commit: "", changed: false,
       result: null, report: "", last_error: ""}}) | from_entries)}' "$file" > "$tmp" || { rm -f "$tmp"; bd_die "could not build the breakdown record"; }
  mv -f "$tmp" "$bd"
  if ! { write_field "$file" worker_task "$task" && write_field "$file" phase plan-worker && write_field "$file" last_error ""; }; then
    bd_die "opened the breakdown but could not move the loop to plan-worker"
  fi
  bd_unlock
  printf 'breakdown round %s open for %s: %s plan tasks\n' "$round" "$task" "$(jq '.tasks | length' "$bd")"
}

ready_tasks() {  # <task>
  jq -r '.tasks as $t | $t | to_entries[] | select(.value.status == "pending")
         | select(all(.value.depends_on[]; $t[.].status == "pass")) | .key' "$(bd_file "$1")" | sort -V
}

cmd_bd_ready() {
  need_open "$1" >/dev/null || exit 1
  ready_tasks "$1"
}

# base_lacks_dependencies <record> <Tn> <spawn args...>: print " Tk@<sha>"
# for each dependency that changed code and is provably absent from the remote
# base the worker would start from. Read-only: ls-remote and local object
# checks only. Prints nothing when the base cannot be read, leaving the
# post-spawn check to decide.
base_lacks_dependencies() {
  local bd=$1 pt=$2 proj=$3 branch="" i=0 tip dep head
  shift 2
  local -a a=("$@")
  while [ "$i" -lt "${#a[@]}" ]; do
    case "${a[$i]}" in
      --base-branch) branch=${a[$((i + 1))]:-} ;;
      --base-branch=*) branch=${a[$i]#--base-branch=} ;;
    esac
    i=$((i + 1))
  done
  [ -d "$proj" ] || return 0
  [ -n "$branch" ] || branch=$(git -C "$proj" ls-remote --symref origin HEAD 2>/dev/null | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$|\1|p')
  [ -n "$branch" ] || return 0
  tip=$(git -C "$proj" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
  [ -n "$tip" ] && git -C "$proj" cat-file -e "$tip^{commit}" 2>/dev/null || return 0
  for dep in $(jq -r --arg t "$pt" '.tasks[$t].depends_on[]' "$bd"); do
    [ "$(jq -r --arg d "$dep" '.tasks[$d].changed' "$bd")" = true ] || continue
    head=$(jq -r --arg d "$dep" '.tasks[$d].head_commit' "$bd")
    git -C "$proj" merge-base --is-ancestor "$head" "$tip" 2>/dev/null || printf ' %s@%s' "$dep" "${head:0:12}"
  done
}

cmd_bd_dispatch() {
  local task=$1 pt=$2 effort=$3
  shift 3
  local -a args=("$@")
  local file bd n attempts round worker a prompt rc wt base dep head missing="" e=0
  file=$(need_open "$task") || exit 1
  need_plan_task "$task" "$pt"
  [ "${#args[@]}" -gt 0 ] || bd_die "dispatch needs the fm-spawn args after --" 2
  for a in "${args[@]}"; do
    printf '%s' "$a" | grep -Eiq 'CHATGPT_WEB_BRIDGE_URL|fm-chatgpt|codex-chatgpt-web|17841' \
      && bd_die "refusing dispatch: spawn arg references the bridge: $a" 2
    case "$a" in --effort|--effort=*) e=$((e + 1)) ;; esac
  done
  [ "$e" -le 1 ] || bd_die "refusing dispatch: duplicate --effort in the spawn args" 2
  [ "$e" = 0 ] || [ -z "$effort" ] || bd_die "refusing dispatch: effort given both as --effort and in the spawn args" 2
  [ "$e" = 1 ] || args+=(--effort "${effort:-low}")
  bd_lock "$task"
  bd=$(bd_file "$task")
  [ "$(jq -r --arg t "$pt" '.tasks[$t].status' "$bd")" = pending ] \
    || bd_die "$pt is $(jq -r --arg t "$pt" '.tasks[$t].status' "$bd"), not pending"
  for dep in $(jq -r --arg t "$pt" '.tasks[$t].depends_on[]' "$bd"); do
    [ "$(jq -r --arg d "$dep" '.tasks[$d].status' "$bd")" = pass ] \
      || bd_die "refusing to dispatch $pt before its dependency $dep has reported pass ($dep is $(jq -r --arg d "$dep" '.tasks[$d].status' "$bd"))"
  done
  attempts=$(jq -r --arg t "$pt" '.tasks[$t].attempts' "$bd")
  [ "$attempts" -lt "$(jq -r .max_attempts "$bd")" ] || bd_die "$pt has used all its attempts"
  round=$(jq -r .round "$bd")
  n=${pt#T}
  attempts=$((attempts + 1))
  worker="$task-r$round-t$n"
  [ "$attempts" = 1 ] || worker="$worker-a$attempts"
  fm_task_id_creation_valid "$worker" || bd_die "worker id $worker is not a valid task id (loop id too long?)"
  [ ! -e "$STATE/$worker.meta" ] || bd_die "a task record for $worker already exists; refusing to reuse it"
  prompt=$(render_plan_message "$file" "$worker" "$pt") || bd_die "the handoff for $pt could not be rendered; nothing launched"
  missing=$(base_lacks_dependencies "$bd" "$pt" "${args[@]}")
  [ -z "$missing" ] || bd_die "$pt's dependencies are not on the base its worker would start from:$missing; land them (merge, or the project's delivery path) and dispatch again - nothing launched, no attempt charged" 4
  mkdir -p "$DATA/$worker" || bd_die "could not create data/$worker"
  clear_delivery "$worker" || bd_die "could not clear an earlier delivery proof for $worker"
  # The attempt is charged here, exactly once, together with the grant.
  bd_update "$task" --arg t "$pt" --arg w "$worker" --argjson a "$attempts" \
    '.tasks[$t] |= (.status = "dispatching" | .attempts = $a | .worker = $w | .workers += [$w] | .last_error = "") | .updated_at = $now' \
    || bd_die "could not record the dispatch of $pt"
  a=$(mktemp "$DATA/$worker/.fork-consult-grant.XXXXXX") || bd_die "could not write the grant for $worker"
  if ! { jq -n --arg l "$task" --arg t "$pt" --arg w "$worker" --argjson at "$attempts" --arg sha "$(jq -r .plan_sha256 "$bd")" \
      '{v: 1, loop: $l, plan_task: $t, worker: $w, attempt: $at, plan_sha256: $sha}' > "$a" && mv -f "$a" "$(grant_file "$worker")"; }; then
    rm -f "$a"
    bd_update "$task" --arg t "$pt" '.tasks[$t].status = "pending" | .tasks[$t].last_error = "grant could not be written"'
    bd_die "could not write the grant for $worker; the attempt stays charged"
  fi
  bd_unlock
  if env -u CHATGPT_WEB_BRIDGE_URL -u FM_CHATGPT_LOOP_SPAWN -u FM_CHATGPT_LOOP_CONSULT -u FM_CHATGPT_LOOP_SEND \
    -u FM_CHATGPT_LOOP_PLAN_VALIDATE "$SPAWN" "$worker" "${args[@]}"; then rc=0; else rc=$?; fi
  bd_lock "$task"
  if [ "$rc" -ne 0 ]; then
    withdraw_grant "$worker" || true
    if [ "$rc" = 75 ]; then
      bd_update "$task" --arg t "$pt" --arg w "$worker" \
        '.tasks[$t] |= (.status = "pending" | .attempts -= 1 | .worker = "" | .workers -= [$w] | .last_error = "spawn deferred for capacity (exit 75); not charged")'
      bd_die "the spawn of $worker was deferred for capacity; $pt stays pending and the attempt was not charged" 75
    fi
    bd_update "$task" --arg t "$pt" --arg e "spawn of $worker failed (exit $rc)" \
      '.tasks[$t] |= (.status = "pending" | .worker = "" | .last_error = $e)'
    bd_die "the spawn of $worker failed (exit $rc); $pt is pending again with the attempt charged" "$rc"
  fi
  wt=$(meta_worktree "$worker")
  base=""
  [ -z "$wt" ] || base=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)
  for dep in $(jq -r --arg t "$pt" '.tasks[$t].depends_on[]' "$bd"); do
    [ "$(jq -r --arg d "$dep" '.tasks[$d].changed' "$bd")" = true ] || continue
    head=$(jq -r --arg d "$dep" '.tasks[$d].head_commit' "$bd")
    if [ -z "$base" ] || ! git -C "$wt" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
      missing="$missing $dep@${head:0:12}"
    fi
  done
  if [ -n "$missing" ]; then
    withdraw_grant "$worker" || true
    bd_update "$task" --arg t "$pt" --arg e "worker $worker started without the dependency commits:$missing; prompt not sent; clean it up" \
      '.tasks[$t] |= (.status = "pending" | .worker = "" | .last_error = $e)'
    bd_die "worker $worker does not contain the dependency commits$missing (land them on its base first); its prompt was NOT sent and its grant was withdrawn - clean up $worker with fm-teardown" 3
  fi
  bd_update "$task" --arg t "$pt" --arg b "$base" '.tasks[$t] |= (.status = "running" | .base_commit = $b)' \
    || bd_die "could not record $worker as running"
  if ! a=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SEND" "$worker" "$prompt" 2>&1); then
    bd_update "$task" --arg t "$pt" --arg e "prompt delivery to $worker failed: $a" '.tasks[$t].last_error = $e'
    bd_die "spawned $worker but the $pt handoff failed: $a; resend it or record a task failure"
  fi
  record_delivery "$worker" plan || bd_update "$task" --arg t "$pt" --arg e "prompt delivered but the delivery proof could not be written" '.tasks[$t].last_error = $e'
  bd_unlock
  printf 'dispatched %s to %s and delivered its handoff\n' "$pt" "$worker"
}

cmd_bd_record_result() {
  local task=$1 pt=$2 rfile=$3 file bd worker verdict outcome wt head base changed sha report
  file=$(need_open "$task") || exit 1
  need_plan_task "$task" "$pt"
  bd_lock "$task"
  bd=$(bd_file "$task")
  [ "$(jq -r --arg t "$pt" '.tasks[$t].status' "$bd")" = running ] || bd_die "$pt is not running"
  worker=$(jq -r --arg t "$pt" '.tasks[$t].worker' "$bd")
  [ -n "$rfile" ] || rfile="$DATA/$worker/plan-result.json"
  [ -f "$rfile" ] || bd_die "no result file $rfile" 2
  verdict=$(validate_result "$file" "$rfile" "$worker" "$pt") || bd_die "result for $pt refused; nothing changed" 2
  outcome=$(jq -r .outcome <<<"$verdict")
  report=$(jq -r .report <<<"$verdict")
  base=$(jq -r --arg t "$pt" '.tasks[$t].base_commit' "$bd")
  wt=$(meta_worktree "$worker")
  head="" changed=false
  if [ -n "$wt" ] && git -C "$wt" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    if [ "$outcome" = pass ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      bd_die "$pt reports pass but $worker has uncommitted changes in $wt; dependents could not see them - have it commit, then record again" 2
    fi
    head=$(git -C "$wt" rev-parse HEAD)
    [ -z "$base" ] || [ "$head" = "$base" ] || changed=true
  fi
  sha=$(file_sha256 "$report")
  if [ "$outcome" != pass ]; then clear_delivery "$worker" || bd_die "could not clear the delivery proof on $worker"; fi
  withdraw_grant "$worker" || bd_die "could not withdraw the grant on $worker"
  bd_update "$task" --arg t "$pt" --arg o "$outcome" --argjson r "$(jq -c '.result.tasks[0]' <<<"$verdict")" \
    --arg rp "$report" --arg sha "$sha" --arg h "$head" --argjson c "$changed" \
    '.tasks[$t] |= (.status = $o | .result = $r | .report = $rp | .report_sha256 = $sha | .head_commit = $h | .changed = $c | .last_error = "")' \
    || bd_die "could not record the result for $pt"
  bd_unlock
  printf 'recorded %s for %s (%s)%s\n' "$outcome" "$pt" "$worker" "$([ "$changed" = true ] && printf ', code changed at %s' "${head:0:12}")"
  printf 'ready now: %s\n' "$(ready_tasks "$task" | tr '\n' ' ')"
}

cmd_bd_record_failure() {
  local task=$1 pt=$2 reason=$3 bd worker attempts max status
  need_open "$task" >/dev/null || exit 1
  need_plan_task "$task" "$pt"
  bd_lock "$task"
  bd=$(bd_file "$task")
  status=$(jq -r --arg t "$pt" '.tasks[$t].status' "$bd")
  case "$status" in dispatching|running) ;; *) bd_die "$pt is $status; only a dispatching or running task can fail" ;; esac
  worker=$(jq -r --arg t "$pt" '.tasks[$t].worker' "$bd")
  clear_delivery "$worker" || bd_die "could not clear the delivery proof on $worker; nothing changed"
  withdraw_grant "$worker" || bd_die "could not withdraw the grant on $worker; nothing changed"
  attempts=$(jq -r --arg t "$pt" '.tasks[$t].attempts' "$bd")
  max=$(jq -r .max_attempts "$bd")
  if [ "$attempts" -lt "$max" ]; then
    bd_update "$task" --arg t "$pt" --arg e "worker $worker failed: $reason" \
      '.tasks[$t] |= (.status = "pending" | .worker = "" | .last_error = $e)' || bd_die "could not record the failure"
    bd_unlock
    printf '%s returned to pending after worker %s failed (attempt %s of %s)\n' "$pt" "$worker" "$attempts" "$max"
  else
    bd_update "$task" --arg t "$pt" --arg e "worker $worker failed: $reason" --arg w "$worker" --argjson a "$attempts" \
      '.tasks[$t] |= (.status = "fail" | .last_error = $e
        | .result = {id: $t, status: "fail", evidence: [{command: "worker \($w)", exit_code: 1, summary: "no result after \($a) worker attempts; last: \($e)"}]})' \
      || bd_die "could not record the failure"
    bd_unlock
    printf '%s failed: worker attempts exhausted (%s)\n' "$pt" "$max"
  fi
}

cmd_bd_finish() {
  local task=$1 file bd busy ready agg rep w rc
  file=$(need_open "$task") || exit 1
  bd_lock "$task"
  bd=$(bd_file "$task")
  busy=$(jq -r '[.tasks | to_entries[] | select(.value.status == "dispatching" or .value.status == "running") | .key] | join(" ")' "$bd")
  [ -z "$busy" ] || bd_die "still in flight: $busy; record their results or failures first"
  ready=$(ready_tasks "$task" | tr '\n' ' ')
  [ -z "${ready// /}" ] || bd_die "still dispatchable: $ready- dispatch them before finishing"
  agg="$DATA/$task/breakdown-result.json"
  rep="$DATA/$task/breakdown-report.md"
  # Tasks never reached inherit the reason from the first upstream task that
  # did not pass: blocked if any is blocked, otherwise fail.
  jq '.tasks as $t
      | def roots($id): $t[$id].depends_on | map(if $t[.].status == "pending" then roots(.) else [{id: ., s: $t[.].status}] end) | add // [];
      {v: 1, report: "breakdown-report.md",
       tasks: [$t | to_entries | sort_by(.key | ltrimstr("T") | tonumber)[]
         | if .value.status == "pending" then
             (roots(.key) | map(select(.s != "pass"))) as $r
             | {id: .key, status: (if any($r[]; .s == "blocked") then "blocked" else "fail" end),
                evidence: [{command: "not dispatched", exit_code: 1,
                  summary: "depends on \($r | map("\(.id) (\(.s))") | unique | join(", ")), which did not pass"}]}
           else .value.result end]}' "$bd" > "$agg" || bd_die "could not aggregate the task results"
  {
    printf '# Plan breakdown round %s for %s\n\n' "$(jq -r .round "$bd")" "$task"
    jq -r '.tasks | to_entries | sort_by(.key | ltrimstr("T") | tonumber)[]
      | "- \(.key): \(.value.status); workers \(.value.workers | if length == 0 then "none" else join(", ") end); depends on \(.value.depends_on | if length == 0 then "none" else join(", ") end); head \(.value.head_commit | if . == "" then "-" else .[0:12] end); report \(.value.report | if . == "" then "-" else . end)\(if .value.last_error != "" then "; last error: \(.value.last_error)" else "" end)"' "$bd"
  } > "$rep" || bd_die "could not write the breakdown report"
  if FM_CHATGPT_BREAKDOWN_FINISH=1 cmd_record_result --task "$task" --file "$agg"; then rc=0; else rc=$?; fi
  [ "$rc" = 0 ] || bd_die "the loop refused the aggregated result (exit $rc); the breakdown stays open" "$rc"
  for w in $(jq -r '.tasks[].workers[]' "$bd"); do withdraw_grant "$w" || true; done
  for w in $(jq -r '.tasks[] | select(.status != "pass") | .workers[]' "$bd"); do clear_delivery "$w" || true; done
  bd_update "$task" --arg o "$(read_field "$file" phase)" '.state = "closed" | .outcome = $o | .updated_at = $now' \
    || bd_die "the loop recorded the result but the breakdown record could not be closed"
  bd_unlock
  printf 'breakdown closed for %s; loop phase now %s\n' "$task" "$(read_field "$file" phase)"
}


sub=${1:-}
[ $# -eq 0 ] || shift
TASK="" PT="" FILE_ARG="" REASON="" EFFORT=""
REST=()
while [ $# -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:?--task needs a value}; shift 2 ;;
    --plan-task) PT=${2:?--plan-task needs a value}; shift 2 ;;
    --file) FILE_ARG=${2:?--file needs a value}; shift 2 ;;
    --reason) REASON=${2:?--reason needs a value}; shift 2 ;;
    --effort) EFFORT=${2:?--effort needs a value}; shift 2 ;;
    --) shift; REST=("$@"); break ;;
    *) bd_die "unknown argument $1" 2 ;;
  esac
done
case "$sub" in
  start|ready|status|finish|dispatch|record-task-result|record-task-failure) [ -n "$TASK" ] || bd_usage ;;
esac
case "$sub" in
  start) cmd_bd_start "$TASK" ;;
  ready) cmd_bd_ready "$TASK" ;;
  status) need_state "$TASK" >/dev/null || exit 1; jq . "$(bd_file "$TASK")" ;;
  dispatch) [ -n "$PT" ] || bd_usage; cmd_bd_dispatch "$TASK" "$PT" "$EFFORT" "${REST[@]}" ;;
  record-task-result) [ -n "$PT" ] || bd_usage; cmd_bd_record_result "$TASK" "$PT" "$FILE_ARG" ;;
  record-task-failure) [ -n "$PT" ] && [ -n "$REASON" ] || bd_usage; cmd_bd_record_failure "$TASK" "$PT" "$REASON" ;;
  finish) cmd_bd_finish "$TASK" ;;
  -h|--help) sed -n '3,78p' "$BD_DIR/fm-chatgpt-breakdown.sh" | sed 's/^# \{0,1\}//' ;;
  *) bd_usage ;;
esac
