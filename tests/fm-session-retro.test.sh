#!/usr/bin/env bash
# Behavior tests for bin/fm-session-retro.sh: one finished worker session's
# transcript, status log, inbox, and no-mistakes pipeline records become one
# read-only report naming confusion, context, and token-burn signals with
# file:line evidence. Fixtures are real Pi and Claude transcript files with the
# harnesses' own fields, a real SQLite state database, and a private home, so
# the script's public output is what is asserted, never its source.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-retro)
RETRO="$ROOT/bin/fm-session-retro.sh"
TASK=retro-task

# seed_home <dir>: build a private Firstmate home, a project path, a Pi and a
# Claude transcript, and a no-mistakes state database for one finished task.
seed_home() {
  local d=$1
  mkdir -p "$d/home/state/$TASK.inbox/handled" "$d/home/data/$TASK" \
    "$d/pi-root/--project--" "$d/claude-root/-project-" "$d/nm"
  printf 'the brief\n' > "$d/home/data/$TASK/brief.md"
  fm_write_meta "$d/home/state/$TASK.meta" \
    "window=tmux:fm-retro" \
    "endpoint_task_id=$TASK" \
    "worktree=$d/wt" \
    "project=$d/project" \
    "harness=pi" \
    "kind=ship" \
    "mode=no-mistakes" \
    "branch=fm/$TASK" \
    "model=fake/model-1" \
    "effort=high" \
    "spawn_gen=s$NOW.4242.1" \
    "backend=tmux"
  printf 'working [at=%s]: started\n' "$((NOW + 10))" > "$d/home/state/$TASK.status"
  printf 'done [at=%s]: finished\n' "$((NOW + 5010))" >> "$d/home/state/$TASK.status"
  printf 'first steer\n' > "$d/home/state/$TASK.inbox/001.msg"
  printf 'second steer\n' > "$d/home/state/$TASK.inbox/002.msg"
  printf 'handled steer\n' > "$d/home/state/$TASK.inbox/handled/001.msg"

  python3 - "$d" "$NOW" <<'PY'
import json
import sqlite3
import sys
import time
from pathlib import Path

root, base = Path(sys.argv[1]), int(sys.argv[2])


def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


# A Pi session: 17 tool calls before the first edit (exploration and a long
# edit-free run), `npm test` three times with the first failing, one file read
# four times with a compaction before the last, one oversized tool result, and
# one file edited four times.
calls = [
    ("bash", {"command": "npm test"}, True),
    ("bash", {"command": "npm test"}, False),
    ("bash", {"command": "npm test"}, False),
    ("read", {"path": "/x/src/a.ts"}, False),
    ("read", {"path": "/x/src/a.ts"}, False),
    ("read", {"path": "/x/src/a.ts"}, False),
    ("read", {"path": "/x/src/b.ts"}, False),
    ("read", {"path": "/x/src/c.ts"}, False),
    ("read", {"path": "/x/src/d.ts"}, False),
    ("read", {"path": "/x/src/e.ts"}, False),
    ("read", {"path": "/x/src/f.ts"}, False),
    ("bash", {"command": "ls -la"}, False),
    ("bash", {"command": "cat big.log"}, False),
    ("read", {"path": "/x/src/g.ts"}, False),
    ("read", {"path": "/x/src/h.ts"}, False),
    ("read", {"path": "/x/src/a.ts"}, False),
    ("read", {"path": "/x/src/i.ts"}, False),
]
edits = [("edit", {"path": "/x/src/b.ts"}, False) for _ in range(4)]
lines = []
line_no = 0


def add(record):
    global line_no
    line_no += 1
    lines.append(json.dumps(record))


add({"type": "session", "version": 3, "id": "fixture-pi",
     "timestamp": _iso(base), "cwd": str(root / "wt")})
add({"type": "model_change", "provider": "fake", "modelId": "fake/model-1"})
# The compaction sits after the third read of a.ts, so the fourth read is a
# post-compaction re-read.
compaction_after = 5
call_id = 0
for index, (name, args, is_error) in enumerate(calls + edits):
    when = base + index * 60
    call_id += 1
    add({"type": "message", "id": "a%d" % call_id, "timestamp": _iso(when),
         "message": {"role": "assistant", "content": [{"type": "toolCall", "id": "c%d" % call_id,
                                                       "name": name, "arguments": args}],
                     "usage": {"input": 1000, "output": 200, "cacheRead": 200_000,
                               "cacheWrite": 0, "totalTokens": 201_200, "cost": 0.01}}})
    size = 50_000 if args.get("command") == "cat big.log" else 100
    add({"type": "message", "id": "r%d" % call_id, "timestamp": _iso(when + 1),
         "message": {"role": "toolResult", "toolCallId": "c%d" % call_id, "toolName": name,
                     "content": [{"type": "text", "text": "x" * size}], "isError": is_error}})
    if index == compaction_after:
        add({"type": "compaction", "id": "comp1", "timestamp": _iso(when + 30),
             "summary": "trimmed", "tokensBefore": 120_000})
(root / "pi-root" / "--project--" / "session.jsonl").write_text("\n".join(lines) + "\n")

# A Claude session in that harness's own shape: one file read three times.
claude = [
    json.dumps({"type": "user", "timestamp": _iso(base), "cwd": str(root / "wt"),
                "uuid": "u0", "parentUuid": None, "sessionId": "fixture-claude",
                "version": "2.0.0", "isSidechain": False,
                "message": {"role": "user", "content": "do the task"}}),
]
for index in range(3):
    when = base + index * 60
    claude.append(json.dumps({
        "type": "assistant", "timestamp": _iso(when), "cwd": str(root / "wt"),
        "uuid": "a%d" % index, "parentUuid": "u0", "sessionId": "fixture-claude",
        "version": "2.0.0", "isSidechain": False,
        "message": {"role": "assistant", "model": "fake/claude-1",
                    "usage": {"input_tokens": 500, "output_tokens": 50,
                              "cache_read_input_tokens": 1000, "cache_creation_input_tokens": 0},
                    "content": [{"type": "tool_use", "id": "t%d" % index, "name": "Read",
                                 "input": {"file_path": "/x/src/z.ts"}}]}}))
    claude.append(json.dumps({
        "type": "user", "timestamp": _iso(when + 1), "cwd": str(root / "wt"),
        "uuid": "r%d" % index, "parentUuid": "a%d" % index,
        "sessionId": "fixture-claude", "version": "2.0.0", "isSidechain": False,
        "message": {"role": "user", "content": [{"type": "tool_result",
                                                 "tool_use_id": "t%d" % index,
                                                 "is_error": False, "content": "z" * 200}]}}))
(root / "claude-root" / "-project-" / "session.jsonl").write_text("\n".join(claude) + "\n")

# A no-mistakes state database with the columns the script reads: one completed
# run, four review rounds with a file flagged in two of them, a failed
# invocation, and a very long tail.
db = sqlite3.connect(root / "nm" / "state.sqlite")
db.executescript("""
CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                   status TEXT NOT NULL, created_at INTEGER NOT NULL, pr_url TEXT);
CREATE TABLE step_results (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
                           step_order INTEGER NOT NULL);
CREATE TABLE step_rounds (id TEXT PRIMARY KEY, step_result_id TEXT NOT NULL, round INTEGER NOT NULL,
                          trigger_type TEXT NOT NULL, findings_json TEXT, duration_ms INTEGER NOT NULL);
CREATE TABLE agent_invocations (id TEXT PRIMARY KEY, run_id TEXT NOT NULL, step_name TEXT NOT NULL,
                                round INTEGER NOT NULL, purpose TEXT NOT NULL,
                                duration_ms INTEGER NOT NULL, exit_status TEXT NOT NULL,
                                failure_category TEXT, model_roundtrips INTEGER,
                                started_at INTEGER NOT NULL);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (str(root / "project"),))
db.execute("INSERT INTO runs VALUES ('run1', 'r1', ?, 'completed', ?, ?)",
           ("fm/%s" % "retro-task", base, "https://example.invalid/pr/1"))
db.execute("INSERT INTO step_results VALUES ('s1', 'run1', 'review', 1)")
finding = '{"findings": [{"id": "f", "severity": "warning", "file": "src/b.ts", "line": 1}]}'
for round_no in (1, 2):
    db.execute("INSERT INTO step_rounds VALUES (?, 's1', ?, ?, ?, ?)",
               ("sr%d" % round_no, round_no, "auto_fix" if round_no > 1 else "initial", finding, 60_000))
db.execute("INSERT INTO agent_invocations VALUES ('i1', 'run1', 'review', 1, 'review', ?, 'ok', NULL, 12, ?)", (700000, base))
db.execute("INSERT INTO agent_invocations VALUES ('i2', 'run1', 'review', 2, 'review-fix', ?, 'error', 'timeout', 3, ?)", (1000, base + 1))
db.commit()
db.close()
PY
}

# retro <dir> [args...]: run the script against the case's private home and
# roots, with the real account stores kept out of reach.
retro() {
  local d=$1
  shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    FM_HOME="$d/home" NM_HOME="$d/nm" \
    FM_RETRO_PI_ROOT="$d/pi-root" FM_RETRO_CLAUDE_ROOT="$d/claude-root" \
    "$RETRO" "$@"
}

snapshot_home() {  # <dir>
  (cd "$1/home" && find . -type f | LC_ALL=C sort)
}

NOW=$(date +%s)

test_reports_confusion_context_and_pipeline_with_evidence() {
  local d out before after
  d=$TMP_ROOT/full
  seed_home "$d"
  before=$(snapshot_home "$d")
  out=$(retro "$d" "$TASK")
  after=$(snapshot_home "$d")
  assert_equals "$before" "$after" 'the retrospective wrote into the task home'
  assert_contains "$out" "# Session retrospective: $TASK" 'the report did not name the task'
  assert_contains "$out" "runtime: pi / fake/model-1" 'the report lost the recorded runtime'
  assert_contains "$out" "outcome: completed (https://example.invalid/pr/1)" \
    'the report lost the pipeline outcome'
  assert_contains "$out" "**worker session**" 'the report had no token-burn line'
  assert_contains "$out" "**token_heavy**" 'a heavy session was not flagged'
  assert_contains "$out" "npm test" 'the repeated command was not named'
  assert_contains "$out" "ran 3 times" 'the repeat count was not reported'
  assert_contains "$out" "s1:" 'evidence was not located in the transcript'
  assert_contains "$out" "**repeat_read**" 'repeated reads of one file were not reported'
  assert_contains "$out" "**post_compaction_reread**" 'post-compaction re-reads were not reported'
  assert_contains "$out" "**edit_churn**" 'edit churn was not reported'
  assert_contains "$out" "**compaction**" 'compaction was not reported'
  assert_contains "$out" "**largest_result**" 'an oversized tool result was not reported'
  assert_contains "$out" "**exploration_prefix**" 'the pre-edit exploration was not reported'
  assert_contains "$out" "**fix_rounds**" 'extra pipeline rounds were not reported'
  assert_contains "$out" "**repasse_file**" 'a re-passed file was not reported'
  assert_contains "$out" "**pipeline_failure**" 'a failed gate invocation was not reported'
  assert_contains "$out" "**long_tail**" 'the long agent tail was not reported'
  assert_contains "$out" "**status_gap**" 'a silent status stretch was not reported'
  assert_contains "$out" "**steering_churn**" 'steering traffic was not reported'
  assert_contains "$out" "## Pipeline rounds" 'pipeline rounds were not listed'
  assert_contains "$out" "src/b.ts rounds 1,2" 'the re-pass evidence lost its rounds'
  pass 'a full task home yields one read-only report with every signal and its evidence'
}

test_cleaned_up_task_still_retrospects_from_its_transcript() {
  local d out
  d=$TMP_ROOT/cleaned
  seed_home "$d"
  rm -f "$d/home/state/$TASK.meta"
  out=$(retro "$d" --task "$TASK" --branch "fm/$TASK" --project "$d/project" \
    --transcript "$d/pi-root/--project--/session.jsonl")
  assert_contains "$out" "ran 3 times" \
    'a cleaned-up task lost its transcript signals'
  assert_contains "$out" "kind: unknown" 'a missing task record was reported as a known kind'
  assert_contains "$out" "status_gap" 'the surviving status log was ignored'
  pass 'a task with no record left is still retrospected from its transcript'
}

test_claude_transcripts_are_read() {
  local d out rc
  d=$TMP_ROOT/claude
  seed_home "$d"
  set +e
  out=$(retro "$d" --transcript "$d/claude-root/-project-/session.jsonl"); rc=$?
  set -e
  expect_code 0 "$rc" 'a Claude transcript'
  assert_contains "$out" "runtime: claude / fake/claude-1" 'the Claude model was not read'
  assert_contains "$out" "**repeat_read**" 'repeated Claude reads were not reported'
  assert_contains "$out" "/x/src/z.ts was read 3 times" 'the Claude read count was wrong'
  pass 'Claude Code sessions are parsed from their own transcript shape'
}

test_absent_evidence_is_named_never_invented() {
  local d out
  d=$TMP_ROOT/empty
  mkdir -p "$d/home/state" "$d/home/data" "$d/pi-root" "$d/claude-root" "$d/nm"
  fm_write_meta "$d/home/state/$TASK.meta" \
    "worktree=$d/wt" "project=$d/project" "harness=pi" "kind=ship" \
    "branch=fm/$TASK" "spawn_gen=s$NOW.42.1"
  out=$(retro "$d" "$TASK")
  assert_contains "$out" "session: no transcript found for this task copy" \
    'a missing transcript was not named'
  assert_contains "$out" "No worker transcript was found" \
    'the report did not say which evidence was missing'
  assert_contains "$out" "pipeline: unavailable: the task copy is gone" \
    'a missing pipeline source was not named'
  pass 'absent sources are named in the report rather than guessed'
}

test_usage_and_refusals() {
  local d out rc
  d=$TMP_ROOT/usage
  seed_home "$d"
  set +e
  retro "$d" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" 'no task id and no transcript'
  set +e
  retro "$d" '../escape' >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" 'an unsafe task id'
  set +e
  retro "$d" --transcript "$d/missing.jsonl" >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'an unreadable transcript'
  set +e
  retro "$d" ghost >/dev/null 2>&1; rc=$?
  set -e
  expect_code 1 "$rc" 'a task id with no record and no transcript'
  out=$(retro "$d" --help)
  assert_contains "$out" "fm-session-retro.sh <task-id>" 'the help text was empty'
  pass 'bad usage and unreadable sources are refused with distinct exit codes'
}

test_reports_confusion_context_and_pipeline_with_evidence
test_cleaned_up_task_still_retrospects_from_its_transcript
test_claude_transcripts_are_read
test_absent_evidence_is_named_never_invented
test_usage_and_refusals
