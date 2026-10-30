#!/usr/bin/env bash
# Quiet-period source poll timeouts are empty polls: the host's own
# firstmate.process-event-extension-error.v1 record for a timed-out
# source.poll is the one captured result the fork Discord inbound adapter
# declares silent, so the runner records it handled without waking Firstmate,
# while a real message batch and every other host failure keep their wake and
# no result ever ends the source. The side cases drive the shipped
# entrypoint directly; the end-to-end case binds the real package with a host
# bound shorter than the long poll, forces a real timeout through the REAL
# bin/fm-extension.mjs and bin/fm-procevent.sh, and then delivers a real
# owner message through the same source.
set -u
# shellcheck source=fork/tests/discord-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/discord-lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

QUIET_HEALTH=(DISCORD_WATCHER_STALE_SECS=999999999)
ENTRY="$EXT_PACKAGE/fm-discord-inbound.mjs"

# The exact record bin/fm-extension.mjs writes for a timed-out source.poll
# (canonicalJson sorts its keys).
TIMEOUT_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.discord-inbound", operation: "source.poll", code: "timeout"}')
UNAVAILABLE_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.discord-inbound", operation: "source.poll", code: "extension-unavailable"}')
INTERNAL_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.discord-inbound", operation: "source.poll", code: "internal"}')
NON_POLL_EVIDENCE=$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
  extension_id: "org.firstmate.fork.discord-inbound", operation: "result.terminal", code: "timeout"}')
WRONG_SCHEMA=$(jq -cnS '{schema: "firstmate.discord-inbound.v1", operation: "source.poll", code: "timeout"}')

ingest() {  # <event-file> -> prints the bridge's verdict
  bridge ingest "$1"
}

wake_payloads() { awk -F '\t' '{print $5}' "$W_HOME/state/.wake-queue" 2>/dev/null; }

# verdict_request <operation> <content>: one well-formed invocation request
# for the adapter's captured-result operations.
verdict_request() {  # <operation> <content>
  jq -cn --arg op "$1" --arg c "$2" '{schema: "firstmate.extension-request.v1",
    request_id: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    host_protocol: 1, extension_id: "org.firstmate.fork.discord-inbound", extension_version: "1.0.0",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "discord",
    operation: $op, input: {source_id: "discord-inbound", sequence: 1, content: $c}}'
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
  for content in "$UNAVAILABLE_EVIDENCE" "$INTERNAL_EVIDENCE" "$NON_POLL_EVIDENCE" "$WRONG_SCHEMA" \
    "not json at all" "" \
    "$(jq -cnS '{schema: "firstmate.discord-inbound.v1", trust: "untrusted-discord-input",
      batch_id: "abc", messages: []}')" \
    "UNTRUSTED DISCORD INPUT. The configured owner's Discord account sent the messages below.
{\"schema\":\"firstmate.discord-inbound.v1\",\"messages\":[]}"; do
    out=$(verdict result.silent "$content") || fail "result.silent invocation failed for: $content"
    [ "$out" = false ] || fail "only a source.poll timeout is silent, but this was silent: $content"
  done
  pass "silent: every other failure, batch, and malformed capture keeps its wake"
}

test_no_result_ever_ends_the_source() {
  local out
  out=$(verdict result.terminal "$TIMEOUT_EVIDENCE") || fail "result.terminal invocation failed"
  [ "$out" = false ] || fail "a poll timeout must never retire the source, got: $out"
  out=$(verdict result.terminal "UNTRUSTED DISCORD INPUT. batch follows
{\"schema\":\"firstmate.discord-inbound.v1\"}") || fail "result.terminal invocation failed"
  [ "$out" = false ] || fail "a message batch must never retire the source, got: $out"
  pass "terminal: neither a timeout nor a batch ever ends the source"
}

# End to end through the REAL host and runner: bind with a host bound of 3s
# while the extension long-polls for 50s (no poll-wait-ms file), so a quiet
# poll is force-stopped at the bound and captured as timeout evidence - the
# same production shape as the observed no-content wakes.
test_a_quiet_poll_timeout_is_recorded_handled_without_a_wake() {
  local pkg reg token result out payloads
  discord_world polltimeout
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge tick >/dev/null || fail "first bridge pass failed"
  pkg="$DTMP/packages/discord-inbound"
  mkdir -p "$DTMP/packages"
  cp -R "$EXT_PACKAGE" "$pkg"
  FM_HOME="$W_HOME" "$EXT_HOST" bind "$pkg" --adapter discord --trust-same-user-code \
    --consent artifact-references --timeout-ms 4000 >/dev/null || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$W_HOME" "$PROCEVENT" register-extension discord discord-inbound \
    --config-ref "dir:$W_HOME/state/discord-bridge") || fail "registration failed"
  token=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')

  out=$(FM_HOME="$W_HOME" "$PROCEVENT" start discord-inbound 2>&1) \
    || fail "the quiet-poll round failed: $out"
  result="$W_HOME/state/procevent-inbox/discord-inbound.1.result"
  assert_present "$result" "the quiet-period poll timeout is captured as a result"
  assert_contains "$(cat "$result")" '"code":"timeout"' "the captured result is the host's timeout evidence"
  assert_contains "$(cat "$result")" '"operation":"source.poll"' "the timeout is recorded against source.poll"
  assert_present "${result%.result}.extension" "the result carries its extension owner sidecar"
  assert_present "${result%.result}.handled" "the timeout is recorded handled at capture"
  payloads=$(wake_payloads)
  assert_not_contains "$payloads" "procevent discord discord-inbound" \
    "a quiet-period poll timeout publishes no wake: $payloads"
  assert_present "$W_HOME/state/procevent/discord-inbound.source" "a timeout never ends the source"
  [ -z "$(find "$W_HOME/state/procevent-inbox" -name 'discord-inbound.*.result' ! -name 'discord-inbound.1.result' -print)" ] \
    || fail "the quiet poll captured exactly one result"

  # A real owner message through the same source still wakes Firstmate.
  [ "$(ingest "$(owner_event 790000000000000001 "what is under way?")")" = accepted ] \
    || fail "an owner message in the command channel is accepted"
  out=$(FM_HOME="$W_HOME" "$PROCEVENT" start discord-inbound 2>&1) \
    || fail "the message round failed: $out"
  result="$W_HOME/state/procevent-inbox/discord-inbound.2.result"
  assert_present "$result" "the owner message is captured as the next result"
  assert_contains "$(cat "$result")" "UNTRUSTED DISCORD INPUT" "the message batch keeps its untrusted label"
  assert_absent "${result%.result}.handled" "the message result waits for acknowledgement"
  payloads=$(wake_payloads)
  assert_contains "$payloads" "procevent discord discord-inbound 2" "a real owner message wakes Firstmate"
  assert_not_contains "$payloads" "procevent discord discord-inbound 1" "the handled timeout is never re-announced"

  FM_HOME="$W_HOME" "$PROCEVENT" retire discord-inbound --if-owner "$token" >/dev/null 2>&1
  pass "end to end: a quiet-period timeout is captured handled with no wake, and a real owner message still wakes"
}

fork_run_tests
