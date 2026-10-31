#!/usr/bin/env bash
# Fork PR readiness evaluation: the two missing-evidence guards.
#
# A pull request that is not provably mergeable, and a rollup that reports no
# check at all while the repository has an active workflow that triggers on
# pull_request, must never produce a readiness wake: GitHub skips required and
# CI checks on a conflicting head, so an all-green or empty rollup there is the
# artifact of checks that never ran, never evidence that they passed.
#
# Every case here drives the REAL extension/readiness.mjs against a fixture
# GitHub CLI (fork/tests/pr-green-fake-gh) that serves recorded responses. No
# test contacts GitHub, a real forge CLI, or the running session's home, and no
# test needs an account. The last case drives the REAL adapter entry end to end
# through the real protocol invocation, so the guards are proven on the path a
# poll actually takes, not only at the seam.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

SEAM="$ROOT/fork/pr-green/extension/readiness.mjs"
ENTRY="$ROOT/fork/pr-green/extension/fm-pr-green.mjs"
HEAD_A=1111111111111111111111111111111111111111
PR_URL=https://github.com/acme/app/pull/7

PTMP=$(fm_test_tmproot fm-fork-pr-green-evidence)
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
new_case() {
  local dir=$PTMP/$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/forge" "$dir/bin"
  fork_fixture_gh "$dir/bin/gh" "$dir/forge"
  printf '%s\n' "$dir/bin/gh" > "$dir/home/config/pr-green-gh"
  printf '%s\n' "$dir"
}

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
decide() {
  local before after rc
  before=$(home_manifest "$1")
  DECISION=$(node "$DRIVER" "$SEAM" "$2" "$(ctx_json "$1")" 2>"$1/seam.err"); rc=$?
  after=$(home_manifest "$1")
  [ "$rc" -eq 0 ] || fail "the seam crashed instead of answering (exit $rc): $(cat "$1/seam.err")"
  [ "$before" = "$after" ] || fail "the readiness predicate wrote to the home: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
}

assert_ready() {  # <case-dir> <entry-file> <message>
  decide "$1" "$2"
  [ "$DECISION" != null ] || fail "$3 (the seam stayed silent: $(cat "$1/seam.err"))"
  assert_contains "$DECISION" "advisory" "$3 (the advisory body says it is advisory)"
}

assert_silent() {  # <case-dir> <entry-file> <message>
  decide "$1" "$2"
  [ "$DECISION" = null ] || fail "$3 (the seam answered ready: $DECISION)"
}

calls() {  # <case-dir>: the recorded calls of the last decision
  if [ -f "$1/forge/calls.log" ]; then wc -l < "$1/forge/calls.log" | tr -d ' '; else printf '0'; fi
}

reset_calls() { : > "$1/forge/calls.log"; }

# green_view <case-dir> [mergeable]: the shared fully-green answer set at the
# recorded head, mergeable unless the case says otherwise.
green_view() {
  fork_pr_green_forge "$1/forge" "$HEAD_A"
  if [ -n "${2-}" ]; then
    jq --arg mergeable "$2" '.mergeable = $mergeable' \
      "$1/forge/pr-view.json" > "$1/view.json" && mv "$1/view.json" "$1/forge/pr-view.json"
  fi
}

# empty_view <case-dir> [mergeable]: the same pull request reporting NO checks at
# all, with a base branch no rule protects - the shape that must never read
# green while the repository's workflows run on pull requests.
empty_view() {
  jq -cn --arg head "$HEAD_A" --arg mergeable "${2:-MERGEABLE}" \
    '{state: "OPEN", isDraft: false, mergeable: $mergeable, headRefOid: $head, baseRefName: "main",
      statusCheckRollup: []}' > "$1/forge/pr-view.json"
  printf '%s\n' '{"protected": false}' > "$1/forge/branch.json"
  printf '%s\n' '[[{"type": "deletion"}]]' > "$1/forge/rules.json"
}

workflow_list() {  # <case-dir> <workflows-json>: the repository workflow list,
  # in the --slurp page shape the read returns
  jq -cn --argjson workflows "$2" '[{total_count: ($workflows | length), workflows: $workflows}]' \
    > "$1/forge/workflows-list.json"
}

workflow_file() {  # <case-dir> <basename> <yaml-source>: one workflow file's contents read
  jq -cn --arg content "$3" '{type: "file", encoding: "base64", content: ($content | @base64)}' \
    > "$1/forge/workflow-file-$2.json"
}

CI_WORKFLOW='[{"name": "ci", "path": ".github/workflows/ci.yml", "state": "active"}]'

