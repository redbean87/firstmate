#!/usr/bin/env bash
# fm-session-retro.sh - read-only retrospective of one finished worker session.
#
# Usage:
#   fm-session-retro.sh <task-id>
#   fm-session-retro.sh --transcript <session-file> [--task <task-id>]
#   fm-session-retro.sh --transcript <session-file> [--project <path> --branch <name>]
#
# A task record is required only when no --transcript is given, so a cleaned-up
# task can still be retrospected from its transcript. --project and --branch
# attribute pipeline data when the task record is gone.
#
# Purpose: explain where one finished worker session spent confusion, context,
# and tokens, with file:line evidence and concrete reduction recommendations,
# so the next dispatch can be cheaper. It reads only; it never writes to the
# task or its copy. Redirect stdout to keep the report, for example
# `fm-session-retro.sh <id> > data/<id>/retro.md`.
#
# Evidence sources, each optional. The report names every source it could not
# read and never guesses a value, so a partial record yields a partial report
# rather than a confident wrong one:
#   - the harness session transcript, located by the session's own recorded
#     working directory matching the task copy: Pi sessions under
#     $HOME/.pi/agent/sessions/, Claude Code sessions under
#     $HOME/.claude/projects/. FM_RETRO_PI_ROOT and FM_RETRO_CLAUDE_ROOT
#     override those roots. This is the primary source for confusion, context,
#     and worker token burn, and it survives task cleanup.
#   - state/<id>.status, the append-only supervisor event log, for status
#     discipline and silent gaps.
#   - state/<id>.inbox/, for steering traffic the worker had to absorb.
#   - no-mistakes' state database, opened read-only, for pipeline churn: run
#     outcomes, per-step rounds, findings per round, durations, and failures.
#     Pipeline token totals are read only from the owned ledger
#     data/pipeline-spend.jsonl when a record exists; this script never
#     recomputes bin/fm-pipeline-spend.sh's token accounting.
#
# Signal thresholds, weights, and the report schema are owned by the analyzer
# below. The session-retro skill owns when to run a retrospective and how to
# read the report.
#
# Exit status: 0 when a report was produced (even a partial one), 1 when the
# task record or the requested transcript could not be read, 2 for bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}
fail() {
  printf 'fm-session-retro: %s\n' "$*" >&2
  exit 1
}

TASK=
TRANSCRIPT=
PROJECT_ARG=
BRANCH_ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --transcript)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      TRANSCRIPT=$2
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      TASK=$2
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECT_ARG=$2
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      BRANCH_ARG=$2
      shift 2
      ;;
    -*) usage >&2; exit 2 ;;
    *)
      [ -z "$TASK" ] || { usage >&2; exit 2; }
      TASK=$1
      shift
      ;;
  esac
done

[ -n "$TASK" ] || [ -n "$TRANSCRIPT" ] || { usage >&2; exit 2; }
if [ -n "$TASK" ]; then
  fm_task_id_path_safe "$TASK" || { echo "fm-session-retro: invalid task id" >&2; exit 2; }
fi
if [ -n "$TRANSCRIPT" ]; then
  [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || fail "transcript $TRANSCRIPT is not a readable file"
fi

# meta_value <file> <key>
meta_value() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

KIND=
MODE=
HARNESS=
MODEL=
EFFORT=
BACKEND=
PROJECT=
BRANCH=
SPAWN_EPOCH=
WORKTREE=
STATUS_FILE=
INBOX_DIR=
DATA_DIR=
NM_REASON=

if [ -n "$TASK" ]; then
  META="$STATE/$TASK.meta"
  DATA_DIR="$DATA/$TASK"
  STATUS_FILE="$STATE/$TASK.status"
  INBOX_DIR="$STATE/$TASK.inbox"
  if [ -f "$META" ] && [ ! -L "$META" ]; then
    KIND=$(meta_value "$META" kind)
    MODE=$(meta_value "$META" mode)
    HARNESS=$(meta_value "$META" harness)
    MODEL=$(meta_value "$META" model)
    EFFORT=$(meta_value "$META" effort)
    BACKEND=$(meta_value "$META" backend)
    PROJECT=$(meta_value "$META" project)
    BRANCH=$(meta_value "$META" branch)
    WORKTREE=$(meta_value "$META" worktree)
    SPAWN_GEN=$(meta_value "$META" spawn_gen)
    case "$SPAWN_GEN" in
      s[0-9]*) SPAWN_EPOCH=$(printf '%s' "$SPAWN_GEN" | sed -n 's/^s\([0-9][0-9]*\).*/\1/p') ;;
    esac
  elif [ -z "$TRANSCRIPT" ]; then
    fail "no task record at $META (use --transcript for a cleaned-up task)"
  fi
fi
if [ -n "$PROJECT_ARG" ]; then PROJECT=$PROJECT_ARG; fi
if [ -n "$BRANCH_ARG" ]; then BRANCH=$BRANCH_ARG; fi

if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
  NM_DB=$(fm_nm_state_db "$WORKTREE")
  if [ -n "$BRANCH" ]; then
    SINCE=$(git -C "$WORKTREE" reflog show --date=unix --format=%gd "refs/heads/$BRANCH" -- 2>/dev/null \
      | tail -1 | sed -n 's/.*@{\([0-9][0-9]*\)}$/\1/p') || SINCE=
    NM_SINCE=$SINCE
    OVERVIEW=$(fm_nm_run_checked "$WORKTREE" 30 axi) || true
    NM_REPO=$(fm_nm_strip_quotes "$(printf '%s\n' "$OVERVIEW" | sed -n 's/^repo:[[:space:]]*//p' | head -1)")
    [ -n "$NM_REPO" ] || NM_REASON="no-mistakes resolved no repository from the task copy"
  else
    NM_REASON="the task record names no branch"
  fi
