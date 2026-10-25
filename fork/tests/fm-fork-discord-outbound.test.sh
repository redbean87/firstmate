#!/usr/bin/env bash
# Outbound half of the fork Discord bridge: replies from the REAL upstream
# mirror writer and from the fork's full-length Stop hook, operational events
# from the REAL fleet-ledger writer, the watcher-health notices, and the
# durable outbox's ordering, splitting, retry, permanent-failure, crash, and
# deduplication behavior, all against a fake Discord REST API.
set -u
# shellcheck source=fork/tests/discord-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/discord-lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

QUIET_HEALTH=(DISCORD_WATCHER_STALE_SECS=999999999)

# chunk_body <content>: a chunk without its " (k/n)" suffix.
chunk_body() { printf '%s' "$1" | sed -E 's/ \([0-9]+\/[0-9]+\)$//'; }

test_mirror_replies_are_split_in_order_and_routed_to_replies() {
  local long out first second
  discord_world mirror
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  mirror_say "a reply from before the bridge started"
  bridge tick || fail "first pass failed"
  [ "$(post_count)" = 0 ] || fail "the first start must not replay earlier mirror entries"
  long=$(python3 -c 'print("\n".join("line %04d of a long Firstmate reply" % i for i in range(1, 101)))')
  mirror_say "$long"
  mirror_say "a short second reply"
  bridge tick || fail "delivery pass failed"
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "expected two chunks and one reply in the replies channel: $(posts)"
  [ "$(post_count "$D_OPS")" = 0 ] || fail "a reply leaked into the operations channel"
  out=$(posts "$W_REPLIES" | jq -r .content)
  first=$(posts "$W_REPLIES" | sed -n 1p | jq -r .content)
  second=$(posts "$W_REPLIES" | sed -n 2p | jq -r .content)
  assert_contains "$first" " (1/2)" "the first chunk carries its marker"
  assert_contains "$second" " (2/2)" "the second chunk carries its marker"
  [ "$(chunk_body "$first")"$'\n'"$(chunk_body "$second")" = "$long" ] \
    || fail "chunks must reassemble to the reply, split at a line boundary"
  [ "$(posts "$W_REPLIES" | sed -n 3p | jq -r .content)" = "a short second reply" ] || fail "replies must stay in order"
  [ "$(posts "$W_REPLIES" | jq -s 'map(.mentions | length) | add')" = 0 ] || fail "replies never mention anyone"
  bridge tick
  [ "$(post_count)" = 3 ] || fail "a later pass must not resend delivered replies"
  [ -z "$(ls "$W_HOME/state/discord-bridge/outbox/replies")" ] || fail "the outbox must be empty after delivery"
  pass "mirror replies: first start skips history, long replies split in order at line boundaries, replies channel only, sent once"
}

test_mirror_truncation_is_stated_never_hidden() {
  local text
  discord_world trunc
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge tick
  mirror_say "$(python3 -c 'print("word " * 1200)')"
  bridge tick
  text=$(posts "$W_REPLIES" | jq -r .content)
  assert_contains "$text" "mirror truncated:" "the mirror's own truncation note is delivered"
  assert_contains "$text" "[Shortened: the local mirror keeps about 4000 characters" "the bridge states that the reply was shortened"
  pass "mirror fallback: a reply over the mirror's cap is delivered with an explicit shortened notice"
}

