#!/usr/bin/env bash
# Fork PR readiness latch: one wake per task, pull request, and live head.
#
# This file exists because the latch is a promise rather than a happy path, and
# that promise has three sides that pull against each other:
#
#   AT MOST ONE  two consults of the same green head produce one wake;
#   AT LEAST ONE a head that is genuinely ready is never suppressed - not by an
#                interrupted marker write, not by a crash between answering and
#                capture, and not by a marker left by another task, pull request,
#                or worker incarnation;
#   RE-ARM       a changed head (or a changed pull request, or a replaced worker)
#                wakes again.
#
# The deliberate order is duplicate over suppression, so most of these cases
# assert that a wake still happens where a naive latch would swallow it. Every
# case drives the REAL seam (fork/pr-green/extension/readiness.mjs) and, for the
# poll and end-to-end cases, the REAL extension host and process-event runner,
# against a fixture GitHub CLI. No test contacts GitHub, a forge CLI, or the
# running session's own home, and upstream's own suites are untouched: none of
# their expectations is relaxed to accommodate the fork.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

SEAM="$ROOT/fork/pr-green/extension/readiness.mjs"
ENTRY_POINT="$ROOT/fork/pr-green/extension/fm-pr-green.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"
PKG_SRC="$ROOT/fork/pr-green/extension"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222
PR_URL=https://github.com/acme/app/pull/7
PR_URL_8=https://github.com/acme/app/pull/8
INCARNATION=s1793000000.4200.7

PTMP=$(fm_test_tmproot fm-fork-pr-green-latch)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

# rid <label>: a distinct, well-shaped host request id per consult. The seam's
# latch records the id that produced a wake, so a test says exactly which host
# request it is answering.
rid() { printf 'sha256:%s' "$(printf 'request:%s' "$1" | shasum -a 256 | cut -d' ' -f1)"; }

# driver.mjs <seam> <entry-file> <ctx-json>: one real seam consult, printed as
# JSON. It is the same call the adapter makes, with the host request id the
# adapter passes.
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

# record <case-dir> <id> [key=value...]: the task record the seam re-reads. The
# default is an armed, yolo=on, no-mistakes ship at HEAD_A whose pull request is
# PR_URL, with its own spawn_gen= incarnation, so a case only states what it
# changes; an override REPLACES that key's default line rather than duplicating it,
# because a record with a duplicate key is refused as ambiguous.
record() {
  local dir=$1 id=$2 line override keep
  shift 2
  local -a defaults=( "kind=ship" "mode=no-mistakes" "yolo=on" "pr=$PR_URL" \
    "pr_head=$HEAD_A" "spawn_gen=$INCARNATION" )
  local -a kept=()
  for line in "${defaults[@]}"; do
    keep=1
    for override in "$@"; do
      if [ "${override%%=*}" = "${line%%=*}" ]; then keep=0; fi
    done
    if [ "$keep" = 1 ]; then kept+=("$line"); fi
  done
  {
    printf '%s\n' "${kept[@]}"
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi
  } > "$dir/home/state/$id.meta"
  chmod 0600 "$dir/home/state/$id.meta"
}

# armed <case-dir> <id>: the armed merge poll's sidecar, as bin/fm-pr-check.sh
# publishes it.
armed() {
  printf '#!/usr/bin/env bash\n' > "$1/state/$2.check.sh"
  chmod 0600 "$1/state/$2.check.sh"
}

# entry <case-dir> <id> [jq-filter]: the entry the adapter's gate would hand the
# seam, optionally narrowed by a jq filter over the entry.
entry() {  # <case-dir> <id> [<jq-filter>]
  local dir=$1 id=$2 filter=${3:-.}
  jq -cn --arg id "$id" --arg head "$HEAD_A" --arg url "$PR_URL" \
    --arg meta "$dir/home/state/$id.meta" \
    '{id: $id, mode: "no-mistakes", yolo: "on", kind: "ship", pr: $url,
      host: "github.com", owner: "acme", repo: "app", number: "7",
      head: $head, meta: $meta}' \
    | jq "$filter" > "$dir/$id.entry.json"
  printf '%s\n' "$dir/$id.entry.json"
}

