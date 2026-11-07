#!/usr/bin/env bash
# Fork CI trigger volume: .github/workflows/fork-ci.yml's on: block declares
# pull_request and nothing else - one suite per pull request, zero for branch
# pushes and for the merges those pushes land - while the trim keeps the
# fork/bin/fm-fork-workflow-guard step and permissions: actions: read. Each
# fixture proves a re-added push trigger or a quietly dropped piece fails the
# check rather than passing silently. The real tree is never edited.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-ci-trigger-volume)
WORKFLOW="$ROOT/.github/workflows/fork-ci.yml"
CHECK="$TMP_ROOT/check_triggers.rb"

command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/fork-ci.yml as YAML"

# The one check every test drives: no push trigger at all, pull_request still
# declared, the workflow-guard step present, and actions: read granted.
# YAML 1.1 reads the bare `on:` key as boolean true, hence w["on"] || w[true].
cat > "$CHECK" <<'RB'
require "yaml"
w = YAML.load_file(ARGV[0])
on = w["on"] || w[true]
raise "push trigger present: fork-ci.yml must run on pull requests only" if on.is_a?(Hash) && on.key?("push")
raise "fork-ci.yml must still declare a pull_request trigger" unless on.is_a?(Hash) && on.key?("pull_request")
raise "fork-ci.yml must grant permissions: actions: read" unless (w["permissions"] || {})["actions"] == "read"
steps = w.dig("jobs", "fork", "steps") || []
raise "fork-ci.yml has no step running fork/bin/fm-fork-workflow-guard" unless steps.any? { |s| (s["run"] || "").include?("fm-fork-workflow-guard") }
puts "ok: pull_request only; guard step and actions: read intact"
RB

check() { # <workflow-path>: sets OUT and RC
  OUT=$(ruby "$CHECK" "$1" 2>&1)
  RC=$?
}

# mutate <outfile> <ruby-body>: load the real workflow, run <ruby-body>
# against w, dump the result to <outfile>. Bodies use single-quoted ruby
# strings only, since the shell hands the body in through double quotes.
mutate() {
  ruby -ryaml -e "
    w = YAML.load_file(ARGV[0])
    on = w['on'] || w[true]
    $2
    File.write(ARGV[1], YAML.dump(w))
  " "$WORKFLOW" "$1" || fail "fixture build failed: $1"
}

test_workflow_is_pull_request_only() {
  check "$WORKFLOW"
  assert_equals 0 "$RC" "the workflow must be pull_request-only with the guard step and actions: read intact: $OUT"
  assert_contains "$OUT" "pull_request only" "the check must report what it verified"
  assert_not_contains "$OUT" "FAIL" "a passing run must not print FAIL"
  pass "trigger: fork-ci.yml declares pull_request only; guard step and actions: read intact"
}

test_a_readded_push_trigger_fails() {
  mutate "$TMP_ROOT/readded-push.yml" "on['push'] = { 'branches' => ['main', 'fork/**'] }"
  check "$TMP_ROOT/readded-push.yml"
  assert_equals 1 "$RC" "a re-added push trigger must fail the check: $OUT"
  assert_contains "$OUT" "push trigger present" "the failure must name the push trigger"
  pass "trigger: a re-added push trigger fails rather than costing another suite per merge"
}

test_a_dropped_pull_request_trigger_fails() {
  mutate "$TMP_ROOT/no-pull-request.yml" "on.delete('pull_request')"
  check "$TMP_ROOT/no-pull-request.yml"
  assert_equals 1 "$RC" "dropping the pull_request trigger must fail the check: $OUT"
  assert_contains "$OUT" "pull_request trigger" "the failure must name the missing trigger"
  pass "trigger: dropping the pull_request trigger fails the check"
}

test_a_dropped_workflow_guard_step_fails() {
  mutate "$TMP_ROOT/no-guard-step.yml" "w['jobs']['fork']['steps'].reject! { |s| (s['run'] || '').include?('fm-fork-workflow-guard') }"
  check "$TMP_ROOT/no-guard-step.yml"
  assert_equals 1 "$RC" "dropping the workflow-guard step must fail the check: $OUT"
  assert_contains "$OUT" "fm-fork-workflow-guard" "the failure must name the dropped step"
  pass "trigger: a dropped workflow-guard step fails the check"
}

test_a_dropped_actions_read_permission_fails() {
  mutate "$TMP_ROOT/no-actions-read.yml" "w['permissions'].delete('actions')"
  check "$TMP_ROOT/no-actions-read.yml"
  assert_equals 1 "$RC" "dropping permissions actions: read must fail the check: $OUT"
  assert_contains "$OUT" "actions: read" "the failure must name the missing permission"
  pass "trigger: a dropped permissions actions: read fails the check"
}

fork_run_tests
