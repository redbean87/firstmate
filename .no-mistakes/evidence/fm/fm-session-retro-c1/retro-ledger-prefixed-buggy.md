# Session retrospective: <transcript only>

- kind: unknown
- delivery: unknown
- runtime: pi / fake/m / effort unknown / unknown backend
- project: /tmp/fm-retro-fixcheck/proj
- branch: fm/ledgertest
- outcome: completed
- report built: 2026-10-09T02:43:16Z
- session: 1 transcript(s), 2026-10-09T02:42:42Z to 2026-10-09T02:47:43Z (5m01s)
- session 1: /tmp/fm-retro-fixcheck/tx/double.jsonl (pi)
- turns: 2 assistant, 0 user, 2 tool calls
- pipeline: 1 run(s), 1 agent invocation(s), 0 fix round(s)
- pipeline tokens: 444 input, 555 output, 666 cache-read (from the spend ledger)

## Top drivers
1. **compaction** - 2 compaction(s), peak context 60,000 tokens (s1:5, s1:6)
2. **post_compaction_reread** - 2 file(s) were re-read after a compaction dropped them from context (s1:7)

## Token burn
- **worker session**: 40 tokens over 5m01s (20 fresh input, 0 cache-read, 20 output)
- standing context: first instruction turn 0 chars, system prompt 0 chars, thinking 0 chars, replies 0 chars

## Confusion
- **post_compaction_reread** (2): 2 file(s) were re-read after a compaction dropped them from context
  - evidence: s1:7

## Context size
- **compaction** (2): 2 compaction(s), peak context 60,000 tokens
  - evidence: s1:5, s1:6

## Biggest context injectors
- /x/src/f.ts: at least 20 bytes read into context

## Pipeline rounds
- review round 1 (initial): 0 finding(s), 1s

## Recommendations
- Context overflowed repeatedly; trim the standing brief and always-loaded instructions, or split the task.
- Compaction is dropping files the agent still needs; keep the working set in a task notes file it can reload cheaply.