ctx_json() {  # <case-dir> <request-id>
  jq -cn --arg home "$1/home" --arg state "$1/home/state" --arg config "$1/home/config" \
    --arg rid "$2" \
    '{home: $home, stateDir: $state, configDir: $config, now: 0, requestId: $rid}'
}

forge_green() {  # <case-dir> <head>
  fork_pr_green_forge "$1/forge" "$2"
}

reset_calls() { : > "$1/forge/calls.log"; }

calls() {  # <case-dir>: the recorded forge calls of the last consult
  if [ -f "$1/forge/calls.log" ]; then wc -l < "$1/forge/calls.log" | tr -d ' '; else printf '0'; fi
}

DECISION=
# consult <case-dir> <entry-file> <request-label>: one real seam consult.
consult() {
  local rc
  DECISION=$(node "$DRIVER" "$SEAM" "$2" "$(ctx_json "$1" "$(rid "$3")")" 2>"$1/seam.err"); rc=$?
  [ "$rc" -eq 0 ] || fail "the seam crashed instead of answering (exit $rc): $(cat "$1/seam.err")"
}

assert_wake() {  # <case-dir> <entry-file> <request-label> <message>
  consult "$1" "$2" "$3"
  [ "$DECISION" != null ] || fail "$4 (the seam stayed silent: $(cat "$1/seam.err"))"
  assert_contains "$DECISION" "advisory" "$4 (the answer is the advisory wake)"
}

assert_quiet() {  # <case-dir> <entry-file> <request-label> <message>
  consult "$1" "$2" "$3"
  [ "$DECISION" = null ] || fail "$4 (the seam answered ready: $DECISION)"
}

marker_of() {  # <case-dir> <id>
  printf '%s\n' "$1/home/state/$2.pr-green-ready"
}

read_marker_line() {  # <case-dir> <id> <line-number>
  sed -n "$3p" "$(marker_of "$1" "$2")" 2>/dev/null
}

# merge_notified <case-dir> <id>: the merge-notification marker upstream writes
# in the SAME state directory, in upstream's own format. Readiness state must be
# independent of it in both directions.
merge_notified() {
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/app\n7\n' \
    > "$1/home/state/$2.pr-poll-merge-notified"
  chmod 0600 "$1/home/state/$2.pr-poll-merge-notified"
}

test_two_consults_of_one_green_head_produce_one_wake() {
  local dir e marker
  dir=$(new_case twice)
  record "$dir" green-task
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"

  reset_calls "$dir"
  assert_wake "$dir" "$e" a "the first consult of a green head wakes firstmate"
  [ "$(calls "$dir")" = 3 ] || fail "the first consult reads the pull request and its required sources: $(cat "$dir/forge/calls.log")"

  marker=$(marker_of "$dir" green-task)
  assert_present "$marker" "the wake is recorded in a latch marker"
  [ -n "$(find "$marker" -maxdepth 0 -perm 600)" ] \
    || fail "the latch marker is private to this user"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '.fm-fork-pr-green-ready.*')" ] \
    || fail "publication leaves no temporary file behind"
  [ "$(wc -l < "$marker" | tr -d ' ')" = 10 ] \
    || fail "the marker is the fixed-arity record the reader expects: $(cat "$marker")"
  assert_equals "fm-fork-pr-green-ready-v1" "$(read_marker_line "$dir" green-task 1)" "the marker names its own version"
  assert_equals "green-task" "$(read_marker_line "$dir" green-task 2)" "the marker binds the task id"
  assert_equals "$INCARNATION" "$(read_marker_line "$dir" green-task 3)" "the marker binds the worker incarnation"
  assert_equals "github" "$(read_marker_line "$dir" green-task 4)" "the marker binds the provider"
  assert_equals "github.com" "$(read_marker_line "$dir" green-task 5)" "the marker binds the host"
  assert_equals "acme/app" "$(read_marker_line "$dir" green-task 6)" "the marker binds the repository"
  assert_equals "7" "$(read_marker_line "$dir" green-task 7)" "the marker binds the pull number"
  assert_equals "$HEAD_A" "$(read_marker_line "$dir" green-task 8)" "the marker binds the live head"
  assert_equals "$(rid a)" "$(read_marker_line "$dir" green-task 9)" "the marker binds the host request id that produced the wake"

  # The second consult is the same head under a later host request, which is what
  # an ordinary next poll looks like: silence, and no forge read at all.
  reset_calls "$dir"
  assert_quiet "$dir" "$e" b "a second consult of the same green head is silent"
  assert_contains "$(cat "$dir/seam.err")" "pr-green: latched green-task" "the silence names the latch"
  [ "$(calls "$dir")" = 0 ] || fail "an already-announced head costs no forge read at all: $(cat "$dir/forge/calls.log")"

  assert_quiet "$dir" "$e" c "a third consult stays silent too"
  pass "at most one: one green head wakes once, and every later consult of that head costs no forge read"
}