test_hook_delivers_complete_replies() {
  local long out rc spool joined
  discord_world hook
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_REPLIES_SOURCE=hook)
  fresh_beat
  bridge tick || fail "first pass failed"
  spool="$W_HOME/state/discord-bridge/replies-spool"
  [ -d "$spool" ] || fail "hook mode must create the reply spool"
  long=$(python3 -c 'print(" ".join(str(i) for i in range(1, 1501)))')
  out=$(hook_stop "$(stop_payload "$long")"); rc=$?
  expect_code 0 "$rc" "the hook always exits 0"
  [ -z "$out" ] || fail "the hook must print nothing: $out"
  out=$(printf '%s' "$(stop_payload "$long")" | FM_HOME="$W_HOME" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$REPLY_HOOK"); rc=$?
  expect_code 0 "$rc" "outside the lock-owning session the hook still exits 0"
  hook_stop '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}'
  hook_stop "$(stop_payload "   ")"
  [ "$(find "$spool" -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
    || fail "only the session's non-empty Stop event may be recorded: $(ls "$spool")"
  hook_stop "$(stop_payload "the continued answer" true)"
  bridge tick || fail "delivery pass failed"
  [ "$(post_count "$D_OPS")" = 0 ] || fail "a reply leaked into the operations channel"
  [ "$(post_count "$W_REPLIES")" -ge 5 ] || fail "a 6392-character reply needs four chunks plus the continuation: $(post_count)"
  joined=$(posts "$W_REPLIES" | jq -s -r '.[:-1][] | .content' | while IFS= read -r c; do chunk_body "$c"; printf ' '; done)
  [ "${joined% }" = "$long" ] || fail "the full reply must arrive complete, in order"
  [ "$(posts "$W_REPLIES" | tail -n 1 | jq -r .content)" = $'(continued)\nthe continued answer' ] \
    || fail "a second Stop for the same prompt is delivered as a marked continuation"
  [ -z "$(find "$spool" -name '*.json')" ] || fail "delivered spool events are removed"
  pass "reply hook: complete 6392-character reply delivered in order; only the session's Stop events; continuation marked; hook silent and exit 0"
}

test_hook_is_inert_without_hook_mode() {
  discord_world hookoff
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge tick
  hook_stop "$(stop_payload "nothing records this")"
  assert_absent "$W_HOME/state/discord-bridge/replies-spool" "mirror mode has no spool for the hook to write"
  pass "reply hook: inert unless the bridge runs in hook mode"
}

test_install_hook_preserves_settings() {
  local dir="$DTMP/settings" s before out rc
  mkdir -p "$dir"
  s="$dir/settings.local.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' > "$s"
  before=$(cat "$s")
  discord_world settings
  bridge install-hook --settings "$s" >/dev/null || fail "install failed"
  [ "$(jq -c .permissions "$s")" = '{"allow":["Bash(ls)"]}' ] || fail "existing settings must be preserved"
  [ "$(jq '.hooks.Stop | length' "$s")" = 2 ] || fail "the reply hook is added beside the existing Stop hook"
  [ "$(cat "$s.before-discord-hook")" = "$before" ] || fail "the previous settings are kept beside the file"
  bridge install-hook --settings "$s" >/dev/null
  [ "$(jq '.hooks.Stop | length' "$s")" = 2 ] || fail "installing twice must not add a second hook"
  bridge uninstall-hook --settings "$s" >/dev/null
  [ "$(jq -c '.hooks.Stop' "$s")" = '[{"hooks":[{"type":"command","command":"echo other"}]}]' ] || fail "uninstall removes only the reply hook"
  printf '{not json' > "$dir/bad.json"
  out=$(bridge install-hook --settings "$dir/bad.json" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "invalid settings must be refused"
  [ "$(cat "$dir/bad.json")" = '{not json' ] || fail "refused settings must be unchanged"
  bridge install-hook --settings "$dir/new/settings.local.json" >/dev/null || fail "an absent settings file is created"
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$dir/new/settings.local.json")" != null ] || fail "the created file holds the hook"
  pass "install-hook: preserves existing settings, keeps a copy, is idempotent, refuses invalid JSON, uninstalls only its own hook"
}

test_retry_schedule_429_5xx_transport_then_success() {
  local nonces
  discord_world retry
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1000)
  fresh_beat
  bridge tick
  printf '429 2\n503\nfail\n' > "$W_FAKE/responses"
  mirror_say "retry me"
  bridge tick
  [ "$(post_count)" = 1 ] || fail "the first attempt is rate limited"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1001); bridge tick
  [ "$(post_count)" = 1 ] || fail "Retry-After must be honored"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1003); bridge tick
  [ "$(post_count)" = 2 ] || fail "the retry after Retry-After happens"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1003.5); bridge tick
  [ "$(post_count)" = 2 ] || fail "a server error backs off"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1010); bridge tick
  [ "$(post_count)" = 3 ] || fail "the backoff ends and a transport failure follows"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_NOW=1040); bridge tick
  [ "$(post_count)" = 4 ] || fail "the fourth attempt succeeds"
  nonces=$(posts | jq -r .nonce | sort -u | wc -l | tr -d ' ')
  [ "$nonces" = 1 ] || fail "every attempt of one chunk carries the same nonce"
  [ -z "$(ls "$W_HOME/state/discord-bridge/outbox/replies")" ] || fail "the delivered entry leaves the outbox"
  assert_grep '"result": "retry-after 2"' "$W_HOME/state/discord-bridge/bridge.log" "the rate limit is logged"
  assert_no_grep "retry me" "$W_HOME/state/discord-bridge/bridge.log" "logs never carry message text"
  assert_no_grep "$D_TOKEN" "$W_HOME/state/discord-bridge/bridge.log" "logs never carry the token"
  pass "retry: 429 waits Retry-After, 5xx and transport failures back off, same nonce, delivered once"
}

