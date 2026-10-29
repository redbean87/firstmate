#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-github-checks-lib.sh, the shared authoritative
# GitHub required-check verdict that bin/fm-pr-merge.sh and the PR-readiness
# path both source.
#
# The library is exercised through its own interface: each case writes the JSON
# GitHub would answer with, puts a fake gh on PATH, sources the library,
# and calls fm_pr_github_check_verdict. What is pinned here is the verdict
# itself - a required check that never reported, a pending or red check, an
# unreadable requirement source, a malformed payload, and a head that is not the
# one the payload was read at are all not green - plus the merge gate semantics
# the shared code must keep (reported SKIPPED and NEUTRAL are green, an older
# cancelled run is superseded only by a later passing run, status contexts are
# never superseded, app-bound requirements need their own producer).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-pr-github-checks-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-github-checks-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the library's own jq programs over GitHub-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OTHER_HEAD=2710bc5efc936efb70e95b86ca3582e9da7e60f4
BASE=main
# Exported into the sourced library, which reads both.
# shellcheck disable=SC2034
PR_OWNER=fixture
# shellcheck disable=SC2034
PR_REPO=fixture-repo

# The fake gh answers the three reads the verdict makes from the case directory
# named by FM_TEST_GH_DIR, so a case controls each answer and can fail any one
# of them through a marker file. Anything else is a test bug, not silence.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_TEST_GH_DIR:?}
printf '%s\n' "$*" >> "$dir/gh.log"
case "$*" in
  api\ *"/commits/"*"/check-runs"*)
    [ ! -e "$dir/runs-fail" ] || { echo 'error: check runs unreadable' >&2; exit 1; }
    cat "$dir/runs.json"
    ;;
  api\ *"/rules/branches/"*)
    if [ -e "$dir/rules-fail-body" ]; then
      cat "$dir/rules-fail-body" >&2
      exit 1
    fi
    [ ! -e "$dir/rules-fail" ] || { echo 'error: branch rules unreadable' >&2; exit 1; }
    cat "$dir/rules.json"
    ;;
  api\ *"/branches/"*)
    [ ! -e "$dir/branch-fail" ] || { echo 'error: branch unreadable' >&2; exit 1; }
    cat "$dir/branch.json"
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# One CheckRun rollup entry the way GitHub reports it. A conclusion or timestamp
# of "-" is emitted as JSON null. Args: name status conclusion [startedAt]
check_run() {
  local name=$1 status=$2 conclusion=$3 started=${4:--}
  local conclusion_json='null' started_json='null'
  [ "$conclusion" = - ] || conclusion_json="\"$conclusion\""
  [ "$started" = - ] || started_json="\"$started\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s}' \
    "$name" "$status" "$conclusion_json" "$started_json"
}

status_context() {
  local name=$1 state=$2
  printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$name" "$state"
}

# A fresh case directory with an unprotected base branch, no ruleset rule, and no
# check runs, so a case states only the requirement and rollup it is about.
new_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  write_required "$dir"
  printf '[]\n' > "$dir/runs.json"
  printf '%s\n' "$dir"
}

# The base branch's required checks as GitHub reports them, in the classic
# branch-protection summary and in the active ruleset rules. Args: dir
# [classic:<name>] [ruleset:<name>] [bound:<name>:<app_id>]...
write_required() {
  local dir=$1 spec name app contexts='' checks='' rules='' protected=false
  shift
  for spec in "$@"; do
    case "$spec" in
      classic:*)
        protected=true
        name=${spec#classic:}
        contexts="${contexts:+$contexts,}\"$name\""
        checks="${checks:+$checks,}{\"context\":\"$name\",\"app_id\":null}"
        ;;
      ruleset:*)
        name=${spec#ruleset:}
        rules="${rules:+$rules,}{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"$name\"}]}}"
        ;;
      bound:*)
        name=${spec#bound:}
        app=${name##*:}
        name=${name%:*}
        rules="${rules:+$rules,}{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"$name\",\"integration_id\":$app}]}}"
        ;;
      *) fail "write_required: unknown spec '$spec'" ;;
    esac
  done
  printf '{"name":"main","protected":%s,"protection":{"enabled":%s,"required_status_checks":{"enforcement_level":"%s","contexts":[%s],"checks":[%s]}}}\n' \
    "$protected" "$protected" "$([ "$protected" = true ] && echo non_admins || echo off)" "$contexts" "$checks" \
    > "$dir/branch.json"
  printf '[{"type":"deletion"}%s]\n' "${rules:+,$rules}" > "$dir/rules.json"
}