elif [ -n "$PROJECT" ]; then
  NM_REPO=$PROJECT
  NM_DB=$(fm_nm_state_db "$SCRIPT_DIR")
  NM_REASON="the task copy is gone, so only the project path and branch name attribute its pipeline runs"
else
  NM_DB=$(fm_nm_state_db "$SCRIPT_DIR")
  NM_REASON="the task record names no copy and no project"
fi
NM_REPO=${NM_REPO:-}
NM_SINCE=${NM_SINCE:-}
if [ -n "$PROJECT_ARG" ]; then
  NM_REPO=$PROJECT_ARG
  NM_REASON=""
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required to read session transcripts and no-mistakes' state database"

python3 - \
  "$TASK" "$KIND" "$MODE" "$HARNESS" "$MODEL" "$EFFORT" "$BACKEND" \
  "$PROJECT" "$BRANCH" "$SPAWN_EPOCH" "$WORKTREE" "$STATUS_FILE" "$INBOX_DIR" \
  "$DATA_DIR" "$NM_DB" "$NM_REPO" "$NM_SINCE" "$NM_REASON" "$TRANSCRIPT" \
  "${FM_RETRO_PI_ROOT:-$HOME/.pi/agent/sessions}" \
  "${FM_RETRO_CLAUDE_ROOT:-$HOME/.claude/projects}" \
  "$DATA/pipeline-spend.jsonl" <<'PY'
"""Analyze one finished worker session and print a retrospective report.

Reads the resolved source configuration from argv (written by the shell
wrapper in bin/fm-session-retro.sh), then every evidence source named in that
script's header. Emits a Markdown report on stdout. Never writes anywhere.
"""

from __future__ import annotations

import collections
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Signal thresholds and weights. A signal fires only at or above its
# threshold, and its weight orders the top drivers and the recommendations.
WEIGHTS = {
    "repeat_command": 7,
    "failed_retry": 9,
    "consecutive_failures": 8,
    "repeat_read": 6,
    "edit_churn": 7,
    "post_compaction_reread": 9,
    "exploration_prefix": 6,
    "no_edit_run": 5,
    "token_heavy": 7,
    "compaction": 10,
    "largest_result": 6,
    "status_sparse": 5,
    "status_gap": 6,
    "steering_churn": 5,
    "fix_rounds": 9,
    "repasse_file": 8,
    "pipeline_failure": 8,
    "long_tail": 7,
}
THRESHOLDS = {
    "repeat_command": 3,
    "consecutive_failures": 3,
    "repeat_read": 3,
    "edit_churn": 4,
    "exploration_prefix": 12,
    "no_edit_run": 15,
    "status_gap": 3600,
    "steering_churn": 3,
    "largest_result": 40_000,
    "token_total": 1_000_000,
    "token_per_turn": 60_000,
    "long_tail": 600_000,
}
MAX_EVIDENCE = 5
MAX_RECOMMENDATIONS = 10
TOOL_WRITE = ("edit", "write", "multiedit", "notebookedit")


def now_utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# The shell wrapper passes one value per key in this exact order.
CFG_KEYS = (
    "task", "kind", "mode", "harness", "model", "effort", "backend",
    "project", "branch", "spawn_epoch", "worktree", "status_file", "inbox_dir",
    "data_dir", "nm_db", "nm_repo", "nm_since", "nm_reason", "transcript",
    "pi_root", "claude_root", "ledger",
)


def load_cfg(argv):
    values = list(argv)
    if len(values) != len(CFG_KEYS):
        sys.stderr.write("fm-session-retro: internal error: expected %d sources, got %d\n"
                         % (len(CFG_KEYS), len(values)))
        raise SystemExit(2)
    return dict(zip(CFG_KEYS, values))


def parse_ts(value):
    """Epoch seconds from a Pi or Claude timestamp, or None when unreadable."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value) / 1000.0 if value > 1e11 else float(value)
    text = str(value).strip()
    if not text:
        return None
    if re.fullmatch(r"\d+", text):
        return parse_ts(int(text))
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def iso(epoch):
    if epoch is None:
        return "unknown"
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def human_duration(seconds):
    if seconds is None:
        return "unknown"
    seconds = int(seconds)
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return "%dh%02dm" % (hours, minutes)
    if minutes:
        return "%dm%02ds" % (minutes, secs)
    return "%ds" % secs


def group(number):
    return "{:,}".format(int(number))


def join_text(content):
    """Flatten a Pi or Claude content field to plain text."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                for field in ("text", "content", "thinking", "output"):
                    value = block.get(field)
                    if isinstance(value, str):
                        parts.append(value)
                    elif isinstance(value, list):
                        parts.append(join_text(value))
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    if isinstance(content, dict):
        return join_text(content.get("text") or content.get("content"))
    return str(content)


def iter_lines(path):
    """Yield (line number, line) from a transcript without holding it in memory."""
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for lineno, raw in enumerate(handle, 1):
                yield lineno, raw
    except OSError:
        return


def tool_path(name, args):
    lowered = (name or "").lower()
    if lowered in ("read",) + TOOL_WRITE:
        return (args.get("path") or args.get("file_path") or args.get("filePath")
                or args.get("notebook_path"))
    return None


def tool_command(args):
    command = args.get("command") or args.get("cmd")
    if isinstance(command, str) and command.strip():
        return " ".join(command.split())
    return None


# ---------------------------------------------------------------------------
# Transcript parsing. Both harnesses normalize into the same event list:
# assistant turns with usage, tool calls with result size and error flag,
# compactions, and user turns.


