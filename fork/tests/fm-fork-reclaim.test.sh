#!/usr/bin/env bash
# Coverage for fork/bin/fm-reclaim: the proof gate and the residue pattern set
# proven against fixture homes - an eligible task with a local report, a
# BLOCKED task whose row names only a path that does not exist, a BLOCKED task
# with no backlog row, a live task, standing resources (the fm-archive set and
# a config/archive-extra-keep addition), a report-linked proof read from the
# row header, a row-body-path proof resolved against the row's repo clone from
# the archive file, the dry run deleting nothing, --apply deleting only pattern
# directories (never a file, never brief/report/evidence/scripts), --days
# holding back fresh residue, and the usage refusals. Every case runs the real
# script against a throwaway FM_HOME; no network, no real home.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECLAIM="$ROOT/fork/bin/fm-reclaim"
TMP_ROOT=$(fm_test_tmproot fm-fork-reclaim)
mkdir -p "$TMP_ROOT"

# new_home <case>: a fixture firstmate home at $TMP_ROOT/<case>/home (so the
# home's parent directory is the case directory, where a repo-clone sibling
# fixture can sit).
new_home() {
  local h="$TMP_ROOT/$1/home"
  mkdir -p "$h/data" "$h/state"
  printf '%s' "$h"
}

run_reclaim() { # <home> [args...]: stdout, exit status preserved for caller
  local h=$1
  shift
  FM_HOME="$h" bash "$RECLAIM" "$@"
}

add_residue() { # <task-dir> <name>...: one pattern directory with a file each
  local dir=$1 n
  shift
  for n in "$@"; do
    mkdir -p "$dir/$n"
    printf 'x\n' > "$dir/$n/file"
  done
}

PATTERN_DIRS=(ws-run agents agents-2 node_modules __pycache__ .cache tmp scratch)

test_local_proof_reclaims_only_pattern_directories() {
  local h out t n
  h=$(new_home local-proof)
  t="$h/data/alpha"
  mkdir -p "$t"
  printf '# report\n' > "$t/report.md"
  printf '# brief\n' > "$t/brief.md"
  printf '# launch\n' > "$t/launch-brief.md"
  printf 'diff --git a/x b/x\n' > "$t/fix.patch"
  printf 'a: 1\n' > "$t/config.yml"
  mkdir -p "$t/evidence/scripts"
  printf 'keep\n' > "$t/evidence/scripts/run.sh"
  printf 'keep\n' > "$t/evidence/proof.txt"
  add_residue "$t" "${PATTERN_DIRS[@]}"
  # Files that match the pattern names must survive: only directories go.
  printf 'file-not-dir\n' > "$t/ws-note"
  printf 'nested file\n' > "$t/evidence/scripts/tmp"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "ELIGIBLE alpha" "the local-report task is eligible"
  assert_contains "$out" "proof: data/alpha/report.md" "the proof names where it was found"
  assert_contains "$out" "RECLAIM: 1 eligible task(s), 8 folder(s)" "the total counts the eight trees"
  assert_contains "$out" "dry run; --apply to delete" "the dry run states itself"
  for n in "${PATTERN_DIRS[@]}"; do
    assert_present "$t/$n" "dry run must not delete $n"
  done

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_contains "$out" "FREED alpha" "apply reports what was freed per task"
  assert_contains "$out" "freed" "apply reports a freed total"
  for n in "${PATTERN_DIRS[@]}"; do
    assert_absent "$t/$n" "apply must delete pattern directory $n"
  done
  assert_present "$t/report.md" "apply must never delete report.md"
  assert_present "$t/brief.md" "apply must never delete brief.md"
  assert_present "$t/launch-brief.md" "apply must never delete launch-brief.md"
  assert_present "$t/fix.patch" "apply must never delete a patch file"
  assert_present "$t/config.yml" "apply must never delete a yml file"
  assert_present "$t/evidence/scripts/run.sh" "apply must never delete evidence/scripts"
  assert_present "$t/evidence/proof.txt" "apply must never delete evidence"
  assert_present "$t/ws-note" "apply must never delete a file even when its name matches"
  assert_present "$t/evidence/scripts/tmp" "apply must never delete a file nested under evidence"
  pass "local proof: dry run deletes nothing, apply deletes only pattern directories"
}