test_a_pull_request_that_is_not_provably_mergeable_is_never_ready() {
  local dir entry
  dir=$(new_case not-mergeable)
  entry="$dir/entry.json"; entry_json "$dir" conflict-task "$HEAD_A" > "$entry"

  green_view "$dir" CONFLICTING
  reset_calls "$dir"
  assert_silent "$dir" "$entry" "a pull request that conflicts with its base is never ready"
  [ "$(calls "$dir")" = 1 ] || fail "a conflicting pull request is refused on the first read: $(cat "$dir/forge/calls.log")"
  assert_contains "$(cat "$dir/seam.err")" "not-ready conflict-task not-mergeable" \
    "the refusal names the unprovable mergeability"
  assert_not_contains "$(cat "$dir/forge/calls.log")" "branches/" \
    "a conflicting pull request never costs a required-context read"

  green_view "$dir" UNKNOWN
  assert_silent "$dir" "$entry" "a mergeability GitHub has not computed is never ready"

  green_view "$dir" MERGEABLE
  jq 'del(.mergeable)' "$dir/forge/pr-view.json" > "$dir/nomergeable.json" && mv "$dir/nomergeable.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "an unreadable mergeability field is never ready"

  green_view "$dir" MERGEABLE
  jq '.mergeable = "mergeable"' "$dir/forge/pr-view.json" > "$dir/lower.json" && mv "$dir/lower.json" "$dir/forge/pr-view.json"
  assert_silent "$dir" "$entry" "a mergeability value outside GitHub's own enum is never ready"

  green_view "$dir"
  assert_ready "$dir" "$entry" "the same pull request once GitHub reports it MERGEABLE is ready again"

  pass "mergeability: a conflicting, unknown, missing, or malformed mergeability field is silence, decided on the first read"
}

test_an_empty_rollup_beside_a_pull_request_workflow_is_never_ready() {
  local dir entry
  dir=$(new_case missing-checks)
  entry="$dir/entry.json"; entry_json "$dir" empty-task "$HEAD_A" > "$entry"
  empty_view "$dir"
  workflow_list "$dir" "$CI_WORKFLOW"

  workflow_file "$dir" ci.yml 'name: ci
on:
  pull_request:
jobs: {}
'
  reset_calls "$dir"
  assert_silent "$dir" "$entry" "a zero-check rollup beside an active pull_request workflow is never ready"
  assert_contains "$(cat "$dir/seam.err")" "not-ready empty-task checks-missing" \
    "the refusal names the missing checks"
  [ "$(calls "$dir")" = 5 ] \
    || fail "the zero-check case costs the pull, branch, and rules reads plus the workflow list and its one file: $(cat "$dir/forge/calls.log")"
  assert_contains "$(cat "$dir/forge/calls.log")" "api --paginate --slurp repos/acme/app/actions/workflows" \
    "the repository's workflow list is read"
  assert_contains "$(cat "$dir/forge/calls.log")" "api repos/acme/app/contents/.github/workflows/ci.yml" \
    "the active workflow's own file is read for its triggers"

  workflow_file "$dir" ci.yml 'name: ci
on: pull_request
jobs: {}
'
  assert_silent "$dir" "$entry" "the inline-scalar pull_request trigger is read the same way"

  workflow_file "$dir" ci.yml 'name: ci
on: [push, pull_request] # a trailing comment
jobs: {}
'
  assert_silent "$dir" "$entry" "the flow-list pull_request trigger is read the same way"

  workflow_file "$dir" ci.yml 'name: ci
on:
  - push
  - pull_request
jobs: {}
'
  assert_silent "$dir" "$entry" "the block-list pull_request trigger is read the same way"

  workflow_file "$dir" ci.yml 'name: ci
on: {pull_request: {types: [opened]}}
jobs: {}
'
  assert_silent "$dir" "$entry" "the flow-mapping pull_request trigger is read the same way"

  workflow_file "$dir" ci.yml "name: ci
on: \"pull_request\"
jobs: {}
"
  assert_silent "$dir" "$entry" "a quoted pull_request trigger is read the same way"

  # Two active files, only the second one triggers: the named per-file fixtures
  # let each file answer for itself.
  workflow_list "$dir" '[{"name": "ci", "path": ".github/workflows/ci.yml", "state": "active"},
    {"name": "release", "path": ".github/workflows/release.yml", "state": "active"}]'
  workflow_file "$dir" ci.yml 'name: ci
on: push
jobs: {}
'
  workflow_file "$dir" release.yml 'name: release
on:
  pull_request_target:
  pull_request:
