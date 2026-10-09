# Session retrospective: t2

- kind: ship
- delivery: unknown
- runtime: pi / fake/m / effort unknown / unknown backend
- project: /tmp/fm-retro-dedup.eEwJaM
- branch: fm/t2
- outcome: unknown
- report built: 2026-10-09T12:09:02Z
- session: 1 transcript(s), 2026-10-09T12:09:02Z to 2026-10-09T12:12:03Z (3m01s)
- session 1: /tmp/fm-retro-dedup.eEwJaM/pi/--wt--/s.jsonl (pi)
- turns: 2 assistant, 0 user, 2 tool calls
- pipeline: unavailable: no-mistakes resolved no repository from the task copy

## Top drivers
1. **compaction** - 2 compaction(s), peak context 100,000 tokens (s1:4, s1:5)
2. **post_compaction_reread** - 1 file(s) were re-read after a compaction dropped them from context (s1:6)

## Token burn
- **worker session**: 220 tokens over 3m01s (200 fresh input, 0 cache-read, 20 output)
- standing context: first instruction turn 0 chars, system prompt 0 chars, thinking 0 chars, replies 0 chars

## Confusion
- **post_compaction_reread** (1): 1 file(s) were re-read after a compaction dropped them from context
  - evidence: s1:6

## Context size
- **compaction** (2): 2 compaction(s), peak context 100,000 tokens
  - evidence: s1:4, s1:5

## Biggest context injectors
- /x/F.ts: at least 200 bytes read into context

## Recommendations
- Context overflowed repeatedly; trim the standing brief and always-loaded instructions, or split the task.
- Compaction is dropping files the agent still needs; keep the working set in a task notes file it can reload cheaply.