# The live pull-request payload the verdict is computed from. Args: dir head
# <rollup-entry-json>...
write_view() {
  local dir=$1 head=$2 entry rollup=''
  shift 2
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[%s]}\n' \
    "$head" "$rollup" > "$dir/view.json"
}

# The check-runs read the producer binding is matched against. Args: dir head
# <name> <app-id>...
write_runs() {
  local dir=$1 head=$2 name app first=true
  shift 2
  {
    printf '{"total_count":%s,"check_runs":[' "$(($# / 2))"
    while [ "$#" -ge 2 ]; do
      name=$1
      app=$2
      shift 2
      [ "$first" = true ] || printf ','
      first=false
      printf '{"name":"%s","app":{"id":%s},"head_sha":"%s"}' "$name" "$app" "$head"
    done
    printf ']}\n'
  } > "$dir/runs.json"
}

# Run the verdict exactly as a caller does: source the library with the fake gh
# on PATH and the fixture answers exported, then record every output the verdict
# promises. Args: dir head [verdict args...]
run_verdict() {
  local dir=$1 head=$2
  shift 2
  (
    PATH="$FAKEBIN:$PATH"
    export PATH
    FM_TEST_GH_DIR=$dir
    export FM_TEST_GH_DIR
    # shellcheck source=/dev/null
    . "$LIB"
    rc=0
    fm_pr_github_check_verdict "$(cat "$dir/view.json")" "$BASE" "$head" "$@" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'status=%s\n' "$FM_PR_GITHUB_VERDICT_STATUS"
    printf 'incomplete=%s\n' "$FM_PR_GITHUB_VERDICT_INCOMPLETE"
    printf '%s' "$FM_PR_GITHUB_VERDICT_LINES" > "$dir/lines"
    local name
    printf '%s\n' "$FM_PR_GITHUB_VERDICT_RED" | while IFS= read -r name; do
      [ -n "$name" ] && printf 'red=%s\n' "$name"
    done
    printf '%s\n' "$FM_PR_GITHUB_VERDICT_UNREPORTED" | while IFS= read -r name; do
      [ -n "$name" ] && printf 'unreported=%s\n' "$name"
    done
    return 0
  ) > "$dir/verdict.out" 2> "$dir/verdict.err"
}

# The verdict a readiness caller gets: green, with every input read.
assert_green() {  # dir label
  local dir=$1 label=$2
  grep -qx 'rc=0' "$dir/verdict.out" \
    || fail "$label: expected a green verdict"$'\n'"$(cat "$dir/verdict.out" "$dir/verdict.err")"
  grep -qx 'status=green' "$dir/verdict.out" || fail "$label: status is not green"
  grep -qx 'incomplete=false' "$dir/verdict.out" || fail "$label: a green verdict cannot be incomplete"
  assert_no_grep 'red=' "$dir/verdict.out" "$label: a green verdict named a red check"
  assert_no_grep 'unreported=' "$dir/verdict.out" "$label: a green verdict named an unreported requirement"
  [ ! -s "$dir/lines" ] || fail "$label: a green verdict produced refusal lines: $(cat "$dir/lines")"
}

# Any refusal: the verdict is not green and not unreadable, so the inputs were
# read and something refuses.
assert_blocked() {  # dir label
  local dir=$1 label=$2
  assert_grep 'rc=1' "$dir/verdict.out" "$label: expected a refusal"$'\n'"$(cat "$dir/verdict.out")"
  assert_grep 'status=blocked' "$dir/verdict.out" "$label: expected a blocked verdict, got: $(cat "$dir/verdict.out")"
}

# The payload or its rollup could not be read at all: a failed read, never an
# empty red set and never green.
assert_unreadable() {  # dir label
  local dir=$1 label=$2
  assert_grep 'rc=1' "$dir/verdict.out" "$label: expected the read to fail"$'\n'"$(cat "$dir/verdict.out")"
  assert_grep 'status=unreadable' "$dir/verdict.out" "$label: expected an unreadable verdict, got: $(cat "$dir/verdict.out")"
}