jobs: {}
'
  assert_silent "$dir" "$entry" "one pull_request trigger among several active workflows is enough for silence"

  pass "missing evidence: a rollup that reports nothing beside an active pull_request workflow is silence, and the trigger scan reads every spelling"
}

test_an_empty_rollup_stays_ready_without_a_pull_request_workflow() {
  local dir entry
  dir=$(new_case empty-ok)
  entry="$dir/entry.json"; entry_json "$dir" benign-task "$HEAD_A" > "$entry"
  empty_view "$dir"

  workflow_list "$dir" '[{"name": "ci", "path": ".github/workflows/ci.yml", "state": "active"}]'
  workflow_file "$dir" ci.yml 'name: ci
on: push
jobs: {}
'
  reset_calls "$dir"
  assert_ready "$dir" "$entry" "a zero-check rollup is ready when the only active workflow never triggers on pull requests"
  [ "$(calls "$dir")" = 5 ] || fail "the ready zero-check case costs the same five reads: $(cat "$dir/forge/calls.log")"

  workflow_file "$dir" ci.yml 'name: ci
on:
  pull_request_target:
jobs: {}
'
  assert_ready "$dir" "$entry" "pull_request_target is a different trigger and does not block the wake"

  workflow_file "$dir" ci.yml 'name: ci
on: [push, workflow_dispatch]
jobs: {}
'
  assert_ready "$dir" "$entry" "a flow list without pull_request does not block the wake"

  workflow_list "$dir" '[{"name": "ci", "path": ".github/workflows/ci.yml", "state": "disabled"}]'
  assert_ready "$dir" "$entry" "a DISABLED workflow that triggers on pull requests cannot run, so it does not block the wake"

  workflow_list "$dir" '[]'
  assert_ready "$dir" "$entry" "a repository with no workflows at all leaves the zero-check rollup ready"

  pass "precision: only an ACTIVE pull_request workflow makes zero reported checks missing evidence"
}

test_an_unreadable_workflow_input_is_silence_never_no_workflow() {
  local dir entry
  dir=$(new_case workflows-unreadable)
  entry="$dir/entry.json"; entry_json "$dir" unreadable-task "$HEAD_A" > "$entry"
  empty_view "$dir"
  workflow_list "$dir" "$CI_WORKFLOW"
  workflow_file "$dir" ci.yml 'name: ci
on: push
jobs: {}
'
  reset_calls "$dir"
  assert_ready "$dir" "$entry" "the intact fixture answers ready before the inputs start breaking"

  : > "$dir/forge/fail-workflows-list"
  assert_silent "$dir" "$entry" "a failed workflow-list read beside an empty rollup is silence"
  rm -f "$dir/forge/fail-workflows-list"

  printf 'gh: something went wrong\n' > "$dir/forge/raw-workflows-list"
  assert_silent "$dir" "$entry" "a workflow-list answer that is not JSON is silence"
  printf '%s\n' '{}' > "$dir/forge/raw-workflows-list"
  assert_silent "$dir" "$entry" "a workflow-list answer with no workflows array is silence"
  printf '%s\n' '[{"total_count": 1, "workflows": [null]}]' > "$dir/forge/raw-workflows-list"
  assert_silent "$dir" "$entry" "a workflow entry that is not an object is silence"
  printf '%s\n' '[{"total_count": 1, "workflows": [{"name": "ci", "path": ".github/workflows/ci.yml"}]}]' > "$dir/forge/raw-workflows-list"
  assert_silent "$dir" "$entry" "a workflow entry with no readable state is silence"
  printf '%s\n' '[{"total_count": 1, "workflows": [{"name": "ci", "path": "../secrets", "state": "active"}]}]' > "$dir/forge/raw-workflows-list"
  assert_silent "$dir" "$entry" "an active workflow with an unusable path is silence"
  rm -f "$dir/forge/raw-workflows-list"

  rm -f "$dir/forge/workflows-list.json"
  assert_silent "$dir" "$entry" "a workflow-list read with no answer at all is silence"
  workflow_list "$dir" "$CI_WORKFLOW"

  : > "$dir/forge/fail-workflow-file-ci.yml"
  assert_silent "$dir" "$entry" "a failed workflow-file read beside an empty rollup is silence"
  rm -f "$dir/forge/fail-workflow-file-ci.yml"

  printf 'not json\n' > "$dir/forge/raw-workflow-file-ci.yml"
  assert_silent "$dir" "$entry" "a workflow-file answer that is not JSON is silence"
  printf '%s\n' '{"type": "directory", "encoding": "base64", "content": ""}' > "$dir/forge/raw-workflow-file-ci.yml"
  assert_silent "$dir" "$entry" "a workflow-file answer that is not one file is silence"
  printf '%s\n' '{"type": "file", "encoding": "utf-8", "content": "b246Cg=="}' > "$dir/forge/raw-workflow-file-ci.yml"
  assert_silent "$dir" "$entry" "a workflow-file answer that is not base64 is silence"
  rm -f "$dir/forge/raw-workflow-file-ci.yml"

  workflow_file "$dir" ci.yml 'name: ci
jobs: {}
'
  assert_silent "$dir" "$entry" "a workflow file with no readable trigger block is silence, never \"does not trigger\""
  workflow_file "$dir" ci.yml 'on:
  <<: *defaults
'
  assert_silent "$dir" "$entry" "a trigger block behind a YAML merge key is silence, never a guess"
  workflow_file "$dir" ci.yml 'on:
'
  assert_silent "$dir" "$entry" "an empty trigger block is silence, never a guess"

  workflow_file "$dir" ci.yml 'name: ci
on: push
jobs: {}
'
  assert_ready "$dir" "$entry" "the intact fixture is ready again after the unreadable inputs"

  pass "unreadable: every workflow input that cannot be read keeps the whole judgment silent, never \"no pull-request workflow\""
}

