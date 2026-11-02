#!/usr/bin/env bash
# Capture self-conclusion: a readiness capture whose own task is already
# concluded by the time the capture is read - its pull request merged, or its
# task record state/<id>.meta gone - is recorded handled without a wake, so a
# moot advisory is never presented and never re-delivered, and a conclusion
# that lands between capture and read concludes the capture at read time. The
# live direction is pinned beside it: an advisory for a live task with an open
# pull request keeps its wake and its re-announcement, and every doubt - a live
# record behind an open, closed, or unreadable pull request, a missing home
# reference, non-advisory content - keeps the wake too.
#
# Side cases drive the shipped entrypoint's result.silent verdict directly.
# The end-to-end cases bind the real package and drive the REAL
# bin/fm-extension.mjs and bin/fm-procevent.sh: capture while the task is
# live, conclude the task, then let the runner's next read of that capture
# self-conclude it. No test contacts GitHub; the forge is always the recorded
# fixture CLI.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/pr-green/extension"
ENTRY="$PKG_SRC/fm-pr-green.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222
PR_7=https://github.com/acme/app/pull/7
PR_8=https://github.com/acme/app/pull/8

PTMP=$(fm_test_tmproot fm-fork-pr-green-self-conclude)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
# Source ownership claims are per user, not per home: without this, a real
# registered source of the same id on this machine owns the fixture's claim.
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