# --- the predicate ----------------------------------------------------------

test_reportedly_green_checks_with_no_requirements_are_green() {
  local dir
  dir=$(new_case green-no-requirements)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "green-no-requirements"
  pass "a fully reported green rollup with no required contexts is green"
}

test_required_checks_reported_green_are_green() {
  local dir
  dir=$(new_case green-required)
  write_required "$dir" classic:ci ruleset:unit
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)" "$(check_run unit COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "green-required"
  pass "classic and ruleset requirements that reported green are green"
}

test_required_check_that_never_reported_is_not_green() {
  local dir
  dir=$(new_case unreported-required)
  write_required "$dir" classic:deploy
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "unreported-required"
  assert_grep 'unreported=deploy' "$dir/verdict.out" \
    "unreported-required: the absent requirement was not reported"
  assert_grep "required check 'deploy' has not reported at head $HEAD" "$dir/lines" \
    "unreported-required: the refusal did not name the absent requirement at the head"
  assert_no_grep 'incomplete=true' "$dir/verdict.out" \
    "unreported-required: an absent requirement is a refusal, not an unreadable read"
  pass "a required check that never reported stays not green while every read succeeded"
}

# The merge gate accepts a reported SKIPPED or NEUTRAL conclusion. A readiness
# predicate that called those red would refuse work the gate would merge.
test_reported_skipped_and_neutral_are_green() {
  local dir
  dir=$(new_case skipped-neutral)
  write_required "$dir" classic:docs ruleset:audit
  write_view "$dir" "$HEAD" "$(check_run docs COMPLETED SKIPPED)" "$(check_run audit COMPLETED NEUTRAL)"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "skipped-neutral"
  pass "reported SKIPPED and NEUTRAL results count as green exactly as the merge gate takes them"
}

test_pending_and_failed_checks_are_never_green() {
  local dir
  dir=$(new_case pending-failed)
  write_view "$dir" "$HEAD" \
    "$(check_run ci IN_PROGRESS -)" \
    "$(check_run lint COMPLETED FAILURE)" \
    "$(status_context legacy PENDING)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "pending-failed"
  assert_grep 'red=ci' "$dir/verdict.out" "pending-failed: a pending check was not named"
  assert_grep 'red=lint' "$dir/verdict.out" "pending-failed: a failed check was not named"
  assert_grep 'red=legacy' "$dir/verdict.out" "pending-failed: a pending status context was not named"
  assert_grep "check 'ci' is not green" "$dir/lines" "pending-failed: the pending check was not refused"
  pass "a pending or failed check, status context included, is never green"
}

# GitHub leaves a cancelled run beside the passing re-run that replaced it.
test_superseded_cancellation_is_green() {
  local dir
  dir=$(new_case superseded)
  write_view "$dir" "$HEAD" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T10:00:00Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T10:05:00Z)"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "superseded"
  pass "an older cancelled run superseded by a later passing run leaves the check green"
}

test_unfinished_rerun_keeps_the_check_red() {
  local dir
  dir=$(new_case unfinished-rerun)
  write_view "$dir" "$HEAD" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T10:00:00Z)" \
    "$(check_run ci IN_PROGRESS - 2026-01-01T10:05:00Z)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "unfinished-rerun"
  assert_grep 'red=ci' "$dir/verdict.out" "unfinished-rerun: a rerun that has not finished must keep the check red"
  pass "a re-run that has not finished neither supersedes nor is superseded"
}

test_status_contexts_are_never_superseded() {
  local dir
  dir=$(new_case status-context)
  write_view "$dir" "$HEAD" \
    "$(status_context ci FAILURE)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T10:05:00Z)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "status-context"
  assert_grep 'red=ci' "$dir/verdict.out" \
    "status-context: a check run must never supersede a non-green status context"
  pass "a non-green status context is reported independently and never superseded"
}

# --- incomplete or unreadable input is never green --------------------------