def parse_pi(path):
    events, calls, order = [], {}, []
    cwd = model = started = None
    system_chars = 0
    for lineno, raw in iter_lines(path):
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        rtype = record.get("type")
        if rtype == "session":
            cwd = record.get("cwd") or cwd
            started = parse_ts(record.get("timestamp")) or started
        elif rtype == "model_change":
            model = record.get("modelId") or record.get("model") or model
        elif rtype == "compaction":
            events.append({"kind": "compaction", "line": lineno,
                           "ts": parse_ts(record.get("timestamp")),
                           "tokens_before": record.get("tokensBefore")})
        elif rtype == "message":
            message = record.get("message") or {}
            role = message.get("role")
            ts = parse_ts(record.get("timestamp")) or parse_ts(message.get("timestamp"))
            if role == "assistant":
                event = {"kind": "assistant", "line": lineno, "ts": ts,
                         "usage": message.get("usage") or {}, "text_chars": 0,
                         "thinking_chars": 0, "calls": []}
                for block in message.get("content") or []:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        event["text_chars"] += len(block.get("text") or "")
                    elif block.get("type") == "thinking":
                        event["thinking_chars"] += len(block.get("thinking") or "")
                    elif block.get("type") == "toolCall":
                        call = {"id": block.get("id"), "name": block.get("name") or "?",
                                "args": block.get("arguments") or {}, "line": lineno,
                                "ts": ts, "session": str(path)}
                        event["calls"].append(call)
                        calls[call["id"]] = call
                        order.append(call)
                events.append(event)
            elif role == "toolResult":
                call = calls.get(message.get("toolCallId"))
                if call is not None:
                    text = join_text(message.get("content"))
                    call["result_bytes"] = len(text.encode("utf-8", "replace"))
                    call["is_error"] = bool(message.get("isError"))
                    call["result_line"] = lineno
                    call["result_ts"] = ts
                events.append({"kind": "toolResult", "line": lineno, "ts": ts})
            elif role == "user":
                events.append({"kind": "user", "line": lineno, "ts": ts,
                               "chars": len(join_text(message.get("content")))})
            elif role == "system":
                system_chars += len(join_text(message.get("content")))
                for section in (message.get("sections") or {}).values():
                    system_chars += len(section) if isinstance(section, str) else 0
                events.append({"kind": "system", "line": lineno, "ts": ts})
    return {"harness": "pi", "path": str(path), "cwd": cwd, "model": model,
            "started": started, "events": events, "calls": order,
            "system_chars": system_chars}


def parse_claude(path):
    events, calls, order = [], {}, []
    cwd = model = started = None
    system_chars = 0
    for lineno, raw in iter_lines(path):
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        if cwd is None and record.get("cwd"):
            cwd = record["cwd"]
        rtype = record.get("type")
        ts = parse_ts(record.get("timestamp"))
        if started is None and ts:
            started = ts
        if rtype == "assistant":
            message = record.get("message") or {}
            name = message.get("model")
            if name and name != "<synthetic>":
                model = name
            event = {"kind": "assistant", "line": lineno, "ts": ts,
                     "usage": message.get("usage") or {}, "text_chars": 0,
                     "thinking_chars": 0, "calls": []}
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "text":
                        event["text_chars"] += len(block.get("text") or "")
                    elif block.get("type") == "thinking":
                        event["thinking_chars"] += len(block.get("thinking") or "")
                    elif block.get("type") == "tool_use":
                        call = {"id": block.get("id"), "name": block.get("name") or "?",
                                "args": block.get("input") or {}, "line": lineno,
                                "ts": ts, "session": str(path)}
                        event["calls"].append(call)
                        calls[call["id"]] = call
                        order.append(call)
            events.append(event)
        elif rtype == "user":
            message = record.get("message") or {}
            content = message.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        call = calls.get(block.get("tool_use_id"))
                        if call is not None:
                            text = join_text(block.get("content"))
                            call["result_bytes"] = len(text.encode("utf-8", "replace"))
                            call["is_error"] = bool(block.get("is_error"))
                            call["result_line"] = lineno
                            call["result_ts"] = ts
            events.append({"kind": "user", "line": lineno, "ts": ts,
                           "chars": len(join_text(content))})
        elif rtype == "system":
            system_chars += len(join_text(record.get("content") or record.get("message")))
            events.append({"kind": "system", "line": lineno, "ts": ts})
    return {"harness": "claude", "path": str(path), "cwd": cwd, "model": model,
            "started": started, "events": events, "calls": order,
            "system_chars": system_chars}


def sniff(path):
    """The session's recorded working directory and start time, read cheaply."""
    cwd = started = None
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for index, raw in enumerate(handle):
                if index > 80:
                    break
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if cwd is None and record.get("cwd"):
                    cwd = record["cwd"]
                if started is None:
                    started = parse_ts(record.get("timestamp"))
                if cwd and started:
                    break
    except OSError:
        return None, None
    return cwd, started


def discover(cfg, worktree, spawn_epoch):
    """Transcript files whose own recorded cwd is this task's copy."""
    if not worktree:
        return []
    target = os.path.realpath(worktree)
    found = []
    for harness, root in (("pi", cfg.get("pi_root", "")), ("claude", cfg.get("claude_root", ""))):
        if not root or not os.path.isdir(root):
            continue
        for entry in sorted(os.listdir(root)):
            directory = os.path.join(root, entry)
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                if not name.endswith(".jsonl"):
                    continue
                path = Path(directory) / name
                try:
                    if spawn_epoch and path.stat().st_mtime < spawn_epoch - 120:
                        continue
                except OSError:
                    continue
                cwd, started = sniff(path)
                if not cwd or os.path.realpath(cwd) != target:
                    continue
                found.append({"harness": harness, "path": path, "started": started})
    found.sort(key=lambda item: item["started"] or 0)
    return found


