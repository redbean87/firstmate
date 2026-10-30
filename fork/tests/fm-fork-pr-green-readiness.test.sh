#!/usr/bin/env bash
# Fork PR readiness evaluation: the conservative GitHub predicate at the seam.
#
# Every case here drives the REAL extension/readiness.mjs against a fixture
# GitHub CLI (fork/tests/pr-green-fake-gh) that serves recorded responses. No
# test contacts GitHub, a real forge CLI, or the running session's home, and no
# test needs an account. The merge gate's own suites stay untouched: this file
# exists so none of its expectations is ever relaxed to accommodate the fork.
#
# The fixture CLI is reached through an explicit config/pr-green-gh, the same
# operator override a real host uses, because the extension host gives the
# package a minimal PATH. That is also why these cases can pin the read cost: the
# fake records every call, so "the common not-ready case costs one read" and
# "required contexts are read only after the rollup looks fully green" are
# assertions rather than claims.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

SEAM="$ROOT/fork/pr-green/extension/readiness.mjs"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222
PR_URL=https://github.com/acme/app/pull/7

PTMP=$(fm_test_tmproot fm-fork-pr-green-readiness)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR

# driver.mjs <seam> <entry-file> <ctx-json>: one real seam call, printed as JSON.
DRIVER="$PTMP/driver.mjs"
cat > "$DRIVER" <<'JS'
import fs from "node:fs";
const seam = process.argv[2];
const entry = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const ctx = JSON.parse(process.argv[4]);
ctx.log = (line) => process.stderr.write(`${line}\n`);
const { decideWake } = await import(seam);
process.stdout.write(`${JSON.stringify(decideWake(entry, ctx))}\n`);
JS

# new_case <name> -> the case directory, holding home/, forge/, and bin/.
#
# config/pr-green-gh names a generated wrapper that pins the fixture directory in
# the CLI's own environment, so the seam needs no test-only hook: it resolves a
# real executable and the fake receives its fixtures like a real gh would.
new_case() {
  local dir=$PTMP/$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/forge" "$dir/bin"
  fork_fixture_gh "$dir/bin/gh" "$dir/forge"
  printf '%s\n' "$dir/bin/gh" > "$dir/home/config/pr-green-gh"
  printf '%s\n' "$dir"
}

# entry_json <case-dir> <id> <head>: one entry the scope gate would hand the
# seam, plus the task record it names. The seam re-reads <stateDir>/<id>.meta
# itself before it delivers a wake (mode, yolo, the same pull request and head, and
# the record's own spawn_gen= incarnation), so this predicate suite gives every
# ready case a real record instead of a path that cannot be read.
entry_json() {  # <case-dir> <id> <head>
  local meta="$1/home/state/$2.meta"
  printf '%s\n' "kind=ship" "mode=no-mistakes" "yolo=on" \
    "pr=$PR_URL" "pr_head=$3" "spawn_gen=s1793000000.4100.$RANDOM" > "$meta"
  chmod 0600 "$meta"
  jq -cn --arg id "$2" --arg head "$3" --arg url "$PR_URL" --arg meta "$meta" \
    '{id: $id, mode: "no-mistakes", yolo: "on", kind: "ship", pr: $url,
      host: "github.com", owner: "acme", repo: "app", number: "7",
      head: $head, meta: $meta}'
}

ctx_json() {  # <case-dir>
  jq -cn --arg home "$1/home" --arg state "$1/home/state" --arg config "$1/home/config" \
    '{home: $home, stateDir: $state, configDir: $config, now: 0}'
}

home_manifest() {  # <case-dir>
  find "$1/home" -type f -exec shasum -a 256 {} + | LC_ALL=C sort
}