test_blocked_task_with_no_existing_row_path_is_never_touched() {
  local h out t
  h=$(new_home blocked-row)
  t="$h/data/beta"
  mkdir -p "$t"
  add_residue "$t" ws-beta
  printf '# Backlog\n\n## Queued\n- [ ] beta - Beta run (repo: model-evals) (kind: ship) (since 2026-11-06)\n  Finding lives in results/beta-findings.md.\n' \
    > "$h/data/backlog.md"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "BLOCKED beta" "the unproven task is listed BLOCKED"
  assert_contains "$out" "needs: write data/beta/report.md" "the BLOCKED line says what would satisfy it"
  assert_contains "$out" "BLOCKED: 1 task(s)" "the blocked total counts it"

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_not_contains "$out" "FREED beta" "apply must never free a BLOCKED task"
  assert_present "$t/ws-beta" "apply must never touch a BLOCKED task's residue"
  pass "blocked: a row naming no existing path is listed and never touched"
}

test_blocked_task_with_no_backlog_row_is_named() {
  local h out
  h=$(new_home blocked-norow)
  mkdir -p "$h/data/zeta/ws-zeta"
  printf 'x\n' > "$h/data/zeta/ws-zeta/file"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "BLOCKED zeta" "a task with no row and no local proof is BLOCKED"
  assert_contains "$out" "no backlog row found for zeta" "the BLOCKED line names the missing row"
  pass "blocked: a task with no backlog row says so"
}

test_live_task_is_skipped_whatever_it_holds() {
  local h out t
  h=$(new_home live-task)
  t="$h/data/gamma"
  mkdir -p "$t"
  printf '# report\n' > "$t/report.md"
  add_residue "$t" ws-gamma
  : > "$h/state/gamma.meta"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "SKIP gamma  live task" "a live task is skipped before any proof"
  assert_not_contains "$out" "ELIGIBLE gamma" "a live task is never eligible"

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_not_contains "$out" "FREED gamma" "apply must never free a live task"
  assert_present "$t/ws-gamma" "apply must never touch a live task's residue"
  pass "live: the task record keeps the residue untouched"
}

test_standing_resources_are_skipped() {
  local h out
  h=$(new_home standing)
  mkdir -p "$h/data/archive/ws-old" "$h/data/my-keep/ws-keep" "$h/data/plain-task"
  printf 'x\n' > "$h/data/archive/ws-old/file"
  printf 'x\n' > "$h/data/my-keep/ws-keep/file"
  mkdir -p "$h/config"
  printf 'my-keep\n' > "$h/config/archive-extra-keep"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "SKIP archive  standing resource" "fm-archive's KEEP set is skipped"
  assert_contains "$out" "SKIP my-keep  standing resource" "config/archive-extra-keep additions are skipped"

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_present "$h/data/archive/ws-old" "apply must never touch a standing resource"
  assert_present "$h/data/my-keep/ws-keep" "apply must never touch a home-added standing resource"
  pass "standing: fm-archive's keep set and home additions are skipped"
}