# One advisory body exactly as the real seam writes it - one line per ready
# pull request - for one task.
advisory() {  # <task-id> <pull-url> <head>
  printf 'PR READINESS (advisory): %s %s at head %s. Every reported check is green at that head. The single required check has reported at that head. This is advisory evidence to look at the pull request, not an approval, a merge, or authority to merge; the merge step re-reads every requirement itself.\n' "$1" "$2" "$3"
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# --- fixture home helpers (the same shapes the other pr-green suites use) ---

p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

record() {  # <home> <id> <key=value>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

armed() {
  printf '#!/usr/bin/env bash\n' > "$1/state/$2.check.sh"
  chmod 0600 "$1/state/$2.check.sh"
}

fast_poll() {
  mkdir -p "$1/state/pr-green"
  printf '100\n' > "$1/state/pr-green/poll-wait-ms"
}

# green_forge <home>: the fixture GitHub CLI serving a fully green OPEN pull
# request at HEAD_A, wired through this home's config/pr-green-gh.
green_forge() {
  fork_fixture_gh "$1/bin/gh" "$1/forge"
  mkdir -p "$1/config"
  printf '%s\n' "$1/bin/gh" > "$1/config/pr-green-gh"
  fork_pr_green_forge "$1/forge" "$HEAD_A"
}

# merge_the_fixture <home>: the same pull request now reads MERGED.
merge_the_fixture() {
  jq '.state = "MERGED"' "$1/forge/pr-view.json" > "$1/forge/merged.json" \
    && mv "$1/forge/merged.json" "$1/forge/pr-view.json"
}

# --- side verdicts through the shipped entrypoint ---------------------------

# verdict_request <content> [config-ref]: one well-formed result.silent
# invocation; the optional second argument attaches the home reference the
# host's HK7 block supplies on the real path.
verdict_request() {
  local c=$1 ref=${2-}
  jq -cn --arg c "$c" --arg ref "$ref" \
    --arg rid "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    '{schema: "firstmate.extension-request.v1", request_id: $rid,
      host_protocol: 1, extension_id: "org.firstmate.fork.pr-green",
      extension_version: "0.4.2",
      package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      capability: "process-event-adapter", capability_version: 1, adapter: "pr-green",
      operation: "result.silent",
      input: (if $ref == "" then {source_id: "pr-green", sequence: 1, content: $c}
              else {source_id: "pr-green", sequence: 1, content: $c, config_ref: $ref} end)}'
}

verdict() {  # <content> [config-ref] -> prints true|false
  verdict_request "$1" "${2-}" | node "$ENTRY" invoke | jq -r '.result.value'
}

test_a_merged_pull_request_concludes_its_capture() {
  local home out
  home="$PTMP/side-merged/home"
  p_home "$home"
  record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr="$PR_7" pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  green_forge "$home"
  merge_the_fixture "$home"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose pull request is merged must conclude, got: $out"
  assert_contains "$(cat "$home/forge/calls.log")" "pr view $PR_7" \
    "the verdict proves the merge with its own bounded forge read"
  pass "side: a capture for a merged pull request concludes"
}

test_a_gone_task_record_concludes_its_capture_without_a_forge_read() {
  local home out
  home="$PTMP/side-gone/home"
  p_home "$home"
  # No task record, and a forge that fails any call on purpose: the verdict
  # must conclude from the gone record alone and never consult the forge.
  fork_fixture_gh "$home/bin/gh" "$home/forge"
  printf '%s\n' "$home/bin/gh" > "$home/config/pr-green-gh"
  printf 'present\n' > "$home/forge/fail-pr-view"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose task record is gone must conclude, got: $out"
  assert_absent "$home/forge/calls.log" "a gone task record concludes without any forge read"
  pass "side: a capture whose task record is gone concludes without touching the forge"
}

test_a_live_task_or_any_doubt_keeps_the_wake() {
  local home out
  home="$PTMP/side-live/home"
  p_home "$home"
  record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr="$PR_7" pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  green_forge "$home"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a live task with an open pull request must keep its wake, got: $out"

  # CLOSED is not merged: only MERGED proves a conclusion.
  jq '.state = "CLOSED"' "$home/forge/pr-view.json" > "$home/forge/closed.json" \
    && mv "$home/forge/closed.json" "$home/forge/pr-view.json"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a closed-but-unmerged pull request must keep its wake, got: $out"

  # An unreadable pull request behind a live record is doubt, not proof.
  rm -f "$home/forge/pr-view.json"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "an unreadable pull request must keep its wake, got: $out"

  # No home reference (an older host) keeps the wake, exactly as before.
  green_forge "$home"
  out=$(verdict "$(advisory green-ship "$PR_7" "$HEAD_A")") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a capture without a home reference must keep its wake, got: $out"

  # Non-advisory content never concludes, even for a task that is gone.
  rm -f "$home/state/green-ship.meta"
  out=$(verdict '{"schema":"firstmate.process-event-extension-error.v1","code":"internal"}' "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "non-advisory content must keep its wake, got: $out"
  out=$(verdict "" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "an empty capture must keep its wake, got: $out"

  # The host's own poll-timeout evidence stays the other silent content.
  out=$(verdict "$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
    extension_id: "org.firstmate.fork.pr-green", operation: "source.poll", code: "timeout"}')" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "the poll-timeout absorb must survive with a home reference, got: $out"
  pass "side: a live task, an open/closed/unreadable pull request, a missing home reference, and non-advisory content all keep their wake"
}

test_a_multi_advisory_capture_concludes_only_when_every_task_does() {
  local home out both
  both="$(advisory task-a "$PR_7" "$HEAD_A")
$(advisory task-b "$PR_8" "$HEAD_B")"
  home="$PTMP/side-multi/home"
  p_home "$home"
  # task-a is gone; task-b is live with an open pull request.
  record "$home" task-b kind=ship harness=pi mode=no-mistakes yolo=on \
    pr="$PR_8" pr_head="$HEAD_B" spawn_gen=s1793000000.4200.8
  green_forge "$home"
  out=$(verdict "$both" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "one live task must keep the whole multi-advisory capture announced, got: $out"

  # Both tasks gone: the capture concludes.
  rm -f "$home/state/task-b.meta"
  out=$(verdict "$both" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose every task is gone must conclude, got: $out"
  pass "side: a multi-advisory capture concludes only when every advisory in it does"
}

# --- the real host and runner, end to end -----------------------------------

# install_package <home> <package-copy>: bind the copy and register the source
# through the real host and runner.
install_package() {
  local home=$1 pkg=$2 reg
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter pr-green --trust-same-user-code \
    --consent task-metadata --consent credential-store --consent network >/dev/null \
    || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$home" "$PROCEVENT" register-extension pr-green pr-green --config-ref "home:$home") \
    || fail "registration failed"
  printf '%s\n' "$reg" | grep -q '^owner-token: ' \
    || fail "registration must print its owner token"
}

# first_capture <home>: run the real runner until the live task's advisory is
# captured and announced once; sets RESULT to that capture.
first_capture() {
  local home=$1
  for _ in $(seq 1 50); do
    FM_HOME="$home" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
    [ -f "$home/state/procevent-inbox/pr-green.1.result" ] && break
    sleep 0.2
  done
  RESULT="$home/state/procevent-inbox/pr-green.1.result"
  assert_present "$RESULT" "the live task's advisory is captured"
  assert_contains "$(cat "$RESULT")" "PR READINESS (advisory)" "the capture carries the advisory body"
  assert_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" \
    "the live advisory is announced once"
  assert_absent "${RESULT%.result}.handled" "the live capture stays unhandled"
}

# build_live_home <home>: an armed live task with a green fixture pull request.
build_live_home() {
  p_home "$1"
  record "$1" green-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr="$PR_7" pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  armed "$1" green-ship
  green_forge "$1"
  fast_poll "$1"
}

test_a_capture_for_a_merged_pull_request_concludes_through_the_real_runner() {
  local home pkg before after
  home="$PTMP/e2e-merged/home"
  build_live_home "$home"
  pkg="$PTMP/e2e-merged/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  first_capture "$home"

  # The pull request merges after the capture exists: the next read of that
  # capture must conclude it instead of re-announcing it.
  merge_the_fixture "$home"
  before=$(wc -l < "$home/forge/calls.log" | tr -d ' ')
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  after=$(wc -l < "$home/forge/calls.log" | tr -d ' ')
  [ "$after" -gt "$before" ] \
    || fail "the read-time verdict must consult the forge to prove the merge"
  assert_contains "$(tail -n +"$((before + 1))" "$home/forge/calls.log")" "pr view $PR_7" \
    "the new forge read is the merge proof for this pull request"
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a merged pull request's capture must not be re-announced: $(wake_payloads "$home")"
  assert_present "${RESULT%.result}.handled" "the merged capture is recorded handled"
  # And it stays concluded: a later read never brings it back.
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a concluded capture must stay concluded: $(wake_payloads "$home")"
  assert_present "${RESULT%.result}.handled" "the handled record survives later reads"
  pass "end to end: a merge landing between capture and read concludes the capture at read time, with no wake and no pending re-delivery"
}

test_a_capture_for_a_cleaned_up_task_concludes_through_the_real_runner() {
  local home pkg before after
  home="$PTMP/e2e-gone/home"
  build_live_home "$home"
  pkg="$PTMP/e2e-gone/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  first_capture "$home"

  # The task is cleaned up after the capture exists: the next read of that
  # capture concludes it from the gone record alone, without a forge read.
  rm -f "$home/state/green-ship.meta"
  before=$(wc -l < "$home/forge/calls.log" | tr -d ' ')
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  after=$(wc -l < "$home/forge/calls.log" | tr -d ' ')
  [ "$after" = "$before" ] \
    || fail "a gone task record must conclude without any forge read ($before -> $after)"
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a cleaned-up task's capture must not be re-announced: $(wake_payloads "$home")"
  assert_present "${RESULT%.result}.handled" "the cleaned-up capture is recorded handled"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a concluded capture must stay concluded: $(wake_payloads "$home")"
  pass "end to end: a task record gone between capture and read concludes the capture with no wake, no forge read, and no pending re-delivery"
}

test_a_live_capture_still_reannounces_until_acknowledged() {
  local home pkg
  home="$PTMP/e2e-live/home"
  build_live_home "$home"
  pkg="$PTMP/e2e-live/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  first_capture "$home"

  # Nothing concluded: the same read that would self-conclude a moot capture
  # keeps re-announcing this live one until firstmate acknowledges it.
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  assert_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" \
    "a live task's unhandled capture is still re-announced"
  assert_absent "${RESULT%.result}.handled" "a live capture stays unhandled"
  FM_HOME="$home" "$PROCEVENT" handled pr-green 1 >/dev/null || fail "acknowledging the capture failed"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "an acknowledged capture is not re-announced: $(wake_payloads "$home")"
  pass "end to end: a live task's capture keeps its ordinary wake and re-announcement until acknowledged"
}

fork_run_tests