test_a_changed_head_wakes_again() {
  local dir e
  dir=$(new_case rearm)
  record "$dir" green-task
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"
  assert_wake "$dir" "$e" a "the head at which readiness was established wakes firstmate"
  assert_quiet "$dir" "$e" b "that head is then latched"

  # The same task pushes a new head and it goes green: a new question, so a wake.
  record "$dir" green-task "pr_head=$HEAD_B"
  e=$(entry "$dir" green-task '(.head = "2222222222222222222222222222222222222222")')
  forge_green "$dir" "$HEAD_B"
  assert_wake "$dir" "$e" c "a changed head is a new question and wakes again"
  assert_equals "$HEAD_B" "$(read_marker_line "$dir" green-task 8)" "the marker re-arms onto the new head"
  assert_quiet "$dir" "$e" d "the new head is then latched in its turn"
  pass "re-arm: a changed head wakes again, and the latch follows the head that produced the wake"
}

test_an_unpublished_marker_still_delivers_the_wake() {
  local dir e
  dir=$(new_case unwritable)
  record "$dir" green-task
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"

  # A marker that cannot be published must cost a duplicate wake, never the wake.
  chmod 0500 "$dir/home/state"
  assert_wake "$dir" "$e" a "a wake whose latch cannot be published is still delivered"
  assert_contains "$(cat "$dir/seam.err")" "pr-green: latch-unpublished green-task" \
    "the failed publication is named rather than passed off as recorded"
  assert_absent "$(marker_of "$dir" green-task)" "no marker exists after a failed publication"
  chmod 0700 "$dir/home/state"

  assert_wake "$dir" "$e" b "without a marker the next consult answers again"
  assert_present "$(marker_of "$dir" green-task)" "the retry publishes the marker"
  assert_quiet "$dir" "$e" c "and only then is the head latched"
  pass "interruption: a failed marker write repeats the wake and can never suppress it"
}

test_a_wake_that_was_never_captured_is_answered_again() {
  local dir e
  dir=$(new_case uncaptured)
  record "$dir" green-task
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"

  # Core derives the host request id from the next UNCAPTURED result sequence, so
  # a crash between answering a poll and capturing its result returns the same id
  # to the next attempt. That is exactly the case a head-only latch would swallow.
  assert_wake "$dir" "$e" crash "the first answer to this host request wakes firstmate"
  assert_wake "$dir" "$e" crash "the same host request answered again still delivers, because nothing captured it"
  assert_not_contains "$(cat "$dir/seam.err")" "pr-green: latched" \
    "an unanswered host request is never treated as already announced"

  # Once the host moves on, its next request id proves the earlier answer was
  # consumed, and only then does the latch apply.
  assert_quiet "$dir" "$e" captured "a later host request is silent once the earlier answer was captured"
  pass "at least one: a wake is repeated while its host request is unanswered and suppressed only once that request has moved on"
}

