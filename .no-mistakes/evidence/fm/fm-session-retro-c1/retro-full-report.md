# Session retrospective: retro-task

- kind: ship
- delivery: unknown
- runtime: pi / fake/m / effort unknown / unknown backend
- project: /tmp/fm-retro-live.sjVqtN
- branch: fm/retro-task
- outcome: unknown
- report built: 2026-10-09T12:08:58Z
- session: 1 transcript(s), 2026-10-09T12:08:56Z to 2026-10-09T12:27:57Z (19m01s)
- session 1: /tmp/fm-retro-live.sjVqtN/pi/--wt--/s.jsonl (pi)
- turns: 20 assistant, 0 user, 20 tool calls
- pipeline: unavailable: no-mistakes resolved no repository from the task copy

## Top drivers
1. **token_heavy** - 4,024,000 tokens over 20 assistant turns (201,200 per turn) (fresh input 20,000, cache-read 4,000,000, output 4,000)
2. **largest_result** - one tool result returned 50,000 bytes (s1:26)
3. **status_gap** - a 2h13m stretch had no status event (2026-10-09T12:09:06Z to 2026-10-09T14:22:16Z)

## Token burn
- **worker session**: 4,024,000 tokens over 19m01s (20,000 fresh input, 4,000,000 cache-read, 4,000 output, 0.20 cost)
- standing context: first instruction turn 0 chars, system prompt 0 chars, thinking 0 chars, replies 0 chars

## Confusion
- **failed_retry** (1): 1 command(s) were re-run after failing
  - evidence: s1:4
- **post_compaction_reread** (1): 1 file(s) were re-read after a compaction dropped them from context
  - evidence: s1:31
- **exploration_prefix** (16): 16 tool calls ran before the first edit
  - evidence: s1:2, s1:4, s1:6, s1:8, s1:10 (+12 more)
- **edit_churn** (4): /x/b.ts was edited 4 times
  - evidence: s1:35, s1:37, s1:39, s1:41
- **repeat_command** (3): `npm test` ran 3 times
  - evidence: s1:2, s1:4, s1:6
- **no_edit_run** (16): 16 consecutive tool calls changed nothing
  - evidence: s1:2
- **repeat_read** (4): /x/a.ts was read 4 times
  - evidence: s1:8, s1:10, s1:12, s1:31

## Context size
- **largest_result** (50000): one tool result returned 50,000 bytes
  - evidence: s1:26
- **compaction** (1): 1 compaction(s), peak context 120,000 tokens
  - evidence: s1:14

## Supervision
- **status_gap** (7990): a 2h13m stretch had no status event
  - evidence: 2026-10-09T12:09:06Z to 2026-10-09T14:22:16Z

## Biggest context injectors
- /x/a.ts: at least 400 bytes read into context
- /x/b.ts: at least 100 bytes read into context
- /x/c.ts: at least 100 bytes read into context
- /x/d.ts: at least 100 bytes read into context
- /x/e.ts: at least 100 bytes read into context

## Recommendations
- Per-turn cost is dominated by standing context; cut the always-loaded material and any file the task does not need.
- Bound large command output in the task instructions (head, --summary) instead of letting full logs into context.
- A silent stretch hides a stalled worker; require a phase status even when the phase is long.
- Context overflowed repeatedly; trim the standing brief and always-loaded instructions, or split the task.
- A command that fails and is re-run unchanged is a missing precondition; put that setup in the brief or a task script.
- Compaction is dropping files the agent still needs; keep the working set in a task notes file it can reload cheaply.
- Name the files and the exact change in the brief so the agent starts editing instead of exploring.
- Repeated edits to one file are re-passes; state its target behavior once in the brief so it can land in one pass.
- Batch repeated shell runs into the task's own test or eval script so each repeat costs one round trip.
- A long read-only run is context burn with no deliverable; ask for a written plan when investigation is genuinely required.
