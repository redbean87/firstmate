#!/usr/bin/env bash
# Fork CI upstream guard: fork/bin/fm-fork-workflow-guard's own rules against
# a fixture gh (no network), the fork-ci.yml seam (permissions, step wiring,
# and the declared step command driven end to end through the real script),
# and the ci.yml reminder fm-fork-sync prints from prepare and check.
# The real tree is never edited; sync fixtures live in a throwaway repo.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-ci-upstream-guard)
mkdir -p "$TMP_ROOT/bin"
GUARD="$ROOT/fork/bin/fm-fork-workflow-guard"
SYNC="$ROOT/fork/bin/fm-fork-sync"
WORKFLOW="$ROOT/.github/workflows/fork-ci.yml"
REMINDER='reminder: re-enable ci.yml only for a sync PR that names a compatibility risk, then disable it again'

# install_fake_gh: a fixture GitHub CLI on PATH that answers the one endpoint
# the guard reads from <fixture>/workflows.json (or raw-<body> for malformed
# answers) and fails when <fixture>/fail-api exists. Anything but the
# workflows endpoint is a call shape the guard must not make.
install_fake_gh() {
  cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FAKE_GH_DIR:?}
printf '%s\n' "$*" >> "$dir/calls.log"
[ "${1:-}" = api ] || { echo "fixture gh: unexpected invocation: $*" >&2; exit 2; }
case "${2:-}" in
  repos/*/actions/workflows*) ;;
  *) echo "fixture gh: unexpected endpoint: ${2:-}" >&2; exit 2 ;;
esac
[ ! -f "$dir/fail-api" ] || { echo 'gh: HTTP 403 Resource not accessible by integration' >&2; exit 1; }
if [ -f "$dir/raw-workflows" ]; then cat "$dir/raw-workflows"; exit 0; fi
cat "$dir/workflows.json"
SH
  chmod +x "$TMP_ROOT/bin/gh"
}

wf() { # <name> <path> <state>: one workflow JSON object
  jq -cn --arg n "$1" --arg p "$2" --arg s "$3" '{name: $n, path: $p, state: $s}'
}

write_fixture() { # <dir> <total-count> <workflow-json>...
  local dir=$1 total=$2
  shift 2
  mkdir -p "$dir"
  jq -n --argjson total "$total" --argjson wfs "[$(IFS=,; printf '%s' "$*")]" \
    '{total_count: $total, workflows: $wfs}' > "$dir/workflows.json"
}

run_guard() { # <fixture-dir> [guard-args...]: sets OUT and RC
  local fix=$1
  shift
  OUT=$(PATH="$TMP_ROOT/bin:$PATH" FAKE_GH_DIR="$fix" \
    GITHUB_REPOSITORY="${TEST_REPO-octo/example}" GH_TOKEN=fixture-token \
    bash "$GUARD" "$@" 2>&1)
  RC=$?
}

install_fake_gh

# --- side tests: the guard's own rules -------------------------------------

test_allowlisted_only_active_passes() {
  local d="$TMP_ROOT/allow"
  write_fixture "$d" 4 \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)" \
    "$(wf 'Require no-mistakes' .github/workflows/no-mistakes-required.yml active)" \
    "$(wf 'Windows Herdr automation spike' .github/workflows/windows-herdr-spike.yml active)" \
    "$(wf 'CI' .github/workflows/ci.yml disabled_manually)"
  run_guard "$d"
  assert_equals 0 "$RC" "an allowlisted-only workflow list must pass: $OUT"
  assert_contains "$OUT" "ok: every active workflow on octo/example is on the allowlist" "the pass line must say what passed"
  assert_not_contains "$OUT" "FAIL" "a passing run must not print FAIL"
  pass "guard: only allowlisted workflows active (ci.yml disabled) passes"
}

test_reenabled_ci_fails_and_names_the_fix() {
  local d="$TMP_ROOT/ci-active"
  write_fixture "$d" 4 \
    "$(wf 'CI' .github/workflows/ci.yml active)" \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)" \
    "$(wf 'Require no-mistakes' .github/workflows/no-mistakes-required.yml disabled_manually)" \
    "$(wf 'Windows Herdr automation spike' .github/workflows/windows-herdr-spike.yml active)"
  run_guard "$d"
  assert_equals 1 "$RC" "a re-enabled ci.yml must fail the run: $OUT"
  assert_contains "$OUT" "CI (.github/workflows/ci.yml) is active" "the failure must name the exact workflow"
  assert_contains "$OUT" "gh workflow disable ci.yml" "the failure must give the exact disable command"
  pass "guard: a re-enabled ci.yml fails, naming the workflow and how to disable it"
}

test_sync_installed_workflow_fails() {
  local d="$TMP_ROOT/synced"
  write_fixture "$d" 3 \
    "$(wf 'Upstream Review' .github/workflows/upstream-review.yml active)" \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)" \
    "$(wf 'CI' .github/workflows/ci.yml disabled_manually)"
  run_guard "$d"
  assert_equals 1 "$RC" "a workflow an upstream sync installed must fail: $OUT"
  assert_contains "$OUT" "Upstream Review (.github/workflows/upstream-review.yml) is active" "the failure must name the synced-in workflow"
  pass "guard: a workflow file an upstream sync installed fails the run"
}

test_disabled_non_allowlisted_is_fine() {
  local d="$TMP_ROOT/disabled"
  write_fixture "$d" 3 \
    "$(wf 'CI' .github/workflows/ci.yml disabled_manually)" \
    "$(wf 'Old upstream' .github/workflows/old.yml disabled_inactivity)" \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)"
  run_guard "$d"
  assert_equals 0 "$RC" "a non-allowlisted workflow that is not active must not fail: $OUT"
  pass "guard: non-allowlisted but inactive workflows are not a failure"
}

test_api_failure_fails_loudly() {
  local d="$TMP_ROOT/api-fail"
  write_fixture "$d" 1 "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)"
  : > "$d/fail-api"
  run_guard "$d"
  assert_equals 1 "$RC" "an unreadable API answer must fail, not pass: $OUT"
  assert_contains "$OUT" "cannot read the workflow list" "the failure must say the list is unreadable"
  assert_contains "$OUT" "refusing to pass" "the failure must say it refuses rather than passing"
  pass "guard: a failed API call fails rather than passes"
}

test_unreadable_bodies_fail() {
  local d="$TMP_ROOT/garbage"
  mkdir -p "$d"
  printf 'not json at all {\n' > "$d/raw-workflows"
  run_guard "$d"
  assert_equals 1 "$RC" "invalid JSON must fail rather than pass: $OUT"
  assert_contains "$OUT" "malformed workflow list" "the failure must name the malformed answer"
  : > "$d/raw-workflows"
  run_guard "$d"
  assert_equals 1 "$RC" "an empty answer must fail rather than pass: $OUT"
  assert_contains "$OUT" "came back empty" "the failure must name the empty answer"
  pass "guard: invalid JSON and an empty answer both fail rather than pass"
}

test_structural_gaps_fail() {
  local d="$TMP_ROOT/gap"
  # total_count promises more entries than the body carries: a short read
  # could hide an active workflow, so it must fail.
  write_fixture "$d" 5 "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)"
  run_guard "$d"
  assert_equals 1 "$RC" "a truncated workflow list must fail rather than pass: $OUT"
  assert_contains "$OUT" "incomplete workflow list" "the failure must name the shortfall"
  # an entry without a readable state cannot be judged
  mkdir -p "$d"
  printf '%s\n' '{"total_count": 1, "workflows": [{"name": "X", "path": ".github/workflows/x.yml"}]}' \
    > "$d/workflows.json"
  run_guard "$d"
  assert_equals 1 "$RC" "an entry without a state must fail rather than pass: $OUT"
  assert_contains "$OUT" "malformed workflow list" "the missing state must be reported as unreadable"
  # an active entry without a path cannot be judged against the allowlist
  printf '%s\n' '{"total_count": 1, "workflows": [{"name": "X", "state": "active"}]}' \
    > "$d/workflows.json"
  run_guard "$d"
  assert_equals 1 "$RC" "an active entry without a path must fail rather than pass: $OUT"
  assert_contains "$OUT" "malformed workflow list" "the missing path must be reported as unreadable"
  pass "guard: truncated, stateless, and pathless entries all fail rather than pass"
}

test_usage_errors_exit_2() {
  local d="$TMP_ROOT/usage" out rc
  write_fixture "$d" 1 "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)"
  out=$(PATH="$TMP_ROOT/bin:$PATH" FAKE_GH_DIR="$d" GITHUB_REPOSITORY='' \
    bash "$GUARD" 2>&1); rc=$?
  assert_equals 2 "$rc" "no repository must be a usage error: $out"
  assert_contains "$out" "no repository" "the usage error must name what is missing"
  out=$(PATH="$TMP_ROOT/bin:$PATH" bash "$GUARD" --bogus 2>&1); rc=$?
  assert_equals 2 "$rc" "an unknown argument must be a usage error: $out"
  run_guard "$d" --repo other/repo
  assert_contains "$OUT" "on the allowlist" "--repo must select the repository: $OUT"
  assert_contains "$(cat "$d/calls.log")" "repos/other/repo/actions/workflows" "--repo must reach the API for that repo"
  pass "guard: missing repository and unknown argument are usage errors; --repo selects the repo"
}

# --- the fork-ci.yml seam ---------------------------------------------------

test_fork_ci_wires_the_guard() {
  local ruby_src="$TMP_ROOT/check_workflow.rb" run_cmd
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .github/workflows/fork-ci.yml as YAML"
  cat > "$ruby_src" <<'RB'
require "yaml"
w = YAML.load_file(ARGV[0])
step = (w.dig("jobs", "fork", "steps") || []).find { |s| (s["run"] || "").include?("fm-fork-workflow-guard") }
raise "fork-ci.yml has no step running fork/bin/fm-fork-workflow-guard" unless step
raise "the guard step must pass github.token as GH_TOKEN" unless step.dig("env", "GH_TOKEN") == "${{ github.token }}"
raise "fork-ci.yml must grant permissions: actions: read" unless (w["permissions"] || {})["actions"] == "read"
print step["run"]
RB
  run_cmd=$(ruby "$ruby_src" "$WORKFLOW") || fail "$run_cmd"
  assert_equals "fork/bin/fm-fork-workflow-guard" "$run_cmd" "the step must run the guard script directly"
  pass "wiring: fork-ci.yml grants actions: read and runs the guard with github.token"
}

test_step_command_fails_the_run_end_to_end() {
  local d="$TMP_ROOT/e2e" run_cmd
  # The exact run command declared in fork-ci.yml, executed the way the
  # runner executes it: from the repository root, against a fixture gh.
  run_cmd=$(ruby -ryaml -e 'puts (YAML.load_file(ARGV[0]).dig("jobs", "fork", "steps").find { |s| (s["run"] || "").include?("fm-fork-workflow-guard") })["run"]' "$WORKFLOW") \
    || fail "could not read the guard step from fork-ci.yml"
  write_fixture "$d" 2 \
    "$(wf 'CI' .github/workflows/ci.yml active)" \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)"
  OUT=$( (cd "$ROOT" && PATH="$TMP_ROOT/bin:$PATH" FAKE_GH_DIR="$d" \
    GITHUB_REPOSITORY=octo/example GH_TOKEN=fixture-token bash -c "$run_cmd") 2>&1); RC=$?
  assert_equals 1 "$RC" "the declared step command must fail on a re-enabled ci.yml: $OUT"
  assert_contains "$OUT" "CI (.github/workflows/ci.yml) is active" "the step command must name the workflow"
  write_fixture "$d" 2 \
    "$(wf 'Fork CI' .github/workflows/fork-ci.yml active)" \
    "$(wf 'CI' .github/workflows/ci.yml disabled_manually)"
  OUT=$( (cd "$ROOT" && PATH="$TMP_ROOT/bin:$PATH" FAKE_GH_DIR="$d" \
    GITHUB_REPOSITORY=octo/example GH_TOKEN=fixture-token bash -c "$run_cmd") 2>&1); RC=$?
  assert_equals 0 "$RC" "the declared step command must pass once ci.yml is disabled again: $OUT"
  pass "seam: the run command fork-ci.yml declares drives the real guard fail-then-pass"
}

# --- the sync reminder ------------------------------------------------------

# make_sync_repo: a throwaway repo with main (an upstream commit) and
# fork/stage1-enforcement carrying this task's fm-fork-sync. Echoes its path.
make_sync_repo() {
  local r="$TMP_ROOT/sync-repo"
  mkdir -p "$r/bin" "$r/fork/bin"
  git -C "$r" init -q -b main
  git -C "$r" config user.email fork-test@invalid
  git -C "$r" config user.name fork-test
  printf 'spawn line 1\nspawn line 2\n' > "$r/bin/fm-spawn.sh"
  git -C "$r" add bin
  git -C "$r" commit -q -m base
  git -C "$r" commit -q --allow-empty -m "upstream change"
  git -C "$r" checkout -q -b fork/stage1-enforcement
  cp "$SYNC" "$r/fork/bin/"
  printf 'fork file\n' > "$r/fork/owned"
  git -C "$r" add fork
  git -C "$r" commit -q -m fork
  printf '%s\n' "$r"
}

test_prepare_prints_the_reminder() {
  local r sha out rc
  r=$(make_sync_repo)
  sha=$(git -C "$r" rev-parse main)
  out=$("$r/fork/bin/fm-fork-sync" prepare "$sha" --worktree "$TMP_ROOT/sync-wt" 2>&1); rc=$?
  assert_equals 0 "$rc" "the fixture sync must prepare cleanly: $out"
  assert_contains "$out" "$REMINDER" "prepare must print the ci.yml reminder"
  assert_contains "$out" 'fork/README "Upstream sync procedure"' "the reminder must point at the procedure"
  pass "reminder: fm-fork-sync prepare prints the ci.yml re-enable/disable reminder"
}

test_check_prints_the_reminder() {
  local out rc
  # check's happy path runs the whole fork suite in-root, which would recurse
  # into this very test, so the reminder is pinned on a refusal path: it
  # prints before check touches the root. The root exists but is not a git
  # repository, so check refuses after the reminder.
  mkdir -p "$TMP_ROOT/not-a-repo"
  out=$("$SYNC" check 0123456789abcdef0123456789abcdef01234567 --root "$TMP_ROOT/not-a-repo" 2>&1); rc=$?
  assert_equals 1 "$rc" "check against a non-repository must refuse: $out"
  assert_contains "$out" "$REMINDER" "check must print the ci.yml reminder before its work"
  pass "reminder: fm-fork-sync check prints the ci.yml reminder before any work"
}

fork_run_tests