def detect_harness(path):
    """Which harness wrote this transcript, from its own record shape."""
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for index, raw in enumerate(handle):
                if index > 40:
                    break
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if record.get("type") == "session":
                    return "pi"
                if "parentUuid" in record or "sessionId" in record:
                    return "claude"
    except OSError:
        pass
    if "/.claude/" in str(path) or "/.claude-" in str(path):
        return "claude"
    return "pi"


def parse_transcript(harness, path):
    return parse_claude(path) if harness == "claude" else parse_pi(path)


# ---------------------------------------------------------------------------
# Signal extraction.


def make(cat, name, count, detail, evidence, recommendation):
    return {"cat": cat, "name": name, "count": count, "detail": detail,
            "evidence": [str(item) for item in evidence],
            "rec": recommendation, "weight": WEIGHTS.get(name, 5)}


def score(finding):
    """Rank by severity first, then by magnitude with the tail capped."""
    return finding["weight"] * (1.0 + min(max(finding["count"], 0), 50) / 50.0)


def short(evidence, limit=MAX_EVIDENCE):
    unique = []
    for item in evidence:
        text = str(item)
        if text not in unique:
            unique.append(text)
    if len(unique) <= limit:
        return ", ".join(unique)
    return "%s (+%d more)" % (", ".join(unique[:limit]), len(unique) - limit)


def loc(index, path, line):
    return "s%d:%d" % (index.get(str(path), 0), line)