test_permanent_failures_are_kept_and_reported() {
  local before
  discord_world perm
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge tick
  printf '403\n' > "$W_FAKE/responses"
  mirror_say "first reply refused"
  mirror_say "second reply delivered"
  bridge tick
  [ "$(find "$W_HOME/state/discord-bridge/failed" -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail "a refused message is kept for diagnosis"
  [ "$(posts "$W_REPLIES" | tail -n 1 | jq -r .content)" = "second reply delivered" ] || fail "later replies continue after a permanent failure"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "could not be delivered (http 403)" "the failure is reported in the operations channel"
  assert_not_contains "$(posts "$D_OPS" | jq -r .content)" "first reply refused" "the report does not repeat the message body"
  discord_world permops
  D_EXTRA_ENV=(DISCORD_WATCHER_STALE_SECS=60)
  printf '404\n' > "$W_FAKE/responses"
  bridge tick
  before=$(post_count)
  bridge tick; bridge tick
  [ "$(post_count)" = "$before" ] || fail "a permanently refused operations message must not be retried"
  pass "permanent errors: kept in failed/, reported without the body, later messages continue, no futile retries"
}

test_crash_after_remote_accept_resends_with_same_nonce() {
  local long rc nonces n
  discord_world crash
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_REPLIES_SOURCE=hook)
  fresh_beat
  bridge tick
  long=$(python3 -c 'print(" ".join("w%d" % i for i in range(1, 1200)))')
  hook_stop "$(stop_payload "$long")"
  printf '2\n' > "$W_FAKE/kill-after-post"
  bridge tick; rc=$?
  [ "$rc" -ne 0 ] || fail "the injected crash must end the bridge"
  [ "$(post_count)" = 2 ] || fail "two chunks were accepted before the crash"
  bridge tick || fail "the restarted pass failed"
  n=$(posts | sed -n 1p | jq -r .content | sed -E 's/.* \(1\/([0-9]+)\)$/\1/')
  [ "$n" -ge 3 ] || fail "the fixture reply must need at least three chunks: $n"
  nonces=$(posts | jq -r .nonce)
  [ "$(printf '%s\n' "$nonces" | wc -l | tr -d ' ')" = $((n + 1)) ] || fail "after restart only the unrecorded chunk is sent twice"
  [ "$(printf '%s\n' "$nonces" | sed -n 2p)" = "$(printf '%s\n' "$nonces" | sed -n 3p)" ] \
    || fail "the resent chunk carries the same nonce, so Discord can drop the repeat"
  [ "$(printf '%s\n' "$nonces" | sort -u | wc -l | tr -d ' ')" = "$n" ] || fail "each chunk has its own nonce"
  [ "$(posts | sed -n 2p)" = "$(posts | sed -n 3p)" ] || fail "the resent chunk is byte-identical"
  [ -z "$(ls "$W_HOME/state/discord-bridge/outbox/replies")" ] || fail "the restart finishes the message"
  pass "restart: a crash after Discord accepted a chunk resends only that chunk with the same nonce, then finishes"
}