# --- the real adapter, end to end -------------------------------------------

p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

record() {  # <home> <id> <key=value>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

adapter_poll() {  # <config-ref>: one real protocol poll of the real adapter
  jq -cn --arg rid "sha256:$(printf '5%.0s' $(seq 1 64))" --arg ref "$1" \
    '{schema: "firstmate.extension-request.v1", request_id: $rid,
      host_protocol: 1, extension_id: "org.firstmate.fork.pr-green", extension_version: "0.4.1",
      package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      capability: "process-event-adapter", capability_version: 1, adapter: "pr-green",
      operation: "source.poll", input: {source_id: "pr-green", config_ref: $ref}}' \
    | node "$ENTRY" invoke
}

test_the_real_adapter_stays_silent_exactly_where_the_guards_silence() {
  local home out
  home="$PTMP/e2e/home"
  p_home "$home"
  record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr="$PR_URL" pr_head="$HEAD_A" spawn_gen=s1793000000.4300.1
  printf '#!/usr/bin/env bash\n' > "$home/state/green-ship.check.sh"
  chmod 0600 "$home/state/green-ship.check.sh"
  fork_fixture_gh "$home/bin/gh" "$home/forge"
  printf '%s\n' "$home/bin/gh" > "$home/config/pr-green-gh"
  mkdir -p "$home/state/pr-green"
  printf '100\n' > "$home/state/pr-green/poll-wait-ms"

  # A fully green rollup on a CONFLICTING head: the shape that fired the false
  # ready wake. The poll must answer nothing at all.
  fork_pr_green_forge "$home/forge" "$HEAD_A"
  jq '.mergeable = "CONFLICTING"' "$home/forge/pr-view.json" > "$home/view.json" && mv "$home/view.json" "$home/forge/pr-view.json"
  out=$(adapter_poll "home:$home" 2>/dev/null) || fail "the adapter's poll must answer, not crash"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a conflicting pull request must produce no readiness result: $out"

  # Mergeable but reporting no checks at all, beside an active pull_request
  # workflow: also missing evidence, also silence.
  empty_view "$home"
  workflow_list "$home" "$CI_WORKFLOW"
  workflow_file "$home" ci.yml 'name: ci
on:
  pull_request:
jobs: {}
'
  out=$(adapter_poll "home:$home" 2>/dev/null) || fail "the adapter's poll must answer, not crash"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a zero-check rollup beside a pull_request workflow must produce no readiness result: $out"
  assert_contains "$(cat "$home/forge/calls.log")" "contents/.github/workflows/ci.yml" \
    "the real poll really read the active workflow's own file, so the guard - not an unreadable input - held the wake back"

  # The same pull request, now mergeable with its checks reported green: the
  # guards alone were holding the wake back, and the real path delivers it.
  green_view "$home"
  out=$(adapter_poll "home:$home" 2>/dev/null) || fail "the adapter's poll must answer, not crash"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = result ] \
    || fail "a mergeable green pull request must produce the readiness result: $out"
  assert_contains "$(printf '%s' "$out" | jq -r .result.output)" "PR READINESS (advisory)" \
    "the delivered result carries the advisory body"

  pass "adapter: the real poll goes silent exactly where the two guards silence, and delivers once the pull request is provably mergeable and green"
}

fork_run_tests