def analyze_sessions(sessions, index):
    """Confusion, context, and token findings from the worker transcripts."""
    findings = []
    totals = collections.Counter()
    calls = []
    compactions = []
    assistant_turns = user_turns = system_chars = thinking_chars = output_chars = 0
    started = ended = first_edit_ts = None
    first_edit_call = None
    first_user_chars = 0

    for session in sessions:
        system_chars += session.get("system_chars", 0)
        for event in session["events"]:
            ts = event.get("ts")
            if ts:
                started = ts if started is None else min(started, ts)
                ended = ts if ended is None else max(ended, ts)
            if event["kind"] == "assistant":
                assistant_turns += 1
                thinking_chars += event.get("thinking_chars", 0)
                output_chars += event.get("text_chars", 0)
                for key, value in (event.get("usage") or {}).items():
                    if isinstance(value, (int, float)):
                        totals[key] += value
            elif event["kind"] == "user":
                user_turns += 1
                if first_user_chars == 0:
                    first_user_chars = event.get("chars", 0)
            elif event["kind"] == "compaction":
                compactions.append({"ts": ts, "tokens_before": event.get("tokens_before"),
                                    "session": session["path"], "line": event["line"]})
        for call in session["calls"]:
            calls.append(call)
            if first_edit_ts is None and (call.get("name") or "").lower() in TOOL_WRITE:
                first_edit_ts, first_edit_call = call.get("ts"), call
    calls.sort(key=lambda call: (call.get("ts") or 0, call.get("line") or 0))

    usage = {
        "input": int(totals.get("input") or totals.get("input_tokens") or 0),
        "output": int(totals.get("output") or totals.get("output_tokens") or 0),
        "cache_read": int(totals.get("cacheRead") or totals.get("cache_read_input_tokens") or 0),
        "cache_write": int(totals.get("cacheWrite") or totals.get("cache_creation_input_tokens") or 0),
        "cost": float(totals.get("cost") or 0.0),
    }
    usage["total"] = int(totals.get("totalTokens") or 0)
    if not usage["total"]:
        usage["total"] = usage["input"] + usage["output"] + usage["cache_read"] + usage["cache_write"]

    # Confusion: repeated commands and failed retries.
    commands = collections.defaultdict(list)
    for call in calls:
        if (call.get("name") or "").lower() == "bash":
            command = tool_command(call.get("args") or {})
            if command:
                call["_command"] = command
                commands[command].append(call)
    repeated = sorted(((cmd, items) for cmd, items in commands.items()
                       if len(items) >= THRESHOLDS["repeat_command"]),
                      key=lambda item: -len(item[1]))
    if repeated:
        command, items = repeated[0]
        findings.append(make(
            "confusion", "repeat_command", len(items),
            "`%s` ran %d times" % (command[:120], len(items)),
            [loc(index, c["session"], c["line"]) for c in items],
            "Batch repeated shell runs into the task's own test or eval script so each repeat costs one round trip.",
        ))
    retries = []
    for items in commands.values():
        if len(items) < 2:
            continue
        for previous, current in zip(items, items[1:]):
            if previous.get("is_error"):
                retries.append(current)
                break
    if retries:
        findings.append(make(
            "confusion", "failed_retry", len(retries),
            "%d command(s) were re-run after failing" % len(retries),
            [loc(index, c["session"], c["line"]) for c in retries],
            "A command that fails and is re-run unchanged is a missing precondition; put that setup in the brief or a task script.",
        ))

    streak = best_streak = 0
    streak_start = best_start = None
    failed_calls = []
    for call in calls:
        if call.get("is_error"):
            failed_calls.append(call)
            streak += 1
            streak_start = streak_start or call
            if streak > best_streak:
                best_streak, best_start = streak, streak_start
        else:
            streak, streak_start = 0, None
    if best_streak >= THRESHOLDS["consecutive_failures"]:
        findings.append(make(
            "confusion", "consecutive_failures", best_streak,
            "%d tool calls failed in a row starting at %s" % (
                best_streak, loc(index, best_start["session"], best_start["line"])),
            [loc(index, call["session"], call["line"]) for call in failed_calls],
            "A failure streak means the agent was guessing; give the task a reproduction command and its expected failures up front.",
        ))

    # Confusion: repeated reads, edit churn, and re-reads after compaction.
    reads = collections.defaultdict(list)
    edits = collections.defaultdict(list)
    for call in calls:
        path = tool_path(call.get("name"), call.get("args") or {})
        if not path:
            continue
        lowered = (call.get("name") or "").lower()
        if lowered == "read":
            reads[path].append(call)
        elif lowered in TOOL_WRITE:
            edits[path].append(call)
    hot_reads = sorted(reads.items(), key=lambda item: -len(item[1]))
    if hot_reads and len(hot_reads[0][1]) >= THRESHOLDS["repeat_read"]:
        path, items = hot_reads[0]
        findings.append(make(
            "confusion", "repeat_read", len(items),
            "%s was read %d times" % (path, len(items)),
            [loc(index, c["session"], c["line"]) for c in items],
            "Repeated reads of one file mean its content keeps scrolling out of context; keep a short notes file for it instead.",
        ))
    hot_edits = sorted(edits.items(), key=lambda item: -len(item[1]))
    if hot_edits and len(hot_edits[0][1]) >= THRESHOLDS["edit_churn"]:
        path, items = hot_edits[0]
        findings.append(make(
            "confusion", "edit_churn", len(items),
            "%s was edited %d times" % (path, len(items)),
            [loc(index, c["session"], c["line"]) for c in items],
            "Repeated edits to one file are re-passes; state its target behavior once in the brief so it can land in one pass.",
        ))

    rereads = []
    for compaction in compactions:
        cut = compaction.get("ts")
        if not cut:
            continue
        rereads.extend(repeat_reads_after(reads, cut))
    seen = set()
    unique = []
    for call in rereads:
        key = (call.get("session"), call.get("line"))
        if key in seen:
            continue
        seen.add(key)
        unique.append(call)
    rereads = unique
    if rereads:
        findings.append(make(
            "confusion", "post_compaction_reread", len(rereads),
            "%d file(s) were re-read after a compaction dropped them from context" % len(rereads),
            [loc(index, c["session"], c["line"]) for c in rereads],
            "Compaction is dropping files the agent still needs; keep the working set in a task notes file it can reload cheaply.",
        ))

    # Confusion: exploration before the first edit, and long edit-free runs.
    prefix = [call for call in calls if first_edit_ts is not None and (call.get("ts") or 0) < first_edit_ts]
    if len(prefix) >= THRESHOLDS["exploration_prefix"]:
        evidence = [loc(index, call["session"], call["line"]) for call in prefix]
        if first_edit_call is not None:
            evidence.append("first edit at %s" % loc(index, first_edit_call["session"], first_edit_call["line"]))
        findings.append(make(
            "confusion", "exploration_prefix", len(prefix),
            "%d tool calls ran before the first edit" % len(prefix),
            evidence,
            "Name the files and the exact change in the brief so the agent starts editing instead of exploring.",
        ))
    run = longest = 0
    run_start = best_start = None
    for call in calls:
        if (call.get("name") or "").lower() in TOOL_WRITE:
            run, run_start = 0, None
        else:
            run += 1
            run_start = run_start or call
            if run > longest:
                longest, best_start = run, run_start
    if longest >= THRESHOLDS["no_edit_run"]:
        findings.append(make(
            "confusion", "no_edit_run", longest,
            "%d consecutive tool calls changed nothing" % longest,
            [loc(index, best_start["session"], best_start["line"])],
            "A long read-only run is context burn with no deliverable; ask for a written plan when investigation is genuinely required.",
        ))

    # Token burn: heavy sessions.
    if usage["total"] >= THRESHOLDS["token_total"] or (
            assistant_turns and usage["total"] / assistant_turns >= THRESHOLDS["token_per_turn"]):
        findings.append(make(
            "token", "token_heavy", usage["total"],
            "%s tokens over %d assistant turns (%s per turn)" % (
                group(usage["total"]), assistant_turns,
                group(usage["total"] / assistant_turns) if assistant_turns else "n/a"),
            ["fresh input %s, cache-read %s, output %s" % (
                group(usage["input"]), group(usage["cache_read"]), group(usage["output"]))],
            "Per-turn cost is dominated by standing context; cut the always-loaded material and any file the task does not need.",
        ))

    # Context: compactions and the largest context injectors.
    if compactions:
        peak = max((item["tokens_before"] or 0) for item in compactions)
        findings.append(make(
            "context", "compaction", len(compactions),
            "%d compaction(s), peak context %s tokens" % (len(compactions), group(peak)),
            [loc(index, item["session"], item["line"]) for item in compactions],
            "Context overflowed repeatedly; trim the standing brief and always-loaded instructions, or split the task.",
        ))
    by_result = sorted((call for call in calls if call.get("result_bytes")),
                       key=lambda call: -(call.get("result_bytes") or 0))
    if by_result and by_result[0]["result_bytes"] >= THRESHOLDS["largest_result"]:
        top = by_result[0]
        findings.append(make(
            "context", "largest_result", top["result_bytes"],
            "one tool result returned %s bytes" % group(top["result_bytes"]),
            [loc(index, top["session"], top.get("result_line") or top["line"])],
            "Bound large command output in the task instructions (head, --summary) instead of letting full logs into context.",
        ))
    read_bytes = collections.Counter()
    for path, items in reads.items():
        read_bytes[path] = sum(call.get("result_bytes", 0) for call in items)

    return {
        "findings": findings, "usage": usage, "calls": calls, "compactions": compactions,
        "assistant_turns": assistant_turns, "user_turns": user_turns,
        "system_chars": system_chars, "thinking_chars": thinking_chars,
        "output_chars": output_chars, "first_user_chars": first_user_chars,
        "started": started, "ended": ended, "first_edit_ts": first_edit_ts,
        "read_bytes": read_bytes.most_common(5),
    }