# The dangerous shape: the rollup is green but the requirement source failed, so
# "nothing is red" must not be read as "nothing is required".
test_unreadable_required_source_is_not_green() {
  local dir
  dir=$(new_case required-unreadable)
  write_required "$dir" classic:deploy
  : > "$dir/branch-fail"
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "required-unreadable"
  assert_grep 'incomplete=true' "$dir/verdict.out" \
    "required-unreadable: the verdict did not report incomplete input"
  assert_grep "the branch protection summary for base branch $BASE could not be read, so a required check that has not reported cannot be ruled out" \
    "$dir/lines" "required-unreadable: the unreadable source was not refused"
  pass "a green rollup with an unreadable requirement source is never green"
}

test_unreadable_rules_and_producer_reads_are_not_green() {
  local dir
  dir=$(new_case rules-unreadable)
  : > "$dir/rules-fail"
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "rules-unreadable"
  assert_grep 'incomplete=true' "$dir/verdict.out" "rules-unreadable: incomplete input was not reported"
  assert_grep "the branch rules for base branch $BASE could not be read" "$dir/lines" \
    "rules-unreadable: the unreadable rules were not refused"

  dir=$(new_case producers-unreadable)
  write_required "$dir" bound:ci:5
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  : > "$dir/runs-fail"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "producers-unreadable"
  assert_grep 'incomplete=true' "$dir/verdict.out" "producers-unreadable: incomplete input was not reported"
  assert_grep "required check producers at head $HEAD could not be read" "$dir/lines" \
    "producers-unreadable: the unreadable producer read was not refused"
  pass "a failed ruleset read and a failed producer read are refusals, never green"
}

test_malformed_payloads_are_never_green() {
  local dir
  dir=$(new_case malformed-branch)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  printf '{"name":"main","protected":true,"protection":{}}\n' > "$dir/branch.json"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "malformed-branch"
  assert_grep 'incomplete=true' "$dir/verdict.out" "malformed-branch: incomplete input was not reported"

  dir=$(new_case malformed-rules)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  printf '{not json\n' > "$dir/rules.json"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "malformed-rules"
  assert_grep 'incomplete=true' "$dir/verdict.out" "malformed-rules: incomplete input was not reported"
  pass "a branch-protection summary without its required-status object and an unparseable rules payload are both refusals"
}

test_unreadable_rollup_is_read_as_unreadable() {
  local dir
  dir=$(new_case rollup-missing)
  printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "$HEAD" > "$dir/view.json"
  run_verdict "$dir" "$HEAD"
  assert_unreadable "$dir" "rollup-missing"

  dir=$(new_case rollup-malformed)
  printf '{"state":"OPEN","headRefOid":"%s"' "$HEAD" > "$dir/view.json"
  run_verdict "$dir" "$HEAD"
  assert_unreadable "$dir" "rollup-malformed"
  pass "a missing or malformed check rollup is an unreadable payload, not an empty red set"
}

test_head_mismatch_is_never_green() {
  local dir
  dir=$(new_case head-mismatch)
  write_view "$dir" "$OTHER_HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_unreadable "$dir" "head-mismatch"
  pass "a payload read at another head cannot produce a verdict for this one"
}

# --- requirement sources and producer binding -------------------------------

# An empty required set proven by successful reads is different from an
# unreadable one: the first is green, the second refuses.
test_empty_requirement_set_differs_from_unreadable() {
  local dir
  dir=$(new_case requirements-empty-proven)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "requirements-empty-proven"

  dir=$(new_case requirements-empty-unproven)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  : > "$dir/branch-fail"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "requirements-empty-unproven"
  pass "an empty required set proven by two successful reads is green, while an unproven one refuses"
}

test_plan_gated_403_still_proves_no_ruleset_requirement() {
  local dir
  dir=$(new_case plan-gated)
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  printf '%s\n' 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' \
    > "$dir/rules-fail-body"
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "plan-gated"
  pass "a plan-gated rules read still proves the repository has no ruleset requirement"
}

test_bound_requirement_needs_its_own_producer_at_head() {
  local dir
  dir=$(new_case bound-other-app)
  write_required "$dir" bound:ci:5
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  write_runs "$dir" "$HEAD" ci 7
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "bound-other-app"
  assert_grep 'unreported=ci' "$dir/verdict.out" \
    "bound-other-app: a same-named run from another app must not satisfy the requirement"

  dir=$(new_case bound-own-app)
  write_required "$dir" bound:ci:5
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  write_runs "$dir" "$HEAD" ci 5
  run_verdict "$dir" "$HEAD"
  assert_green "$dir" "bound-own-app"
  pass "an app-bound requirement is satisfied only by a run from that app at the verified head"
}