DECISION=
# decide <case-dir> <entry-file>: run the seam once; DECISION is its JSON verdict.
# Every call also proves the predicate is a pure reader: the home tree must be
# byte-identical afterwards, so no test record, marker, or authority file appears.
decide() {
  local before after rc
  before=$(home_manifest "$1")
  DECISION=$(node "$DRIVER" "$SEAM" "$2" "$(ctx_json "$1")" 2>"$1/seam.err"); rc=$?
  after=$(home_manifest "$1")
  [ "$rc" -eq 0 ] || fail "the seam crashed instead of answering (exit $rc): $(cat "$1/seam.err")"
  [ "$before" = "$after" ] || fail "the readiness predicate wrote to the home: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

assert_ready() {  # <case-dir> <entry-file> <head> <message>
  decide "$1" "$2"
  [ "$DECISION" != null ] || fail "$4 (the seam stayed silent: $(cat "$1/seam.err"))"
  assert_contains "$DECISION" "$PR_URL" "$4 (the advisory body names the pull request)"
  assert_contains "$DECISION" "at head $3" "$4 (the advisory body names the recorded head)"
  assert_contains "$DECISION" "advisory" "$4 (the advisory body says it is advisory)"
}

assert_silent() {  # <case-dir> <entry-file> <message>
  decide "$1" "$2"
  [ "$DECISION" = null ] || fail "$3 (the seam answered ready: $DECISION)"
}

calls() {  # <case-dir>: the recorded calls of the last decision
  if [ -f "$1/forge/calls.log" ]; then wc -l < "$1/forge/calls.log" | tr -d ' '; else printf '0'; fi
}

reset_calls() { : > "$1/forge/calls.log"; }

# green_pr <case-dir> <head>: the shared fully-green answer set for this case.
green_pr() {
  fork_pr_green_forge "$1/forge" "$2"
}

rollup() {  # <case-dir> <rollup-json>
  jq -cn --arg head "$HEAD_A" --argjson rollup "$2" \
    '{state: "OPEN", isDraft: false, mergeable: "MERGEABLE", headRefOid: $head, baseRefName: "main", statusCheckRollup: $rollup}' \
    > "$1/forge/pr-view.json"
}

test_a_green_pull_request_at_the_recorded_head_is_ready() {
  local dir entry
  dir=$(new_case ready)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" green-task "$HEAD_A" > "$entry"
  reset_calls "$dir"
  assert_ready "$dir" "$entry" "$HEAD_A" "a green pull request at the recorded head is ready"
  assert_contains "$DECISION" "Every reported check is green at that head." \
    "the advisory body says the reported checks are green at the head it names"
  assert_contains "$DECISION" "The single required check has reported at that head." \
    "the advisory body names the one required check it counted, in a sentence that reads"
  [ "$(calls "$dir")" = 3 ] || fail "a ready pull request costs the pull read, the branch read, and the rules read: $(cat "$dir/forge/calls.log")"
  assert_contains "$(cat "$dir/forge/calls.log")" "pr view $PR_URL --json state,isDraft,mergeable,headRefOid,baseRefName,statusCheckRollup" \
    "the pull read keeps the live state, draft flag, mergeability, head, base, and rollup fields"
  assert_contains "$(cat "$dir/forge/calls.log")" "api repos/acme/app/branches/main" "classic branch protection is read at the pull request's own base"
  assert_contains "$(cat "$dir/forge/calls.log")" "api --paginate --slurp repos/acme/app/rules/branches/main" "active rulesets are read at that base"
  assert_not_contains "$(cat "$dir/forge/calls.log")" "check-runs" "an unbound required check needs no producer read"
  [ -z "$(find "$dir/home/state" -type f -name '*.pr-green-ready')" ] \
    || fail "a consult with no host request id cannot prove delivery, so it publishes no latch marker"
  pass "ready: an open, non-draft pull request at the recorded head with every check green and every required check reported is advisory-ready"
}

test_the_common_not_ready_case_costs_only_the_initial_read() {
  local dir entry name body
  dir=$(new_case cost)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" cost-task "$HEAD_A" > "$entry"
  for name in pending queued failed cancelled status-red; do
    case "$name" in
      pending)
        body='[{"__typename":"CheckRun","name":"ci","status":"IN_PROGRESS","conclusion":""}]' ;;
      queued)
        body='[{"__typename":"CheckRun","name":"ci","status":"QUEUED","conclusion":""}]' ;;
      failed)
        body='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"}]' ;;
      cancelled)
        body='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"}]' ;;
      status-red)
        body='[{"__typename":"StatusContext","context":"legacy","state":"FAILURE"}]' ;;
    esac
    rollup "$dir" "$body"
    reset_calls "$dir"
    assert_silent "$dir" "$entry" "a $name rollup is never ready"
    [ "$(calls "$dir")" = 1 ] \
      || fail "a not-ready rollup must cost only the initial pull read ($name: $(cat "$dir/forge/calls.log"))"
  done
  pass "cost: every not-ready rollup is silent after exactly one forge read, and no required-context read happens"
}

