# Live validation: sleep-aware extension deadlines

Real product, disposable fixtures (`TMPDIR` lab home / temporary package), nothing in the
operator fleet touched. Drivers kept as `10-live-driver-deadlines-and-capture.sh` and
`11-live-driver-adversarial.sh`.

| # | End-user scenario | Result | Artifact |
|---|---|---|---|
| A | Invocation frozen across its invoke bound and resumed inside the bounded grace completes successfully (exit 0, package result preserved) | pass | `01-suspension-resume-inside-grace.txt` |
| B | Invocation frozen across its bound that never resumes work is still killed after the grace; captured evidence names `bound` and the measured `overrun_ms` | pass | `02-frozen-kill-evidence.json` |
| C | Genuine stall without any suspension dies at its bound, ~3.3 s, no grace, no `overrun_ms` | pass | `03-plain-stall-evidence.json`, `03-plain-stall-timing.txt` |
| D | Two suspension kills of one bound differing only by `overrun_ms` (4000 ms then 4100 ms) coalesce into ONE capture sequence, and the stored evidence keeps the first overrun | pass | `04-capture-coalescing-drift.txt` |
| E | A plain timeout followed by a suspension-driven timeout stay two distinct captures (presence of `overrun_ms` is part of identity) | pass | `05-capture-presence-distinct.txt` |
| F | An overrun past the capture gate's range records no host-error identity and allocates a fresh capture instead of a false coalesce | pass | `06-capture-overrun-cap.txt` |
| G | Adversarial: a pause that ends INSIDE the 2000 ms slack still kills at the bound with no grace (the documented limit) | pass | `07-subslack-still-kills.txt` |
| H | Adversarial: the bounded grace is granted at most once — a second suspension across the armed grace is killed 398 ms after resume, keeping the first overrun | pass | `08-single-grace.txt` |
| I | Runner selects the new suite for a capture-gate-only change (real `--changed` selection in a disposable repo) | pass | `09-changed-selection-capture-gate.txt` |

Suite runs: `sleep-deadlines-suite.log` (8/8 in `tests/fm-extension-sleep-deadlines.test.sh`),
`procevent-extension-errors-suite.log` (existing capture-gate regression suite, green).