test_report_link_in_the_row_header_proves_without_a_local_report() {
  local h out t
  h=$(new_home report-link)
  t="$h/data/delta"
  mkdir -p "$t"
  add_residue "$t" ws-delta
  printf 'the findings, recorded\n' > "$h/data/delta-findings.md"
  printf '# Backlog\n\n## Done\n- [x] delta - Delta eval run data/delta-findings.md (repo: firstmate) (kind: ship) (reported 2026-11-06)\n  Residue of a finished run.\n' \
    > "$h/data/backlog.md"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "ELIGIBLE delta" "the row's recorded report link proves the finding"
  assert_contains "$out" "proof: row report link data/delta-findings.md" "the proof names the row link"
  assert_not_contains "$out" "proof: data/delta/report.md" "no local report exists to lean on"

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_present "$t" "the task folder itself stays"
  assert_absent "$t/ws-delta" "the residue behind the row link is reclaimed"
  pass "report-linked proof: the row's recorded link unlocks the reclaim"
}

test_row_body_path_in_the_archive_resolves_against_the_repo_clone() {
  local h out t
  h=$(new_home body-path)
  t="$h/data/epsilon"
  mkdir -p "$t"
  add_residue "$t" ws-epsilon
  mkdir -p "$h/../model-evals/results"
  printf 'the committed findings\n' > "$h/../model-evals/results/epsilon-findings.md"
  printf '# Backlog\n\n## Archived 2026-11-01\n- [x] epsilon - Epsilon run https://github.com/x/y/pull/1 (repo: model-evals) (kind: ship) (merged 2026-11-01)\n  Findings committed as results/epsilon-findings.md in the model-evals clone.\n' \
    > "$h/data/done-archive.md"

  out=$(run_reclaim "$h") || fail "dry run must exit 0"
  assert_contains "$out" "ELIGIBLE epsilon" "the archived row's body path proves the finding"
  assert_contains "$out" "proof: row body path results/epsilon-findings.md ->" "the proof names the body path it resolved"

  out=$(run_reclaim "$h" --apply) || fail "apply must exit 0"
  assert_absent "$t/ws-epsilon" "the residue behind the body-path proof is reclaimed"
  assert_present "$h/../model-evals/results/epsilon-findings.md" "the repo clone is never written"
  pass "row-body proof: an archived row's body path resolves against the repo clone"
}

test_days_holds_back_recent_residue() {
  local h out t
  h=$(new_home days)
  t="$h/data/omega"
  mkdir -p "$t"
  printf '# report\n' > "$t/report.md"
  add_residue "$t" ws-old ws-fresh
  touch -t 202001010000 "$t/ws-old/file"
  mkdir -p "$h/data/xi"
  printf '# report\n' > "$h/data/xi/report.md"
  add_residue "$h/data/xi" ws-recent

  out=$(run_reclaim "$h" --days 1) || fail "--days dry run must exit 0"
  assert_contains "$out" "ELIGIBLE omega" "the task with old residue stays eligible"
  assert_contains "$out" "kept (within 1 days)" "fresh residue is reported as held back"
  assert_contains "$out" "SKIP xi  all residue touched within 1 days" "a task with only fresh residue is skipped"

  out=$(run_reclaim "$h" --days 1 --apply) || fail "--days apply must exit 0"
  assert_absent "$t/ws-old" "old residue is reclaimed under --days"
  assert_present "$t/ws-fresh" "fresh residue is held back under --days"
  assert_present "$h/data/xi/ws-recent" "a wholly fresh task is never touched under --days"
  pass "--days: residue touched within the window is held back"
}

test_usage_refusals() {
  local h out rc
  h="$TMP_ROOT/not-a-home"
  mkdir -p "$h"
  rc=0
  out=$(run_reclaim "$h") || rc=$?
  expect_code 1 "$rc" "a home without data/ and state/ is refused"
  assert_contains "$out" "not a firstmate home" "the refusal names what is missing"

  h=$(new_home usage)
  rc=0
  out=$(run_reclaim "$h" --bogus) || rc=$?
  expect_code 2 "$rc" "an unknown argument is a usage error"
  rc=0
  out=$(run_reclaim "$h" --days nope) || rc=$?
  expect_code 2 "$rc" "--days needs a number"
  pass "usage: bad homes and bad arguments refuse loudly"
}

fork_run_tests
