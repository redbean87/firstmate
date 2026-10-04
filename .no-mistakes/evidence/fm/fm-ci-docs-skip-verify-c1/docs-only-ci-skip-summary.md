# Docs-only CI skip verification - test-phase evidence

Branch under test: `fm/fm-ci-docs-skip-verify-c1` (base `f0bdbd73`, target `778ec13e`).
Diff: exactly one file, `docs/discord-integration.md` (3 insertions, 3 deletions),
renaming the ambiguous "`register` the slash commands" instruction to
`fm-discord-commands.sh register`.

## Scenarios and results

### 1. The docs-only change names the real register entry point (pass, live)
Drove the real CLI in a disposable `FM_HOME` (`scenario-1-discord-register-cli.txt`):
- `bin/fm-discord-commands.sh --help` prints usage including `fm-discord-commands.sh register` (exit 0)
- `bin/fm-discord-commands.sh register` is dispatched as a real subcommand and refuses
  only because an isolated home has no Discord config: `not configured` (exit 1)
- an unknown verb is rejected with usage (exit 2), proving `register` is a recognised verb
  and not free prose

### 2. The workflow's own change-scope detector classifies this diff as non-heavy (pass, not live)
`drive-scope-step.sh` extracts the `detect-changes` scope step from `.github/workflows/ci.yml`
by step id (typed YAML parse), substitutes the four `${{ ... }}` context expressions with the
pull_request payload values, and executes it under `bash` with `set -eu` and a real
`GITHUB_OUTPUT`. Against `f0bdbd73...778ec13e` it emits `code=false`, `shell=false`
(`scenario-2-4-scope-detector-runs.txt`).

### 3. Adversarial: a code+shell change is not skipped (pass, not live)
Same real step against the historical `7474542f...f0bdbd73` diff (touches `bin/`, `docs/`,
`tests/`) emits `code=true`, `shell=true`.

### 4. Adversarial: an unreadable diff fails closed to full rigor (pass, not live)
Same real step with a nonexistent base SHA keeps the fail-closed defaults
`code=true`, `shell=true`.

### Job-set decisions (`scenario-2-4-job-set-decisions.txt`)
`job-set-eval.rb` parses ci.yml structurally and evaluates every job-level `if`
(unknown condition shapes raise rather than silently reading RUN):
- detect-changes success + `code=false`/`shell=false` (docs-only PR) -> SKIP for
  `tests-portable-parallel-1`, `tests-portable-parallel-2`, `tests-portable-serial` (x9 shards),
  `tests-herdr`, `tests-timing-aggregate`, `macos-stock-bash`; RUN for
  `detect-changes`, `lint` (x2), `test-coverage`, `invariants`
- code+shell change -> all jobs RUN
- detector failure -> all jobs RUN (fail closed)

### 5. The PR's actual GitHub Actions job set (UNTESTED)
`scenario-5-gh-inventory.txt` records the exhaustive checks made:
- No PR exists for this branch (`gh pr list --state all --head fm/fm-ci-docs-skip-verify-c1` empty);
  the branch is not on the remote (`git ls-remote origin refs/heads/...` empty).
- No docs-only CI run exists to observe instead: all 8 historical PRs and all 7 main-push
  CI runs touched non-docs files (per-PR file lists and run head SHAs recorded).
- Creating the PR requires `git push` + `gh pr create`, which are (a) remote writes outside
  the test worktree (workspace boundary) and (b) the pipeline's push/PR/CI phases, which the
  gate-step phase contract reserves to the outer executor.
- ci.yml has no `workflow_dispatch`, so no run can be triggered without a PR; a local Actions
  emulator would be a fixture standing in for GitHub, not the live product.

## Supporting targeted tests run
- `bash tests/fm-ci-workflow.test.sh` -> all 10 assertions ok (incl. "heavy lanes gate on the
  change-scope signals and fail closed")
- `bash tests/fm-documentation-audiences.test.sh` -> all 4 assertions ok
- `bin/fm-test-run.sh --changed --list` -> no tests selected for a docs-only diff vs origin/main

## Artifacts in this directory
- `scenario-1-discord-register-cli.txt`
- `scenario-2-4-scope-detector-runs.txt`
- `scenario-2-4-job-set-decisions.txt`
- `scenario-5-gh-inventory.txt`
- `drive-scope-step.sh`, `job-set-eval.rb` (the drivers)