test_ledger_events_reach_operations_once() {
  local st="$DTMP/ledger/home/state" ops
  discord_world ledger
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  : > "$W_HOME/config/fleet-ledger"
  bridge tick
  printf '%s\n' 'needs-decision [key=pick]: choose option A or B' 'blocked: waiting on credentials' \
    'failed: build broke' 'done: shipped the fix' 'working: still going' 'paused: waiting on CI' > "$st/t1.status"
  FM_HOME="$W_HOME" "$LEDGER" capture || fail "ledger capture failed"
  FM_HOME="$W_HOME" "$LEDGER" pr_ready t1 https://github.com/o/r/pull/7 || fail "pr_ready failed"
  FM_HOME="$W_HOME" "$LEDGER" merged t1 pr https://github.com/o/r/pull/7 || fail "merged failed"
  FM_HOME="$W_HOME" "$LEDGER" merged t2 local || fail "local merge failed"
  bridge tick
  ops=$(posts "$D_OPS")
  [ "$(post_count "$D_OPS")" = 7 ] || fail "four status events, PR ready, and two merges: $ops"
  [ "$(post_count "$W_REPLIES")" = 0 ] || fail "an operational event leaked into the replies channel"
  assert_contains "$ops" "Decision needed - t1: choose option A or B" "the decision is named"
  assert_contains "$ops" "Blocked - t1" "the blocker is named"
  assert_contains "$ops" "Failed - t1" "the failure is named"
  assert_contains "$ops" "Done - t1: shipped the fix" "the completion is named"
  assert_contains "$ops" "PR ready for review - t1: https://github.com/o/r/pull/7" "PR readiness is named"
  assert_contains "$ops" "Merged - t1: https://github.com/o/r/pull/7" "the merge is named"
  assert_contains "$ops" "Merged locally - t2" "the local landing is named"
  assert_not_contains "$ops" "still going" "routine progress never notifies"
  [ "$(posts "$D_OPS" | jq -s 'map(select(.mentions == ["'"$D_OWNER"'"])) | length')" = 3 ] \
    || fail "only decisions, blockers, and failures mention the owner"
  assert_contains "$(posts "$D_OPS" | sed -n 1p | jq -r .content)" "a Discord message cannot approve or answer this" "a decision notice says it is not an approval channel"
  tail -n 3 "$st/fleet-ledger.jsonl" > "$st/repeat.jsonl"
  cat "$st/repeat.jsonl" >> "$st/fleet-ledger.jsonl"
  bridge tick
  [ "$(post_count "$D_OPS")" = 7 ] || fail "a repeated ledger record must not notify again"
  printf '%s\n' 'not json' '{"v":2,"event":"task.status","task":"t1","state":"done","text":"x"}' \
    '{"v":1,"event":"task.unknown","task":"t9"}' '{"v":1,"event":"task.pr_ready","task":"t1","pr":"javascript:x"}' >> "$st/fleet-ledger.jsonl"
  printf '{"v":1,"event":"task.merged"' >> "$st/fleet-ledger.jsonl"
  bridge tick || fail "malformed records must not break the pass"
  [ "$(post_count "$D_OPS")" = 7 ] || fail "malformed or unsupported records notify nothing"
  assert_grep '"event": "ledger-malformed"' "$W_HOME/state/discord-bridge/bridge.log" "malformed records are logged"
  pass "ledger: decision, blocker, failure, completion, PR ready, and merges reach operations once; duplicates and malformed records are safe"
}