# --- waivers are the merge gate's authority, not part of readiness ----------

test_waivers_change_the_gate_verdict_but_not_readiness() {
  local dir
  dir=$(new_case waived-red)
  write_view "$dir" "$HEAD" "$(check_run lint COMPLETED FAILURE)" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "waived-red-readiness"
  assert_grep 'red=lint' "$dir/verdict.out" "waived-red-readiness: the red check was not named without a waiver"

  run_verdict "$dir" "$HEAD" --allow-red lint
  assert_green "$dir" "waived-red-gate"
  pass "a readiness call that passes no waiver refuses a red check the attended gate may waive"

  dir=$(new_case waived-missing)
  write_required "$dir" classic:deploy
  write_view "$dir" "$HEAD" "$(check_run ci COMPLETED SUCCESS)"
  run_verdict "$dir" "$HEAD"
  assert_blocked "$dir" "waived-missing-readiness"
  assert_grep 'unreported=deploy' "$dir/verdict.out" "waived-missing-readiness: the absent requirement was not named"

  run_verdict "$dir" "$HEAD" --allow-missing deploy
  assert_green "$dir" "waived-missing-gate"
  pass "a readiness call that passes no waiver refuses an unreported requirement the attended gate may waive"
}

# --- the seam itself --------------------------------------------------------

test_sourcing_the_library_is_silent_and_defines_the_verdict() {
  local out rc kind
  rc=0
  # shellcheck source=/dev/null
  out=$( ( . "$LIB" ) 2>&1 ) || rc=$?
  expect_code 0 "$rc" "sourcing the library"
  [ -z "$out" ] || fail "sourcing the library wrote output a poll would turn into a wake: $out"
  # shellcheck source=/dev/null
  kind=$( ( . "$LIB"; type -t fm_pr_github_check_verdict ) )
  [ "$kind" = function ] || fail "the library does not define fm_pr_github_check_verdict"
  rc=0
  # shellcheck source=/dev/null
  out=$( ( . "$LIB"; type -t github_checks_not_green; type -t github_read_required_contexts; type -t github_required_checks_missing ) 2>&1 ) || rc=$?
  expect_code 0 "$rc" "the predicate's own functions"
  pass "sourcing the library is silent and exposes the one verdict plus the reads it composes"
}

test_verdict_prints_nothing_a_poll_could_mistake_for_a_wake() {
  local dir
  dir=$(new_case silence)
  write_required "$dir" classic:deploy
  write_view "$dir" "$HEAD" "$(check_run ci IN_PROGRESS -)"
  run_verdict "$dir" "$HEAD"
  [ ! -s "$dir/verdict.err" ] \
    || fail "a refusing verdict wrote to stderr, which a poll's caller could surface: $(cat "$dir/verdict.err")"
  assert_blocked "$dir" "silence"
  pass "the verdict reports through its own outputs and writes nothing to stdout or stderr"
}

test_reportedly_green_checks_with_no_requirements_are_green
test_required_checks_reported_green_are_green
test_required_check_that_never_reported_is_not_green
test_reported_skipped_and_neutral_are_green
test_pending_and_failed_checks_are_never_green
test_superseded_cancellation_is_green
test_unfinished_rerun_keeps_the_check_red
test_status_contexts_are_never_superseded
test_unreadable_required_source_is_not_green
test_unreadable_rules_and_producer_reads_are_not_green
test_malformed_payloads_are_never_green
test_unreadable_rollup_is_read_as_unreadable
test_head_mismatch_is_never_green
test_empty_requirement_set_differs_from_unreadable
test_plan_gated_403_still_proves_no_ruleset_requirement
test_bound_requirement_needs_its_own_producer_at_head
test_waivers_change_the_gate_verdict_but_not_readiness
test_sourcing_the_library_is_silent_and_defines_the_verdict
test_verdict_prints_nothing_a_poll_could_mistake_for_a_wake