test_another_task_pull_request_head_or_worker_is_never_suppressed() {
  local dir a b
  dir=$(new_case identity)
  forge_green "$dir" "$HEAD_A"

  # Two tasks whose pull requests differ in number: each has its own latch.
  record "$dir" a-ship
  a=$(entry "$dir" a-ship)
  record "$dir" b-ship "pr=$PR_URL_8"
  b=$(entry "$dir" b-ship '(.pr = "https://github.com/acme/app/pull/8") | (.number = "8")')
  assert_wake "$dir" "$a" a "the first task's green head wakes"
  assert_wake "$dir" "$b" b "a second task on the same host and repository is not suppressed by the first"
  assert_present "$(marker_of "$dir" b-ship)" "the second task's marker exists beside the first"

  # The same task re-pointed at another pull request is a new identity.
  reset_calls "$dir"
  assert_quiet "$dir" "$a" c "the first task is latched at its own pull request"
  record "$dir" a-ship "pr=$PR_URL_8"
  a=$(entry "$dir" a-ship '(.pr = "https://github.com/acme/app/pull/8") | (.number = "8")')
  assert_wake "$dir" "$a" d "a task re-pointed at another pull request wakes again"
  assert_equals "8" "$(read_marker_line "$dir" a-ship 7)" "the marker follows the new pull request identity"

  # A replacement worker for the same task id (upstream mints a new spawn_gen=)
  # has not been told anything, so it must not inherit the old incantation's latch.
  record "$dir" a-ship "pr=$PR_URL_8" "spawn_gen=s1793000999.4300.9"
  a=$(entry "$dir" a-ship '(.pr = "https://github.com/acme/app/pull/8") | (.number = "8")')
  assert_wake "$dir" "$a" e "a replacement worker incarnation is not suppressed by its predecessor's marker"
  assert_equals "s1793000999.4300.9" "$(read_marker_line "$dir" a-ship 3)" "the marker re-binds to the new incarnation"
  pass "identity: the latch is per task, per provider and host, per pull request, per head, and per worker incarnation"
}

test_posture_is_re_read_before_delivery() {
  local dir e case_name
  dir=$(new_case posture)
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"

  for case_name in \
    "yolo-off:yolo=off" \
    "local-only:mode=local-only" \
    "secondmate-mode:mode=secondmate" \
    "secondmate-kind:kind=secondmate" \
    "other-pr:pr=https://github.com/acme/app/pull/8" \
    "other-head:pr_head=$HEAD_B" \
    "no-incarnation:spawn_gen=" \
    "duplicate-key:mode=no-mistakes"; do
    record "$dir" green-task "${case_name#*:}"
    # A duplicate key needs its own second line to make the record ambiguous.
    if [ "${case_name%%:*}" = duplicate-key ]; then
      printf 'mode=direct-PR\n' >> "$dir/home/state/green-task.meta"
    fi
    assert_quiet "$dir" "$e" "posture-${case_name%%:*}" \
      "a record whose current posture is ${case_name%%:*} never authorizes a wake"
    assert_contains "$(cat "$dir/seam.err")" "pr-green: not-ready green-task posture-changed" \
      "the refusal names the posture change rather than the forge"
    assert_absent "$(marker_of "$dir" green-task)" "no latch marker is published for a refused delivery"
  done

  rm -f "$dir/home/state/green-task.meta"
  assert_quiet "$dir" "$e" "posture-absent" "a task record that is gone never authorizes a wake"

  record "$dir" green-task
  assert_wake "$dir" "$e" "posture-ok" "the intact record is delivered again once the posture is restored"
  pass "posture: yolo, mode, kind, pull request, head, incarnation, and record readability are all re-read before delivery"
}