test_watcher_health_alerts_once_and_recovers() {
  local stale
  discord_world health
  D_EXTRA_ENV=(DISCORD_WATCHER_STALE_SECS=60)
  fresh_beat
  bridge tick
  [ "$(post_count)" = 0 ] || fail "a fresh watcher beat raises nothing"
  stale=$(( $(date +%s) - 900 ))
  python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$W_HOME/state/.last-watcher-beat" "$stale"
  bridge tick; bridge tick
  [ "$(post_count "$D_OPS")" = 1 ] || fail "a stale watcher alerts exactly once"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "Monitoring stopped: Firstmate's watcher has not run for 15 minutes" "the alert names the stopped monitoring"
  fresh_beat
  bridge tick; bridge tick
  [ "$(post_count "$D_OPS")" = 2 ] || fail "recovery is announced once"
  assert_contains "$(posts "$D_OPS" | tail -n 1 | jq -r .content)" "Monitoring resumed" "the recovery is named"
  [ "$(post_count "$W_REPLIES")" = 0 ] || fail "health notices never go to replies"
  pass "health: a stale watcher alerts once in operations, then one recovery notice"
}

test_mirror_gap_is_reported() {
  local m
  discord_world gap
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge tick
  mirror_say "one"
  bridge tick
  mirror_say "two"; mirror_say "three"; mirror_say "four"
  m="$W_HOME/state/.host-mirror.jsonl"
  jq -c 'select(.seq != 2 and .seq != 3)' "$m" > "$m.new" && mv "$m.new" "$m"
  bridge tick
  assert_contains "$(posts "$W_REPLIES" | jq -r .content)" "up to 2 earlier mirror entries left the local mirror" "a sequence gap is reported"
  [ "$(posts "$W_REPLIES" | tail -n 1 | jq -r .content)" = four ] || fail "delivery resumes after the gap"
  pass "mirror gap: entries that left the mirror unread are counted, never claimed delivered"
}

test_configuration_refuses_closed() {
  local out rc
  discord_world config
  D_EXTRA_ENV=(DISCORD_OPERATIONS_CHANNEL_ID=)
  out=$(bridge check-config 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing operations channel must be refused"
  assert_contains "$out" "DISCORD_OPERATIONS_CHANNEL_ID must be a Discord id" "the problem is named"
  bridge tick 2>/dev/null && fail "the bridge must not run without both channels"
  D_EXTRA_ENV=(DISCORD_OPERATIONS_CHANNEL_ID="$D_REPLIES")
  out=$(bridge check-config 2>&1) && fail "one channel for both categories must be refused"
  assert_contains "$out" "must differ" "the shared channel is named"
  D_EXTRA_ENV=(DISCORD_COMMAND_CHANNEL_IDS="$D_CMD,$D_OPS")
  out=$(bridge check-config 2>&1) && fail "the operations channel must never accept commands"
  assert_contains "$out" "the operations channel must not accept commands" "the problem is named"
  D_EXTRA_ENV=(DISCORD_COMMAND_CHANNEL_IDS="$D_CMD 300000000000000033")
  out=$(bridge check-config 2>&1) && fail "a space-separated channel list must be refused, not read as one channel"
  assert_contains "$out" "DISCORD_COMMAND_CHANNEL_IDS entries must be Discord ids" "the malformed list is named"
  D_EXTRA_ENV=(DISCORD_COMMAND_CHANNEL_IDS=)
  bridge check-config >/dev/null 2>&1 && fail "no command channel must be refused"
  D_EXTRA_ENV=(DISCORD_OWNER_USER_ID=)
  bridge check-config >/dev/null 2>&1 && fail "a missing owner must be refused"
  assert_not_contains "$out" "$D_TOKEN" "diagnostics never print the token"
  [ "$(post_count)" = 0 ] || fail "a refused configuration sends nothing"
  assert_absent "$W_HOME/state/discord-bridge" "a refused configuration creates no bridge state"
  pass "configuration: missing, shared, or malformed channels, operations as a command channel, and a missing owner refuse before anything runs"
}

fork_run_tests