test_check_run_supersession_matches_the_merge_gate() {
  local dir entry
  dir=$(new_case supersession)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" supersede-task "$HEAD_A" > "$entry"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T00:00:00Z"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_ready "$dir" "$entry" "$HEAD_A" "a cancelled run that a later same-named run superseded does not block readiness"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:01:00Z"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_silent "$dir" "$entry" "a tied run is not superseded"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:02:00Z"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_silent "$dir" "$entry" "a run started after the green one is not superseded"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"FAILURE"},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_silent "$dir" "$entry" "an undated run can never be superseded"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"deploy","status":"IN_PROGRESS","conclusion":""},
    {"__typename":"CheckRun","name":"deploy","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_silent "$dir" "$entry" "a still-running run can never be superseded"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
  assert_ready "$dir" "$entry" "$HEAD_A" "a name whose runs are all green needs no timestamp"

  pass "supersession: only a completed, whole-second-dated run strictly older than a green run of the same name is superseded"
}

test_status_contexts_and_unnamed_runs_are_judged_separately() {
  local dir entry
  dir=$(new_case identity)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" identity-task "$HEAD_A" > "$entry"

  rollup "$dir" '[{"__typename":"StatusContext","context":"legacy","state":"SUCCESS"},
    {"__typename":"StatusContext","context":"legacy","state":"FAILURE"}]'
  assert_silent "$dir" "$entry" "status contexts are never grouped or superseded, so one red context stays red"

  rollup "$dir" '[{"__typename":"StatusContext","context":"legacy","state":"PENDING"}]'
  assert_silent "$dir" "$entry" "a pending status context is not green"

  rollup "$dir" '[{"__typename":"StatusContext","context":"legacy"}]'
  assert_silent "$dir" "$entry" "a status context with no state is not green"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T00:00:00Z"},
    {"__typename":"CheckRun","name":"","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:01:00Z"}]'
  assert_silent "$dir" "$entry" "unnamed runs are grouped alone, so one cannot supersede another"

  pass "identity: status contexts are judged one by one and unnamed check runs are never treated as one check"
}

test_reported_skipped_and_neutral_are_green_and_unreported_required_is_not() {
  local dir entry
  dir=$(new_case skipped)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" skipped-task "$HEAD_A" > "$entry"

  rollup "$dir" '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SKIPPED","startedAt":"2026-01-01T00:00:00Z"},
    {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"NEUTRAL","startedAt":"2026-01-01T00:00:00Z"}]'
  assert_ready "$dir" "$entry" "$HEAD_A" "a reported SKIPPED or NEUTRAL conclusion is green, exactly as the merge gate reads it"

  # A green rollup that does not carry the required context: the requirement has
  # not reported, so nothing about it is green.
  rollup "$dir" '[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T00:00:00Z"}]'
  reset_calls "$dir"
  assert_silent "$dir" "$entry" "a required context that has not reported is never green"
  [ "$(calls "$dir")" = 3 ] || fail "the unreported-required case is decided by the required reads, not by the rollup: $(cat "$dir/forge/calls.log")"

  pass "required: a reported SKIPPED/NEUTRAL is green while a required context missing from the rollup is silence"
}

