---
name: session-retro
description: >-
  Agent-only procedure for retrospecting one finished worker session.
  Load when the captain asks to retrospect a finished task or asks where a task's confusion, context growth, or token spend came from, when repeated waste appears across recent runs (unexplained re-passes, thin status discipline, long tails), or before changing a brief or template on the strength of a single bad run.
user-invocable: false
metadata:
  internal: true
---

# session-retro

Run a retrospective on one finished worker session to find where it spent confusion, context, and tokens, so the next dispatch is cheaper.
`bin/fm-session-retro.sh` is the mechanism and owns its evidence sources, signal thresholds, and report schema; its header is authoritative and this skill does not restate it.

## When to run one

Run a retrospective when the captain asks for one, and when recent runs show repeated waste the captain wants understood rather than guessed at.
Three questions justify it on their own: why a task took extra review rounds, why a worker went quiet or re-explored, and why a session burned far more tokens than its deliverable warranted.
Do not run one on live work as a substitute for supervising it, and do not run one to manufacture a justification for a change nobody asked for.
A single bad run is a hint; two or more runs showing the same signal in the same place is the evidence that justifies editing a brief, a template, or a standing instruction.

## How to run one

Run the retrospective against the task id while the task record and its copy still exist, because that is the only time every source is attributable at once:

    bin/fm-session-retro.sh <task-id>

Keep the report as durable evidence by redirecting it, normally to the task's own data directory:

    bin/fm-session-retro.sh <task-id> > data/<task-id>/retro.md

After cleanup only the harness transcript survives, so pass it, plus the project and branch when the pipeline churn still matters:

    bin/fm-session-retro.sh --transcript <session-file> --project <clone> --branch <branch>

The script reads only and never writes to the task or its copy.
It reports which sources it could not read; a missing source is a gap in the report, never a licence to guess what it would have said.

## How to read the report

Read the top drivers first, then the sections.
The top three drivers are the findings with the highest severity and magnitude, so they are the ones worth acting on this round; the remaining sections are the full evidence behind them.
Each finding names a count and file:line evidence (`s1:120` is line 120 of session 1, whose full path is listed above the findings), so a claim can be checked before it changes anything.

Signals and what they mean in practice:

- Compaction, post-compaction re-reads, and a large result: context overflowed or was flooded. The fix is smaller standing context, not a stronger model.
- Repeated commands, failed retries, and consecutive failures: the brief was missing a precondition or a reproduction command, and the worker guessed.
- Repeated reads and edit churn: the worker could not hold the target behavior, or the brief named a goal instead of the change.
- Exploration before the first edit and long edit-free runs: investigation that the brief could have replaced with named files and an exact change.
- Extra review rounds and files flagged in several rounds: the acceptance check the reviewer applied was not stated, so the worker fixed instances instead of the class.
- A long single agent run: one step carries more than it should, and it is where the tail lives.
- Status gaps and steering traffic: supervision had to guess or correct after dispatch, which is brief work wearing a different hat.

## What to do with the findings

Act on the top drivers, and only where a signal is structural rather than incidental to one task.
Route what a retrospective produces to its right owner rather than leaving it in the report:

- A repeated brief defect belongs in the brief scaffold or dispatch profile that produced it, as a normal tracked change.
- A standing instruction that keeps being re-read should be trimmed where it lives, not copied into a task.
- A fleet-local operational fact belongs in `data/learnings.md`.
- A home-domain captain preference belongs in `data/captain.md`.
- A follow-up worth doing later is a backlog item.

The report is private evidence and keeps exact identifiers, paths, and internal labels.
Anything reported to the captain is an outcome: how much the run cost, where it went, and what changes next, translated out of internal vocabulary per the escalation rules.
Never report a retrospective as finished before saying what, if anything, it changes.
