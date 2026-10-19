# Stop-hook visibility fix — live validation evidence

Change under test: `495896dd` on `fm/fm-stop-hook-emit-fix-c1` (base `7587473a`).
Only `bin/fm-supervision-host.sh` changes: the at-turn hand-back refusal branch
(`downtime-unrestored`) now stores its already-composed verdict in `REFUSAL`,
logs it, clears `ARM_TEXT` and prints it with the script's existing `emit` before
`exit 1`. No timeout, retry, arm/take-over or hook change (`change.diff`).

## Why the race matters

The Stop hook (`bin/fm-claude-stop-autoarm.sh`) retries a host park only when the
host produced **no stdout** (`[ ! -s "$OUT" ]`). Before the fix the refusal branch
logged the verdict to `state/.supervision-host.log` and exited 1 without printing
anything, so the verdict was observable only if some *other* line (the first-cycle
`watcher: started ...` ready line) happened to be streamed to stdout before the
arm closed. That is a race. When the ready line lost the race, the hook treated a
decided refusal as silent host death, ran a second park that took over the left
successor cycle, and there either hung past the test's 25 s budget (CI) or
delivered a close-less verdict — the reported flake.

The drivers below reproduce both sides of that race against the real
`fm-supervision-host.sh park`, the real Stop hook, the real arm/watcher and the
real wake queue/lease scripts, in a throwaway fixture home (the suite's own
`make_primary_home` harness; the only fake is the model engine stub and the
injected `mktemp` failure that forces the refusal). The `rm` shim copies the
hook's captured host-stdout file before the hook deletes it, so
`host-stdout-seen.txt` is exactly what the hook itself observed.

- `drivers/evidence-drive.sh` — fixture as the suite's at-turn downtime case
  (ready line normally wins the race).
- `drivers/race-lost-drive.sh` — same fixture plus a deterministic loss of the
  ready-line race (suppresses only the host's
  `grep -E -m 1 '^watcher: (started|attached) '` ready-line stream), which is the
  CI-load ordering.

Both drivers are `head -n 2971 tests/fm-supervision-host.test.sh` plus a scenario
block, so the fixture is identical to the suite's.

## Results

### Race lost (the flake ordering)

| build | host stdout seen by the hook | hook | offer/park count | hook.err verdict |
|---|---|---|---|---|
| post-fix `495896dd` | `pass-through	downtime-unrestored	signal: ...demo.status` | exit 2, attempt 1 | 2, one host park | `auto-arm FAILED ... broken after 1 bounded attempts` + `last one exited 1 without a wake` |
| pre-fix `7587473a` | *(empty)* | exit 2 only after retry, attempt 2 | 2, **two host parks** (`take-over arm=...`) | `auto-arm FAILED ... broken after 2 bounded attempts` + `last one exited 0 without a wake`; no refusal line anywhere |

Artifacts: `race-lost-post-fix/`, `race-lost-pre-fix/`,
`race-lost-pre-fix-a/`, `race-lost-pre-fix-b/` (three pre-fix runs were
identical: every one ran a second take-over park because the refusal never
reached stdout; one post-fix run is enough because it is now deterministic).

### Race won (pre-existing behaviour must not change)

| build | host stdout seen by the hook | hook |
|---|---|---|
| post-fix | `watcher: started pid=...` then `pass-through	downtime-unrestored	signal: ...` | exit 2, attempt 1, FAILED notice |
| pre-fix | `watcher: started pid=...` only | exit 2, attempt 1, FAILED notice (identical outcome — this ordering never depended on the fix) |

Artifacts: `post-fix/`, `pre-fix/`.

### Verdict line is not an actionable wake

In every captured host stdout the `signal:` close only ever appears *inside* the
tab-separated refusal verdict, never as its own line, so the owner's
`^(signal:|...)` classifier does not read the undelivered close as a new
actionable wake. That is the `ARM_TEXT=` clearing in the change.

### Targeted suites (fixed tree)

```
bin/fm-test-run.sh tests/fm-supervision-host.test.sh tests/fm-claude-stop-autoarm.test.sh
FM_TEST_END ... tests/fm-supervision-host.test.sh exit=0 duration_ms=588634 gate_skip=false
FM_TEST_END ... tests/fm-claude-stop-autoarm.test.sh exit=0 duration_ms=63796 gate_skip=false
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=652560
```

134 `ok -` assertions, 0 failures, 0 gate skips (`targeted-suites.log`).

### Not covered here (by design)

The ready-line race itself still exists: this change removes the *silent* outcome
of losing it, it does not make the refusal branch independent of the race
ordering for other lines. The user intent explicitly tracks the race-covering
regression as separate later work.