test_a_closed_draft_or_unrecorded_head_is_never_ready() {
  local dir entry
  dir=$(new_case lifecycle)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" lifecycle-task "$HEAD_A" > "$entry"

  jq -cn --arg head "$HEAD_A" '{state: "CLOSED", isDraft: false, headRefOid: $head, baseRefName: "main",
    statusCheckRollup: [{__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "SUCCESS"}]}' > "$dir/forge/pr-view.json"
  reset_calls "$dir"
  assert_silent "$dir" "$entry" "a closed pull request is never ready"
  [ "$(calls "$dir")" = 1 ] || fail "a closed pull request is refused on the first read"

  green_pr "$dir" "$HEAD_A"
  jq '.isDraft = true' "$dir/forge/pr-view.json" > "$dir/draft.json" && mv "$dir/draft.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "a draft pull request is never ready"

  green_pr "$dir" "$HEAD_A"
  jq 'del(.isDraft)' "$dir/forge/pr-view.json" > "$dir/nodraft.json" && mv "$dir/nodraft.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "an unreadable draft flag is never treated as non-draft"

  green_pr "$dir" "$HEAD_B"
  assert_silent "$dir" "$entry" "a live head that disagrees with the recorded head is silence"

  green_pr "$dir" "$HEAD_A"
  jq '.headRefOid = "abc123"' "$dir/forge/pr-view.json" > "$dir/badhead.json" && mv "$dir/badhead.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "a live head that is not a commit id is silence"

  green_pr "$dir" "$HEAD_A"
  jq 'del(.headRefOid)' "$dir/forge/pr-view.json" > "$dir/nohead.json" && mv "$dir/nohead.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "an unreadable live head is silence"

  green_pr "$dir" "$HEAD_A"
  jq 'del(.baseRefName)' "$dir/forge/pr-view.json" > "$dir/nobase.json" && mv "$dir/nobase.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "an unreadable base branch is silence, because the required set cannot be read"

  pass "lifecycle: a closed, draft, head-mismatched, or unreadable pull request is never ready, and never costs a required read"
}

test_a_green_rollup_with_an_unreadable_required_source_stays_silent() {
  local dir entry
  dir=$(new_case required-source)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" source-task "$HEAD_A" > "$entry"

  : > "$dir/forge/fail-branch"
  assert_silent "$dir" "$entry" "a failed branch-protection read beside a green rollup is silence"
  rm -f "$dir/forge/fail-branch"

  printf 'the branch is unavailable\n' > "$dir/forge/raw-branch"
  assert_silent "$dir" "$entry" "a branch-protection answer that is not JSON is silence"
  printf '%s\n' '{"protected": "yes"}' > "$dir/forge/raw-branch"
  assert_silent "$dir" "$entry" "a branch-protection answer with an unreadable protected flag is silence"
  printf '%s\n' '{"protected": true}' > "$dir/forge/raw-branch"
  assert_silent "$dir" "$entry" "a protected branch with no protection summary is silence"
  printf '%s\n' '{"protected": true, "protection": {"required_status_checks": null}}' > "$dir/forge/raw-branch"
  assert_silent "$dir" "$entry" "a protected branch whose required summary is unreadable is silence"
  printf '%s\n' '{"protected": true, "protection": {"required_status_checks": {"checks": [{"context": ""}]}}}' > "$dir/forge/raw-branch"
  assert_silent "$dir" "$entry" "a required entry with no usable context is silence"
  rm -f "$dir/forge/raw-branch"

  : > "$dir/forge/fail-rules"
  assert_silent "$dir" "$entry" "a failed ruleset read beside a green rollup is silence"
  rm -f "$dir/forge/fail-rules"

  printf '%s\n' '{}' > "$dir/forge/raw-rules"
  assert_silent "$dir" "$entry" "a ruleset answer that is not an array of pages is silence"
  printf '%s\n' '[[{"type": "required_status_checks", "parameters": {}}]]' > "$dir/forge/raw-rules"
  assert_silent "$dir" "$entry" "a required-status-checks rule with no readable parameters is silence"
  printf '%s\n' '[[{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "ci", "integration_id": "x"}]}}]]' \
    > "$dir/forge/raw-rules"
  assert_silent "$dir" "$entry" "a required entry with an unusable producer binding is silence"
  rm -f "$dir/forge/raw-rules"

  rm -f "$dir/forge/rules.json"
  assert_silent "$dir" "$entry" "a required-context source with no answer at all is silence"

  printf '%s\n' '[[{"type": "deletion"}]]' > "$dir/forge/rules.json"
  assert_ready "$dir" "$entry" "$HEAD_A" "an active ruleset that requires no check still leaves a fully reported green pull request ready"
  assert_contains "$DECISION" "Every reported check is green at that head." \
    "the zero-required advisory body says the reported checks are green at the head it names"
  assert_contains "$DECISION" "No branch rule requires a check at this base branch." \
    "the zero-required advisory body states plainly that no branch rule requires a check"

  pass "required sources: a green rollup beside any unreadable, incomplete, or ambiguous required-context source is silence, never green"
}

