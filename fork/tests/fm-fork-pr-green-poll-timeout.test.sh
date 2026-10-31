#!/usr/bin/env bash
# A quiet-period source poll timeout is an empty poll: the host's own
# firstmate.process-event-extension-error.v1 record for a timed-out
# source.poll under this extension's id is the one captured result the fork
# PR readiness adapter declares silent, so the runner records it handled
# without waking Firstmate, while a readiness advisory, a non-timeout host
# failure, a timeout naming another operation or another extension, and every
# other capture keep their wake, and no result ever ends the source. The side
# cases drive the shipped entrypoint directly; the end-to-end case binds the
# real package with a host bound shorter than the long poll, forces a real
# timeout through the REAL bin/fm-extension.mjs and bin/fm-procevent.sh, and
# checks the capture is handled with no wake while the source keeps listening.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/pr-green/extension"
ENTRY="$PKG_SRC/fm-pr-green.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"

PTMP=$(fm_test_tmproot fm-fork-pr-green-poll-timeout)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
# Source ownership claims are per user, not per home: without this, a real
# registered source of the same id on this machine owns the fixture's claim.
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

# The exact record bin/fm-extension.mjs writes for a timed-out source.poll
# (canonicalJson sorts its keys), and the near misses that must keep waking.
TIMEOUT_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.pr-green", operation: "source.poll", code: "timeout"}')
UNAVAILABLE_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.pr-green", operation: "source.poll", code: "extension-unavailable"}')
INTERNAL_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.pr-green", operation: "source.poll", code: "internal"}')
NON_POLL_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.pr-green", operation: "result.terminal", code: "timeout"}')
OTHER_EXTENSION_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.discord-inbound", operation: "source.poll", code: "timeout"}')
WRONG_SCHEMA=$(jq -cnS '{schema: "firstmate.pr-green-readiness.v1", operation: "source.poll", code: "timeout"}')
READINESS_ADVISORY="PR READINESS (advisory): ok-nomistakes https://github.com/acme/app/pull/7 at head 1111111111111111111111111111111111111111.
Every reported check is green at that head. This is evidence for firstmate to look, not approval, and the merge step re-reads every requirement before merging."

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# verdict_request <operation> <content>: one well-formed invocation request
# for the adapter's captured-result operations.
verdict_request() {  # <operation> <content>
  jq -cn --arg op "$1" --arg c "$2" '{schema: "firstmate.extension-request.v1",
    request_id: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    host_protocol: 1, extension_id: "org.firstmate.fork.pr-green", extension_version: "0.4.1",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "pr-green",
    operation: $op, input: {source_id: "pr-green", sequence: 1, content: $c}}'
}

verdict() {  # <operation> <content> -> prints true|false
  verdict_request "$1" "$2" | node "$ENTRY" invoke | jq -r '.result.value'
}

test_a_poll_timeout_evidence_is_the_one_silent_result() {
  local out
  out=$(verdict result.silent "$TIMEOUT_EVIDENCE") || fail "result.silent invocation failed"
  [ "$out" = true ] || fail "a source.poll timeout must be silent, got: $out"
  out=$(verdict result.silent "$TIMEOUT_EVIDENCE"$'\n') || fail "result.silent invocation with trailing newline failed"
  [ "$out" = true ] || fail "a source.poll timeout must be silent with the host's trailing newline, got: $out"
  pass "silent: the host's source.poll timeout evidence is the one silent result"
}

test_every_other_captured_result_stays_announced() {
  local content out
  for content in "$READINESS_ADVISORY" "$UNAVAILABLE_EVIDENCE" "$INTERNAL_EVIDENCE" \
    "$NON_POLL_EVIDENCE" "$OTHER_EXTENSION_EVIDENCE" "$WRONG_SCHEMA" \
    "not json at all" ""; do
    out=$(verdict result.silent "$content") || fail "result.silent invocation failed for: $content"
    [ "$out" = false ] || fail "only this source's poll timeout is silent, but this was silent: $content"
  done
  pass "silent: a readiness advisory, every other host failure, and every near-miss timeout keep their wake"
}

test_no_result_ever_ends_the_source() {
  local out
  out=$(verdict result.terminal "$TIMEOUT_EVIDENCE") || fail "result.terminal invocation failed"
  [ "$out" = false ] || fail "a poll timeout must never retire the source, got: $out"
  out=$(verdict result.terminal "$READINESS_ADVISORY") || fail "result.terminal invocation failed"
  [ "$out" = false ] || fail "a readiness advisory must never retire the source, got: $out"
  pass "terminal: neither a timeout nor an advisory ever ends the source"
}

# End to end through the REAL host and runner: bind with a host bound of 4s
# while the extension long-polls for its ordinary 50s (no poll-wait-ms file),
# so the quiet poll is force-stopped at the bound and captured as timeout
# evidence - the same production shape as the sleep-induced no-content wakes.
test_a_captured_poll_timeout_is_handled_without_a_wake() {
  local home pkg reg token out result
  home="$PTMP/e2e/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  pkg="$PTMP/e2e/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter pr-green --trust-same-user-code \
    --consent task-metadata --consent credential-store --consent network --timeout-ms 4000 >/dev/null \
    || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$home" "$PROCEVENT" register-extension pr-green pr-green --config-ref "home:$home") \
    || fail "registration failed"
  token=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')
  [ -n "$token" ] || fail "registration must print its owner token"

  out=$(FM_HOME="$home" "$PROCEVENT" start pr-green 2>&1) \
    || fail "the quiet-poll round failed: $out"
  result="$home/state/procevent-inbox/pr-green.1.result"
  assert_present "$result" "the quiet-period poll timeout is captured as a result"
  assert_contains "$(cat "$result")" '"code":"timeout"' "the captured result is the host's timeout evidence"
  assert_contains "$(cat "$result")" '"operation":"source.poll"' "the timeout is recorded against source.poll"
  assert_contains "$(cat "$result")" '"extension_id":"org.firstmate.fork.pr-green"' \
    "the timeout evidence names this extension"
  assert_present "${result%.result}.extension" "the result carries its extension owner sidecar"
  assert_present "${result%.result}.handled" "the timeout is recorded handled at capture"
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a quiet-poll timeout publishes no wake: $(wake_payloads "$home")"
  assert_present "$home/state/procevent/pr-green.source" "a timeout never ends the source"
  [ "$(FM_HOME="$home" "$PROCEVENT" classify "$result")" = pr-ready-error ] \
    || fail "a timeout must still classify as host failure evidence, never readiness advice"
  [ -z "$(find "$home/state/procevent-inbox" -name 'pr-green.*.result' ! -name 'pr-green.1.result' -print)" ] \
    || fail "the quiet poll captured exactly one result"

  FM_HOME="$home" "$PROCEVENT" retire pr-green --if-owner "$token" >/dev/null 2>&1
  assert_absent "$home/state/procevent/pr-green.source" "the owner token still retires the registration"
  pass "end to end: a captured poll timeout is recorded handled with no wake, and the source keeps listening"
}

fork_run_tests
