# T7 — Firstmate ChatGPT project routing: live validation evidence

Target commit: `44c5ac683d7d7d50abaf45a326f8158fb8f3c609` (branch `fm/bridge-fork-caller`)

## What was driven

The real, unmodified `fork/chatgpt/fm-chatgpt-loop.sh` and `fork/chatgpt/fm-chatgpt-consult.sh`
from the gate worktree, as an operator runs them, against a throwaway loopback bridge double on
`127.0.0.1:17931`. The double records every request's headers and body and writes
`<routes>/<trace>.outcome.json` exactly as the deployed fork documents (`fork/README`
"Project routing", `fork/project-route.ts`, inspected read-only in `~/tools/codex-chatgpt-web`).
Each case used an isolated `HOME`/`FM_HOME` under `/tmp` and was torn down afterwards.

The operator's live bridge (`127.0.0.1:17841`, home `~/tools/codex-chatgpt-web/home`) was only
read — never posted to — so no real ChatGPT turn was spent and no operator state changed. After the
run, none of the harness thread ids or prompt texts appear in that bridge's `responses-state.json` or
`runtime/luna-checkpoints.json` (the one 13:03 turn visible in its diagnostics has thread id `t` and
prompt `x`, i.e. another process, not this run). Its
own `fork-routes/*.outcome.json` already contains a prior live acceptance record
(`{"project":"firstmate","decision":"project","member":true}`) and
`fork/project-route.ts` exports `PROJECT_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/`,
the exact pattern this change now enforces.

## Scenarios and results

| # | Scenario | Result |
|---|----------|--------|
| S1 | `consult` with `--project firstmate` puts `x-fm-chatgpt-project: firstmate` on the wire; without `--project` no routing header is sent and the model slug is unchanged | pass |
| S2 | `loop init --project expo-bowling-journal` persists the name; the audit `consult` sends it; `init` without `--project` sends nothing | pass |
| S3 | Invalid names (`../etc/passwd`, 65 chars, `has space`, `.hidden`, `sl/ash`) refused with exit 2 at both entry points, zero bridge requests, no loop record written | pass |
| S4 | 64-character name accepted end-to-end (header length 64); 65-character name refused — the bridge's own length bound | pass |
| S5 | A trailing valueless flag (`--prompt-file`, `--mode`, `--thread`, `--project`, and `loop init --project`) exits 2 immediately instead of spinning | pass |
| S6 | A bridge-recorded fallback prints exactly one advisory stderr notice through the loop, exit 0, answer intact, state advanced with no `last_error` | pass |
| S7 | Adversarial: a successful project route, a stale fallback outcome, and another project's fallback are all silent; a positive control in the same setup fires the notice | pass |
| S8 | `--project` with no bridge still fails closed (exit 1, empty stdout, prerequisite diagnostic) — routing never masks a real failure | pass |
| S9 | The plan-stage consult carries the project header too, not only the audit consult | pass |

## Artifacts

- `t7-live-project-routing-transcript.txt` — full command/output transcript for S1–S9
- `t7-wire-requests.json` — captured requests: no project header vs. `x-fm-chatgpt-project: firstmate`
- `t7-fork-chatgpt-tests.txt` — `fork/tests/fm-fork-chatgpt-consult.test.sh` (20 ok) and
  `fork/tests/fm-fork-chatgpt-loop.test.sh` (62 ok), both exit 0