test_a_bound_requirement_needs_its_producer_app() {
  local dir entry
  dir=$(new_case producers)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" producer-task "$HEAD_A" > "$entry"
  printf '%s\n' '{"protected": true, "protection": {"required_status_checks": {"checks": [{"context": "ci", "app_id": 15368}], "contexts": []}}}' \
    > "$dir/forge/branch.json"

  jq -cn --arg head "$HEAD_A" '[{"total_count": 1, "check_runs": [{"name": "ci", "app": {"id": 15368}, "head_sha": $head}]}]' \
    > "$dir/forge/check-runs.json"
  reset_calls "$dir"
  assert_ready "$dir" "$entry" "$HEAD_A" "a bound requirement reported by its own producer app is ready"
  assert_contains "$(cat "$dir/forge/calls.log")" "api --paginate --slurp repos/acme/app/commits/$HEAD_A/check-runs" \
    "a bound requirement reads the check runs reported at the live head"
  [ "$(calls "$dir")" = 4 ] || fail "a bound requirement costs exactly one more read: $(cat "$dir/forge/calls.log")"

  jq -cn --arg head "$HEAD_A" '[{"total_count": 1, "check_runs": [{"name": "ci", "app": {"id": 4242}, "head_sha": $head}]}]' \
    > "$dir/forge/check-runs.json"
  assert_silent "$dir" "$entry" "a same-named check run from another app does not satisfy a bound requirement"

  jq -cn '[{"total_count": 1, "check_runs": [{"name": "ci", "app": {"id": 15368}, "head_sha": "2222222222222222222222222222222222222222"}]}]' \
    > "$dir/forge/check-runs.json"
  assert_silent "$dir" "$entry" "a producer reported at another head does not satisfy a bound requirement"

  rm -f "$dir/forge/check-runs.json"
  : > "$dir/forge/fail-check-runs"
  assert_silent "$dir" "$entry" "an unreadable producer read is silence"
  rm -f "$dir/forge/fail-check-runs"

  printf '%s\n' 'not json' > "$dir/forge/raw-check-runs"
  assert_silent "$dir" "$entry" "a producer answer that is not JSON is silence"
  rm -f "$dir/forge/raw-check-runs"

  printf '%s\n' '{"protected": true, "protection": {"required_status_checks": {"checks": [{"context": "ci", "app_id": -1}], "contexts": []}}}' \
    > "$dir/forge/branch.json"
  reset_calls "$dir"
  assert_ready "$dir" "$entry" "$HEAD_A" "an unbound requirement is satisfied by name, with no producer read"
  [ "$(calls "$dir")" = 3 ] || fail "an unbound requirement still costs three reads: $(cat "$dir/forge/calls.log")"

  pass "producers: a producer-bound requirement needs its own app reported at the live head, and an unreadable producer read is silence"
}