def repeat_reads_after(reads, cut):
    """Reads that repeat a file the session had already read before `cut`."""
    repeated = []
    for path, items in reads.items():
        before = False
        for call in items:
            when = call.get("ts")
            if when is None:
                continue
            if when < cut:
                before = True
            elif before and when >= cut:
                repeated.append(call)
                break
    return repeated


# ---------------------------------------------------------------------------
# Supervisor records: status log and steering inbox.

STATUS_RE = re.compile(r"^(?P<state>[a-zA-Z_-]+)\s*(?P<tail>.*?):\s*(?P<msg>.*)$")
AT_RE = re.compile(r"\[at=(\d+)\]")
KEY_RE = re.compile(r"\[key=([^\]]+)\]")


def analyze_status(path):
    if not path or not path.is_file():
        return {"available": False, "lines": []}
    lines = []
    for lineno, raw in iter_lines(path):
        match = STATUS_RE.match(raw.strip())
        if not match:
            continue
        tail = match.group("tail") or ""
        at = AT_RE.search(tail)
        key = KEY_RE.search(tail)
        lines.append({"line": lineno, "state": match.group("state"),
                      "at": int(at.group(1)) if at else None,
                      "key": key.group(1) if key else None,
                      "msg": match.group("msg").strip()})
    return {"available": True, "lines": lines}


def analyze_inbox(path):
    if not path or not path.is_dir():
        return {"available": False, "open": 0, "handled": 0}
    opened = len([name for name in os.listdir(path) if name.endswith(".msg")])
    handled_dir = path / "handled"
    handled = len([name for name in os.listdir(handled_dir) if name.endswith(".msg")]) \
        if handled_dir.is_dir() else 0
    return {"available": True, "open": opened, "handled": handled}


def status_findings(status, span):
    findings = []
    if not status["available"]:
        return findings
    events = [line for line in status["lines"] if line["at"]]
    points = [line["at"] for line in events]
    if span and span > 900 and len(events) <= 2 and len(events) / (span / 3600.0) < 1:
        findings.append(make(
            "supervision", "status_sparse", len(events),
            "only %d status line(s) over %s" % (len(events), human_duration(span)),
            ["status:%d" % line["line"] for line in events],
            "Sparse status leaves supervision guessing; require a status line at each phase gate in the brief.",
        ))
    gaps = [(current - previous, previous, current)
            for previous, current in zip(points, points[1:])]
    if gaps:
        gap, start, end = max(gaps)
        if gap >= THRESHOLDS["status_gap"]:
            findings.append(make(
                "supervision", "status_gap", int(gap),
                "a %s stretch had no status event" % human_duration(gap),
                ["%s to %s" % (iso(start), iso(end))],
                "A silent stretch hides a stalled worker; require a phase status even when the phase is long.",
            ))
    return findings


def inbox_findings(inbox):
    if not inbox["available"]:
        return []
    total = inbox["open"] + inbox["handled"]
    if total < THRESHOLDS["steering_churn"]:
        return []
    return [make(
        "supervision", "steering_churn", total,
        "%d steering message(s) reached the worker" % total,
        ["%d open, %d handled" % (inbox["open"], inbox["handled"])],
        "Steering after dispatch usually means the brief missed a constraint; move the correction into the brief template.",
    )]


# ---------------------------------------------------------------------------
# no-mistakes pipeline churn. Token totals come only from the owned ledger.


def analyze_pipeline(cfg):
    result = {"available": False, "reason": None, "runs": [], "rounds": [],
              "repasse_files": [], "long_tail": [], "failures": [], "roundtrips": 0,
              "ledger": None}
    ledger_path = cfg.get("ledger")
    if ledger_path and cfg.get("task") and os.path.isfile(ledger_path):
        try:
            for raw in Path(ledger_path).read_text(encoding="utf-8", errors="replace").splitlines():
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(record, dict):
                    continue
                if cfg.get("task") and record.get("task") != cfg["task"]:
                    continue
                result["ledger"] = record
        except OSError:
            result["ledger"] = None

    database, repo, branch = cfg.get("nm_db"), cfg.get("nm_repo"), cfg.get("branch")
    if not database or not repo or not branch or not os.path.isfile(database):
        result["reason"] = (cfg.get("nm_reason")
                            or "no project, branch, or state database attributes pipeline runs")
        return result
    try:
        connection = sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=30)
    except sqlite3.Error:
        result["reason"] = "no-mistakes' state database could not be opened"
        return result
    connection.row_factory = sqlite3.Row
    try:
        repo_row = connection.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchone()
        if repo_row is None:
            result["reason"] = "no repository %s is recorded in no-mistakes' state" % repo
            return result
        since = int(cfg["nm_since"]) if cfg.get("nm_since") else 0
        runs = connection.execute(
            "SELECT id, status, created_at, pr_url FROM runs WHERE repo_id = ? AND branch = ? "
            "AND created_at >= ? ORDER BY created_at, id",
            (repo_row["id"], branch, since),
        ).fetchall()
        result["available"] = True
        result["runs"] = [{"id": row["id"], "status": row["status"],
                           "created_at": iso(row["created_at"]), "pr_url": row["pr_url"]}
                          for row in runs]
        for run in runs:
            for row in connection.execute(
                    "SELECT sr.round, sr.trigger_type, sr.duration_ms, sr.findings_json, s.step_name "
                    "FROM step_rounds sr JOIN step_results s ON s.id = sr.step_result_id "
                    "WHERE s.run_id = ? ORDER BY s.step_order, sr.round", (run["id"],)):
                files = []
                if row["findings_json"]:
                    try:
                        for item in (json.loads(row["findings_json"]).get("findings") or []):
                            if isinstance(item, dict) and item.get("file"):
                                files.append(item["file"])
                    except ValueError:
                        pass
                result["rounds"].append({"run": run["id"], "step": row["step_name"],
                                         "round": row["round"], "trigger": row["trigger_type"],
                                         "duration_ms": row["duration_ms"] or 0,
                                         "files": files, "findings": len(files)})
            for row in connection.execute(
                    "SELECT step_name, round, purpose, duration_ms, exit_status, failure_category, "
                    "model_roundtrips FROM agent_invocations WHERE run_id = ? ORDER BY started_at, id",
                    (run["id"],)):
                result["roundtrips"] += row["model_roundtrips"] or 0
                if row["exit_status"] not in (None, "ok"):
                    result["failures"].append({"run": run["id"], "step": row["step_name"],
                                               "round": row["round"], "exit": row["exit_status"],
                                               "category": row["failure_category"]})
                result["long_tail"].append({"run": run["id"], "step": row["step_name"],
                                            "round": row["round"], "purpose": row["purpose"],
                                            "duration_ms": row["duration_ms"] or 0})
        seen = collections.defaultdict(set)
        for round_row in result["rounds"]:
            for path in set(round_row["files"]):
                seen[path].add(round_row["round"])
        result["repasse_files"] = sorted(((path, sorted(rounds)) for path, rounds in seen.items()
                                          if len(rounds) > 1), key=lambda item: -len(item[1]))
    except sqlite3.Error:
        result["available"] = False
        result["reason"] = "no-mistakes' state database could not be read"
    finally:
        connection.close()
    return result