test_readiness_state_is_independent_of_merge_notification() {
  local dir e before after
  dir=$(new_case independent)
  record "$dir" green-task
  e=$(entry "$dir" green-task)
  forge_green "$dir" "$HEAD_A"
  merge_notified "$dir" green-task
  assert_not_contains "$(cat "$dir/home/state/green-task.pr-poll-merge-notified")" "$HEAD_A" \
    "the merge-notification marker does not carry a head at all"
  before=$(shasum -a 256 "$dir/home/state/green-task.pr-poll-merge-notified" | awk '{print $1}')

  reset_calls "$dir"
  assert_wake "$dir" "$e" a "a merge notification already recorded for this pull request does not suppress readiness"
  [ "$(calls "$dir")" = 3 ] || fail "the readiness consult still reads the forge: $(cat "$dir/forge/calls.log")"
  after=$(shasum -a 256 "$dir/home/state/green-task.pr-poll-merge-notified" | awk '{print $1}')
  assert_equals "$before" "$after" "the readiness latch leaves the merge-notification marker byte-identical"

  assert_quiet "$dir" "$e" b "the readiness latch then applies to readiness"
  after=$(shasum -a 256 "$dir/home/state/green-task.pr-poll-merge-notified" | awk '{print $1}')
  assert_equals "$before" "$after" "suppressing a readiness wake touches nothing about merge notification"

  # ... and removing readiness state leaves merge notification behind: the two
  # latches are separate files with separate owners.
  rm -f "$(marker_of "$dir" green-task)"
  assert_present "$dir/home/state/green-task.pr-poll-merge-notified" "dropping readiness state keeps the merge-notification marker"
  [ -z "$(find "$dir/home/state" -name '*merge-authority*' -o -name '*.answer*')" ] \
    || fail "no approval or merge authority is recorded by the readiness path"

  # A green head is announced again once its readiness state is gone, so readiness
  # suppression can never stand in for merge-notification state either.
  assert_wake "$dir" "$e" c "with no readiness marker the head wakes again, whatever merge notification says"
  pass "independence: readiness markers and merge-notification markers never read, write, or stand in for each other"
}

# adapter_poll <entrypoint> <config-ref>: one protocol invocation of one poll.
poll_request() {  # <request-hex> <config-ref>
  jq -cn --arg rid "sha256:$1" --arg ref "$2" '{schema: "firstmate.extension-request.v1", request_id: $rid,
    host_protocol: 1, extension_id: "org.firstmate.fork.pr-green", extension_version: "0.4.0",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "pr-green",
    operation: "source.poll", input: {source_id: "pr-green", config_ref: $ref}}'
}

adapter_poll() {  # <entrypoint> <config-ref>
  poll_request "$(printf '7%.0s' $(seq 1 64))" "$2" | node "$1" invoke
}

test_the_poll_prunes_markers_that_no_longer_name_a_live_identity() {
  local dir out
  dir=$(new_case prune)
  mkdir -p "$dir/home/state/pr-green"
  printf '100\n' > "$dir/home/state/pr-green/poll-wait-ms"
  fork_pr_pending_forge "$dir/forge" "$HEAD_A"

  # Four markers: one that still names a live identity, one whose task is gone,
  # one whose record has moved to another head, and one whose record is malformed.
  record "$dir" live-ship
  record "$dir" moved-ship
  record "$dir" adopted-ship "spawn_gen=s1793000000.4200.7"
  mkdir -p "$dir/home/state"
  for id in live-ship gone-ship moved-ship adopted-ship; do
    printf 'fm-fork-pr-green-ready-v1\n%s\n%s\ngithub\ngithub.com\nacme/app\n7\n%s\n%s\n1793000000\n' \
      "$id" "$INCARNATION" "$HEAD_A" "$(rid "$id")" > "$dir/home/state/$id.pr-green-ready"
    chmod 0600 "$dir/home/state/$id.pr-green-ready"
  done
  record "$dir" moved-ship "pr_head=$HEAD_B"
  printf 'kind=ship\nmode=no-mistakes\n' > "$dir/home/state/adopted-ship.meta"
  printf 'kind=ship\nmode=no-mistakes\n' >> "$dir/home/state/adopted-ship.meta"
  merge_notified "$dir" live-ship
  printf 'unrelated\n' > "$dir/home/state/notes.txt"

  out=$(adapter_poll "$ENTRY_POINT" "home:$dir/home" 2>"$dir/poll.err") || fail "the adapter's poll failed: $(cat "$dir/poll.err")"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] || fail "a pending forge is silence: $out"
  assert_contains "$(cat "$dir/poll.err")" "pr-green: latch-pruned 3" \
    "the poll prunes every marker its own records no longer account for"
  assert_present "$(marker_of "$dir" live-ship)" "the marker whose task, pull request, head, and incarnation still match is kept"
  for id in gone-ship moved-ship adopted-ship; do
    assert_absent "$(marker_of "$dir" "$id")" "the marker for $id is pruned, so it can never suppress a future identity"
  done
  assert_present "$dir/home/state/live-ship.pr-poll-merge-notified" "pruning never touches merge-notification state"
  assert_present "$dir/home/state/live-ship.meta" "pruning never touches a task record"
  assert_present "$dir/home/state/notes.txt" "pruning only ever touches marker files this fork wrote"
  assert_absent "$dir/home/state/gone-ship.meta" "the gone task really has no record, so the prune was not a guess"
  pass "cleanup: the ordinary poll prunes a marker whose task, pull request, head, or incarnation is no longer current"
}