test_a_missing_or_unusable_github_cli_is_silence() {
  local dir entry
  dir=$(new_case cli)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" cli-task "$HEAD_A" > "$entry"

  printf '%s\n' "$dir/bin/not-here" > "$dir/home/config/pr-green-gh"
  reset_calls "$dir"
  assert_silent "$dir" "$entry" "a configured forge CLI that does not exist is silence"
  [ "$(calls "$dir")" = 0 ] || fail "nothing is read when the forge CLI cannot be resolved"

  printf '%s\n' "$dir/bin/gh" "$dir/bin/gh" > "$dir/home/config/pr-green-gh"
  assert_silent "$dir" "$entry" "an ambiguous forge CLI configuration is silence rather than a guess"

  printf 'not executable\n' > "$dir/bin/plain"
  printf '%s\n' "$dir/bin/plain" > "$dir/home/config/pr-green-gh"
  assert_silent "$dir" "$entry" "a configured forge CLI that is not executable is silence"

  # A package manager installs its CLI behind a symlink, so that shape resolves.
  ln -s "$dir/bin/gh" "$dir/bin/gh-link"
  printf '%s\n' "$dir/bin/gh-link" > "$dir/home/config/pr-green-gh"
  assert_ready "$dir" "$entry" "$HEAD_A" "a configured forge CLI reached through a symlink, as a package manager installs it, is resolved"

  pass "cli: an absent, ambiguous, or unexecutable forge CLI is silence, never a wake, and a symlinked binary is resolved"
}

test_a_hanging_read_returns_silence_inside_the_budget() {
  local dir entry started elapsed
  dir=$(new_case budget)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" budget-task "$HEAD_A" > "$entry"
  mkdir -p "$dir/home/state/pr-green"
  printf '400\n' > "$dir/home/state/pr-green/read-budget-ms"
  printf '5\n' > "$dir/forge/hang-pr-view"
  reset_calls "$dir"
  started=$SECONDS
  assert_silent "$dir" "$entry" "a forge read that outlives the budget is silence"
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 3 ] || fail "a hanging read must return inside its budget, took ${elapsed}s"
  [ "$(calls "$dir")" = 1 ] || fail "a hanging read is attempted once and never answers: $(cat "$dir/forge/calls.log")"
  pass "budget: a forge read that hangs is silence within the shortened budget rather than a stall or a wake"
}

test_malformed_documents_and_partial_answers_are_silence() {
  local dir entry
  dir=$(new_case malformed)
  green_pr "$dir" "$HEAD_A"
  entry="$dir/entry.json"; entry_json "$dir" malformed-task "$HEAD_A" > "$entry"

  : > "$dir/forge/fail-pr-view"
  assert_silent "$dir" "$entry" "a failed pull read is silence"
  rm -f "$dir/forge/fail-pr-view"

  printf 'gh: something went wrong\n' > "$dir/forge/raw-pr-view"
  assert_silent "$dir" "$entry" "a pull read that is not JSON is silence"

  : > "$dir/forge/raw-pr-view"
  assert_silent "$dir" "$entry" "an empty pull read is silence"

  printf '%s\n' '[]' > "$dir/forge/raw-pr-view"
  assert_silent "$dir" "$entry" "a pull read that is an array is silence"

  printf '%s\n' '{}' > "$dir/forge/raw-pr-view"
  assert_silent "$dir" "$entry" "a pull read with no state is silence"
  rm -f "$dir/forge/raw-pr-view"

  rollup "$dir" '{"not": "an array"}'
  assert_silent "$dir" "$entry" "a rollup that is not an array is silence"

  rollup "$dir" '[null]'
  assert_silent "$dir" "$entry" "a rollup entry that is not an object is silence"

  rollup "$dir" '[{"__typename": "CheckRun", "name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}, {"__typename": "Deployment"}]'
  assert_silent "$dir" "$entry" "an entry the rollup does not classify as green is silence rather than an assumption"

  rollup "$dir" '[{"__typename": "CheckRun", "name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}, {"__typename": "Deployment", "state": "SUCCESS"}]'
  assert_silent "$dir" "$entry" "a green-looking state on an entry that is not a status context cannot stand in for a check"

  green_pr "$dir" "$HEAD_A"
  assert_ready "$dir" "$entry" "$HEAD_A" "the intact fixture is ready again after the malformed cases"

  pass "malformed: failed, empty, unparsable, wrongly shaped, and unclassified answers are all silence"
}

fork_run_tests