def pipeline_findings(pipeline):
    findings = []
    extra_rounds = collections.Counter(row["step"] for row in pipeline["rounds"] if row["round"] > 1)
    if extra_rounds:
        described = ", ".join("%s x%d" % item for item in extra_rounds.most_common(5))
        findings.append(make(
            "pipeline", "fix_rounds", sum(extra_rounds.values()),
            "the pipeline ran %d extra fix round(s): %s" % (sum(extra_rounds.values()), described),
            [described],
            "Findings that force a second round usually mean the brief was thin; state the acceptance check the reviewer will apply.",
        ))
    if pipeline["repasse_files"]:
        findings.append(make(
            "pipeline", "repasse_file", len(pipeline["repasse_files"]),
            "%d file(s) drew findings in more than one round" % len(pipeline["repasse_files"]),
            ["%s rounds %s" % (path, ",".join(str(r) for r in rounds))
             for path, rounds in pipeline["repasse_files"]],
            "A file flagged in several rounds is churn; fix its whole class of finding in one pass instead of one instance.",
        ))
    if pipeline["failures"]:
        categories = collections.Counter(item["category"] or item["exit"] for item in pipeline["failures"])
        findings.append(make(
            "pipeline", "pipeline_failure", len(pipeline["failures"]),
            "%d agent invocation(s) ended in failure" % len(pipeline["failures"]),
            [key for key, _ in categories.most_common(5)],
            "A failed gate agent wastes a whole round; check the failure category before re-running the pipeline.",
        ))
    tail = sorted(pipeline["long_tail"], key=lambda item: -item["duration_ms"])[:5]
    if tail and tail[0]["duration_ms"] >= THRESHOLDS["long_tail"]:
        findings.append(make(
            "pipeline", "long_tail", tail[0]["duration_ms"] // 1000,
            "longest single agent run was %s (%s round %d)" % (
                human_duration(tail[0]["duration_ms"] / 1000), tail[0]["step"], tail[0]["round"]),
            ["%s round %d: %s" % (item["step"], item["round"],
                                  human_duration(item["duration_ms"] / 1000)) for item in tail],
            "A single very long agent run is the long tail; split that step's workload or reduce what it must read.",
        ))
    return findings


def outcome_of(pipeline):
    if not pipeline["runs"]:
        return "unknown"
    newest = pipeline["runs"][-1]
    text = str(newest["status"])
    if newest.get("pr_url"):
        text += " (%s)" % newest["pr_url"]
    return text


# ---------------------------------------------------------------------------
# Report assembly.