test_the_fork_owned_teardown_path_drops_readiness_state_only() {
  local teardown=$ROOT/fork/bin/fm-pr-green-teardown out rc
  local dir
  dir=$(new_case teardown)
  for id in a-ship b-ship; do
    record "$dir" "$id"
    printf 'fm-fork-pr-green-ready-v1\n%s\n%s\ngithub\ngithub.com\nacme/app\n7\n%s\n%s\n1793000000\n' \
      "$id" "$INCARNATION" "$HEAD_A" "$(rid "$id")" > "$dir/home/state/$id.pr-green-ready"
  done
  merge_notified "$dir" a-ship

  out=$("$teardown" --home "$dir/home" --all --dry-run) || fail "a dry run must succeed"
  assert_contains "$out" "$dir/home/state/a-ship.pr-green-ready" "the dry run lists the marker it would remove"
  assert_present "$dir/home/state/a-ship.pr-green-ready" "a dry run removes nothing"

  # The default scope prunes only what the home's own records no longer account
  # for, so a routine call beside live tasks is always safe.
  out=$("$teardown" --home "$dir/home" --dry-run) || fail "a pruning dry run must succeed"
  assert_contains "$out" "would remove 0 readiness marker" \
    "the default scope keeps the markers of tasks this home still accounts for"

  "$teardown" --home "$dir/home" --task a-ship >/dev/null || fail "removing one task's readiness state failed"
  assert_absent "$dir/home/state/a-ship.pr-green-ready" "the named task's readiness state is gone"
  assert_present "$dir/home/state/b-ship.pr-green-ready" "another task's readiness state is kept"
  assert_present "$dir/home/state/a-ship.meta" "teardown keeps the task record"
  assert_present "$dir/home/state/a-ship.pr-poll-merge-notified" "teardown keeps merge-notification state"

  "$teardown" --home "$dir/home" --all >/dev/null || fail "removing every readiness marker failed"
  assert_absent "$dir/home/state/b-ship.pr-green-ready" "the remaining readiness state is gone"
  assert_present "$dir/home/state/b-ship.meta" "the bulk path keeps task records too"

  rc=0
  "$teardown" --home relative/path --all >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a relative home is refused rather than guessed at (exit $rc)"
  pass "teardown: the fork-owned teardown path drops readiness state, and only readiness state, for one task or a whole home"
}

# --- the whole promise through the real host and runner ---------------------

# fast_poll <home>: a fixture poll wait, so a poll returns quickly instead of
# holding its ordinary 50 seconds.
fast_poll() {
  mkdir -p "$1/state/pr-green"
  printf '100\n' > "$1/state/pr-green/poll-wait-ms"
}

install_package() {  # <home> <package-copy>: bind and register through the real host and runner.
  local home=$1 pkg=$2 reg
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter pr-green --trust-same-user-code \
    --consent task-metadata --consent credential-store --consent network >/dev/null \
    || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$home" "$PROCEVENT" register-extension pr-green pr-green --config-ref "home:$home") \
    || fail "registration failed"
  PKG_TOKEN=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')
  [ -n "$PKG_TOKEN" ] || fail "registration must print its owner token"
}

