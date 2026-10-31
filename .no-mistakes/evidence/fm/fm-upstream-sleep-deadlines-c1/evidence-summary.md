# Live validation: extension host deadlines across system sleep (PR #8039)

Change under test: `fm/fm-upstream-sleep-deadlines-c1` at `45e38e10` (base `6946058b`).
Product surface driven: the real extension host CLI (`bin/fm-extension.mjs`), the real
launch barrier (`bin/fm-extension-launch-barrier.mjs`), and the real process-event
pipeline (`bin/fm-procevent.sh` + `bin/fm-procevent-extension-capture.pl`) with real
fixture extension packages, real SIGSTOP/SIGCONT suspension simulation, and a disposable
`FM_HOME` per case. No Herdr session, primary, or fleet state was touched; no product
source was modified to drive a scenario.

| # | Scenario | Result | Log |
| --- | --- | --- | --- |
| A | Healthy invocation under the bound is untouched (rc 0, ~0.6 s, no deadline evidence) | pass | `live-invoke-deadlines.log` |
| B | Genuine stall dies at its bound (rc 70, ~3.9 s, `bound:"invoke"`, no `overrun_ms`, no grace) | pass | `live-invoke-deadlines.log` |
| C | Invocation frozen 7.8 s across its 3 s bound and resumed inside the grace completes (rc 0) | pass | `live-invoke-deadlines.log` |
| D | Invocation frozen and never resumed is killed one grace after resume (5.4 s window), recorded `overrun_ms` 4319 | pass | `live-invoke-deadlines.log` |
| E | Genuine stall retried through the real pipeline coalesces into one capture with host-error identity | pass | `live-invoke-deadlines.log` |
| F | Host frozen inside the launch-ready wait (no `release.json` at freeze) past its 5 s bound recovers (rc 0) with the unmodified product barrier | pass | `live-launch-barrier.log` |
| G1 | Barrier startup bound intact when it fires on time (rc 125 at ~5.2 s, no suspension wording) | pass | `live-launch-barrier.log` |
| G2 | Barrier frozen across its bound and released inside the grace delegates to the package (rc 0) | pass | `live-launch-barrier.log` |
| G3 | Barrier frozen and never released dies exactly one grace after resume (5.3 s) naming `bound startup` and the suspension | pass | `live-launch-barrier.log` |
| H | Real suspension-driven kill through the real pipeline is captured as host-error with `overrun_ms` | pass | `live-capture-gate.log` |
| I | `overrun_ms` = 9007199254740991 (MAX_SAFE_INTEGER) keeps host-error identity and retry coalescing | pass | `live-capture-gate.log` |
| J | `overrun_ms` = 10000000000000000 (17 digits) is refused: no host-error identity, retries do not coalesce | pass | `live-capture-gate.log` |
| K | A deadline firing 1.2 s late (inside the 2 s slack) is not treated as a suspension: no grace, no `overrun_ms` | pass | `live-slack-and-shapes.log` |
| L | Legacy four-key host error still coalesces through the edited capture gate | pass | `live-slack-and-shapes.log` |
| M | A five-key envelope whose extra key is not a valid bound is refused | pass | `live-slack-and-shapes.log` |
| N | Launch-ready failure after a suspension grace is captured with `bound:"launch-ready"` + `overrun_ms` and host-error identity | pass | `live-launch-ready-failure.log` |

## Regression proof

- `shipped-regression-test.log`: the six shipped sleep-deadline cases pass on the change.
- `regression-before-fix.log`: the same test file running against the pre-fix host,
  barrier, and capture gate fails immediately at "a timeout evidence did not name its bound"
  (exit 1), so the suite does catch the reported bug.
- Base-code frozen-resume drive: a resumed invocation failed with rc 70 on base code
  (`drive1-base.sh`), while the same scenario completes with rc 0 on the change.
- `space-path-checkout.log` / `space-path-unquoted-repro.log`: the boundary cases pass from
  a checkout whose path contains a space, and restoring the unquoted shim reproduces
  `/tmp/fm: No such file or directory` during register-extension.

## Notes

- No visual surface exists for this change (no UI, HTML, or renderer); evidence is CLI
  transcripts and persisted process-event records.
- `preexisting-invocation-cleanup.log`: the `lifecycle-invocation-cleanup` segment fails
  identically at base and head ("interrupted extension host exited before its exact process
  group was gone"), so it is a pre-existing machine-specific failure, not a regression here.
- The remote-activation binding segment fails identically at base and head because the
  remote job's restricted child PATH does not include this machine's volta-managed node
  (`env: node: No such file or directory`); unrelated to this change.
- `docs/extension-bindings.md` is prose with no executable surface; its behavioral claims
  were cross-checked against scenarios A–N.