def render(cfg, sessions, index, analysis, status, inbox, pipeline):
    usage = analysis["usage"]
    span = None
    if analysis["started"] and analysis["ended"]:
        span = analysis["ended"] - analysis["started"]

    findings = list(analysis["findings"])
    findings += status_findings(status, span)
    findings += inbox_findings(inbox)
    findings += pipeline_findings(pipeline)

    lines = ["# Session retrospective: %s" % (cfg.get("task") or "<transcript only>"), ""]
    harness = cfg.get("harness") or (sessions[0]["harness"] if sessions else "unknown")
    runtime_model = cfg.get("model") or next((session["model"] for session in sessions if session["model"]), "")
    facts = [
        ("kind", cfg.get("kind") or "unknown"),
        ("delivery", cfg.get("mode") or "unknown"),
        ("runtime", "%s / %s / effort %s / %s backend" % (
            harness, runtime_model or "unknown", cfg.get("effort") or "unknown",
            cfg.get("backend") or "unknown")),
        ("project", cfg.get("project") or "unknown"),
        ("branch", cfg.get("branch") or "unknown"),
        ("outcome", outcome_of(pipeline)),
        ("report built", now_utc()),
    ]
    if sessions:
        facts.append(("session", "%d transcript(s), %s to %s (%s)" % (
            len(sessions), iso(analysis["started"]), iso(analysis["ended"]), human_duration(span))))
        for position, session in enumerate(sessions, 1):
            facts.append(("session %d" % position, "%s (%s)" % (session["path"], session["harness"])))
        facts.append(("turns", "%d assistant, %d user, %d tool calls" % (
            analysis["assistant_turns"], analysis["user_turns"], len(analysis["calls"]))))
    else:
        facts.append(("session", "no transcript found for this task copy"))
    if pipeline["available"]:
        facts.append(("pipeline", "%d run(s), %d agent invocation(s), %d fix round(s)" % (
            len(pipeline["runs"]),
            len(pipeline["long_tail"]),
            sum(1 for row in pipeline["rounds"] if row["round"] > 1))))
        if pipeline["ledger"] and pipeline["ledger"].get("total"):
            total = pipeline["ledger"]["total"]
            facts.append(("pipeline tokens", "%s input, %s output, %s cache-read (from the spend ledger)" % (
                group(total.get("input_tokens", {}).get("total", 0)),
                group(total.get("output_tokens", {}).get("total", 0)),
                group(total.get("cache_read_tokens", {}).get("total", 0)))))
    elif pipeline["reason"] or cfg.get("nm_reason"):
        facts.append(("pipeline", "unavailable: %s" % (pipeline["reason"] or cfg["nm_reason"])))
    for label, value in facts:
        lines.append("- %s: %s" % (label, value))

    lines.append("")
    lines.append("## Top drivers")
    drivers = sorted(findings, key=score, reverse=True)[:3]
    if drivers:
        for number, finding in enumerate(drivers, 1):
            lines.append("%d. **%s** - %s (%s)" % (
                number, finding["name"], finding["detail"], short(finding["evidence"], 3)))
    else:
        lines.append("No measured signal reached its threshold; this session was already tight.")

    if sessions:
        lines.append("")
        lines.append("## Token burn")
        lines.append("- **worker session**: %s tokens over %s (%s fresh input, %s cache-read, %s output%s)" % (
            group(usage["total"]), human_duration(span), group(usage["input"]),
            group(usage["cache_read"]), group(usage["output"]),
            ", %.2f cost" % usage["cost"] if usage["cost"] else ""))
        brief_path = Path(cfg["data_dir"]) / "brief.md" if cfg.get("data_dir") else None
        brief_size = brief_path.stat().st_size if brief_path and brief_path.is_file() else None
        lines.append("- standing context: %s, system prompt %s chars, thinking %s chars, replies %s chars" % (
            "brief %s bytes" % group(brief_size) if brief_size is not None
            else "first instruction turn %s chars" % group(analysis["first_user_chars"]),
            group(analysis["system_chars"]), group(analysis["thinking_chars"]),
            group(analysis["output_chars"])))

    for title, category in (("Confusion", "confusion"), ("Context size", "context"),
                            ("Pipeline churn", "pipeline"), ("Supervision", "supervision")):
        selected = [finding for finding in findings if finding["cat"] == category]
        if not selected:
            continue
        lines.append("")
        lines.append("## %s" % title)
        for finding in sorted(selected, key=score, reverse=True):
            lines.append("- **%s** (%s): %s" % (finding["name"], finding["count"], finding["detail"]))
            if finding["evidence"]:
                lines.append("  - evidence: %s" % short(finding["evidence"]))

    if analysis["read_bytes"]:
        lines.append("")
        lines.append("## Biggest context injectors")
        for path, size in analysis["read_bytes"]:
            lines.append("- %s: at least %s bytes read into context" % (path, group(size)))

    if pipeline["available"] and pipeline["rounds"]:
        lines.append("")
        lines.append("## Pipeline rounds")
        repasse = {path for path, _ in pipeline["repasse_files"]}
        for row in pipeline["rounds"]:
            mark = " (re-pass)" if repasse.intersection(row["files"]) else ""
            lines.append("- %s round %d (%s): %d finding(s), %s%s" % (
                row["step"], row["round"], row["trigger"], row["findings"],
                human_duration(row["duration_ms"] / 1000), mark))

    lines.append("")
    lines.append("## Recommendations")
    seen = []
    for finding in sorted(findings, key=score, reverse=True):
        if finding["rec"] in seen:
            continue
        seen.append(finding["rec"])
        lines.append("- %s" % finding["rec"])
        if len(seen) >= MAX_RECOMMENDATIONS:
            break
    if not seen:
        lines.append("- Nothing to change; keep the current dispatch shape for tasks like this.")
    if not sessions:
        lines.append("")
        lines.append("> No worker transcript was found, so confusion, context, and worker token burn could not be measured. "
                     "Pass `--transcript <file>`, or run the retrospective while the task copy still exists.")
    return "\n".join(lines)


def main():
    cfg = load_cfg(sys.argv[1:])
    worktree = cfg.get("worktree", "")
    spawn_epoch = int(cfg["spawn_epoch"]) if cfg.get("spawn_epoch") else None

    if cfg.get("transcript"):
        path = Path(cfg["transcript"])
        sessions = [{"harness": detect_harness(path), "path": path,
                     "started": sniff(path)[1]}]
    else:
        sessions = discover(cfg, worktree, spawn_epoch)
    index = {str(session["path"]): position for position, session in enumerate(sessions, 1)}
    parsed = [parse_transcript(session["harness"], session["path"]) for session in sessions]

    if parsed:
        analysis = analyze_sessions(parsed, index)
    else:
        analysis = {"findings": [], "usage": {"input": 0, "output": 0, "cache_read": 0,
                                              "cache_write": 0, "cost": 0.0, "total": 0},
                    "calls": [], "compactions": [], "assistant_turns": 0, "user_turns": 0,
                    "system_chars": 0, "thinking_chars": 0, "output_chars": 0,
                    "first_user_chars": 0, "started": None, "ended": None,
                    "first_edit_ts": None, "read_bytes": []}
    status = analyze_status(Path(cfg["status_file"]) if cfg.get("status_file") else None)
    inbox = analyze_inbox(Path(cfg["inbox_dir"]) if cfg.get("inbox_dir") else None)
    pipeline = analyze_pipeline(cfg)
    sys.stdout.write(render(cfg, parsed, index, analysis, status, inbox, pipeline) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