run_source() {  # <home>: one runner invocation, to completion
  FM_HOME="$1" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
}

result_files() {  # <home>
  local f
  for f in "$1"/state/procevent-inbox/pr-green.*.result; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

test_the_end_to_end_source_wakes_once_per_head_and_rearms_on_a_new_head() {
  local home pkg result
  home="$PTMP/e2e/home"
  pkg="$PTMP/e2e/packages/pr-green"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/bin" "$home/forge" "$(dirname "$pkg")"
  fork_fixture_gh "$home/bin/gh" "$home/forge"
  printf '%s\n' "$home/bin/gh" > "$home/config/pr-green-gh"
  printf '%s\n' "kind=ship" "harness=pi" "mode=no-mistakes" "yolo=on" \
    "pr=$PR_URL" "pr_head=$HEAD_A" "spawn_gen=$INCARNATION" > "$home/state/green-ship.meta"
  chmod 0600 "$home/state/green-ship.meta"
  printf '#!/usr/bin/env bash\n' > "$home/state/green-ship.check.sh"
  chmod 0600 "$home/state/green-ship.check.sh"
  forge_green "$home" "$HEAD_A"
  fast_poll "$home"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"

  run_source "$home"
  result="$home/state/procevent-inbox/pr-green.1.result"
  [ -f "$result" ] || fail "the real registered source published no readiness result"
  assert_contains "$(cat "$result")" "PR READINESS (advisory)" "the wake is the advisory readiness body"
  assert_contains "$(cat "$result")" "at head $HEAD_A" "the wake names the head readiness was established at"
  [ "$(printf '%s\n' "$(result_files "$home")" | wc -l | tr -d ' ')" = 1 ] \
    || fail "one green head produces exactly one captured result: $(result_files "$home")"
  assert_equals "$HEAD_A" "$(sed -n 8p "$home/state/green-ship.pr-green-ready")" \
    "the latch marker records the head that was announced"

  # The host acknowledges the wake and polls again: the same head must stay quiet.
  FM_HOME="$home" "$PROCEVENT" handled pr-green 1 >/dev/null || fail "acknowledging the first result failed"
  run_source "$home"
  sleep 0.3
  [ ! -e "$home/state/procevent-inbox/pr-green.2.result" ] \
    || fail "an acknowledged head reappeared as a fresh wake: $(cat "$home/state/procevent-inbox/pr-green.2.result")"

  # A new head goes green: the same registered source wakes again, in a new
  # result sequence, because a changed head re-arms.
  printf '%s\n' "kind=ship" "harness=pi" "mode=no-mistakes" "yolo=on" \
    "pr=$PR_URL" "pr_head=$HEAD_B" "spawn_gen=$INCARNATION" > "$home/state/green-ship.meta"
  chmod 0600 "$home/state/green-ship.meta"
  forge_green "$home" "$HEAD_B"
  run_source "$home"
  [ -f "$home/state/procevent-inbox/pr-green.2.result" ] || for _ in 1 2 3 4 5; do
    run_source "$home"
    [ -f "$home/state/procevent-inbox/pr-green.2.result" ] && break
    sleep 0.2
  done
  [ -f "$home/state/procevent-inbox/pr-green.2.result" ] \
    || fail "a changed green head produced no second wake"
  assert_contains "$(cat "$home/state/procevent-inbox/pr-green.2.result")" "at head $HEAD_B" \
    "the second wake names the changed head"
  [ "$(printf '%s\n' "$(result_files "$home")" | wc -l | tr -d ' ')" = 2 ] \
    || fail "exactly two wakes exist after one head change: $(result_files "$home")"
  assert_equals "$HEAD_B" "$(sed -n 8p "$home/state/green-ship.pr-green-ready")" \
    "the latch marker followed the changed head"
  FM_HOME="$home" "$PROCEVENT" retire pr-green --if-owner "$PKG_TOKEN" >/dev/null 2>&1 || true
  pass "end to end: the real source wakes once per green head, stays silent after acknowledgement, and re-arms on a changed head"
}

PKG_TOKEN=
fork_run_tests
