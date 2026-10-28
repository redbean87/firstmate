#!/usr/bin/env bash
# Outbound half of the fork Discord bridge: replies from the REAL upstream
# mirror writer, from the fork's full-length Stop hook, and from the fork's
# Pi settled-reply extension (fm-pi-reply-mirror.ts driven through
# discord-pi-ext-driver), operational events from the REAL fleet-ledger
# writer, the watcher-health notices, and the durable outbox's ordering,
# splitting, retry, permanent-failure, crash, and deduplication behavior, all
# against a fake Discord REST API. The Pi extension cases need node; they
# skip individually without it.
set -u
# shellcheck source=fork/tests/discord-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/discord-lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

QUIET_HEALTH=(DISCORD_WATCHER_STALE_SECS=999999999)

# lock_owned_by_test: state/.lock names this test shell, an ancestor of the
# node driver pi_scenario spawns - the same lock-owning-session shape the
# Claude hook's as_session fixture produces.
lock_owned_by_test() {
  printf '%s\n' "$$" > "$W_HOME/state/.lock"
}

# scenario <steps-json> [session-file]: the JSON the driver replays.
scenario() {
  jq -cn --arg sf "${2:-/tmp/pi-session-1.jsonl}" --argjson steps "$1" \
    '{session_file: $sf, steps: $steps}'
}

user_entry() { jq -cn --arg t "$1" '{type: "message", message: {role: "user", content: [{type: "text", text: $t}]}}'; }
assistant_entry() {  # <text> [toolcall] - a toolCall part makes it a loop step
  jq -cn --arg t "$1" --argjson tc "${2:-false}" \
    '{type: "message", message: {role: "assistant",
      content: (if $tc then [{type: "text", text: $t}, {type: "toolCall", toolName: "bash", args: {}}]
               else [{type: "text", text: $t}] end)}}'
}
tool_result_entry() { jq -cn '{type: "message", message: {role: "toolResult", content: [{type: "text", text: "ok"}]}}'; }
custom_entry() { jq -cn --arg t "$1" '{type: "message", message: {role: "custom", customType: "fm-processing", content: $t}}'; }

spool_files() { find "$(pi_spool)" -name '[0-9]*.json' 2>/dev/null | sort; }
spool_count() { spool_files | grep -c . || true; }
spool_text() { jq -r .text "$(spool_files | sed -n "$1p")"; }


# Pi extension cases replay transcript fixtures through the real extension in
# node; without node the bridge-driven Pi cases (straight spool events) still
# run, and only the extension-driver cases are skipped.
pi_driver_available() {
  command -v node >/dev/null 2>&1 || { pass "extension-driver case skipped: node absent"; return 1; }
  return 0
}



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

test_ledger_rate_limit_summarizes_held_back_notices() {
  local st="$DTMP/ledgerrate/home/state" ops summary t
  discord_world ledgerrate
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OPS_RATE_MAX=2 DISCORD_OPS_RATE_WINDOW_SECS=600 FM_DISCORD_BRIDGE_NOW=5000)
  fresh_beat
  : > "$W_HOME/config/fleet-ledger"
  bridge tick
  for t in t1 t2 t3 t4; do
    FM_HOME="$W_HOME" "$LEDGER" pr_ready "$t" "https://github.com/o/r/pull/${t#t}" || fail "pr_ready $t failed"
  done
  printf 'failed: build broke\n' > "$st/t5.status"
  FM_HOME="$W_HOME" "$LEDGER" capture || fail "ledger capture failed"
  bridge tick; bridge tick
  ops=$(posts "$D_OPS" | jq -r .content)
  [ "$(post_count "$D_OPS")" = 2 ] || fail "only DISCORD_OPS_RATE_MAX notices post inside one window: $ops"
  assert_not_contains "$ops" "t3" "a notice over the limit is held back"
  assert_grep '"event": "ledger-rate-limited"' "$W_HOME/state/discord-bridge/bridge.log" "held-back notices are logged"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OPS_RATE_MAX=2 DISCORD_OPS_RATE_WINDOW_SECS=600 FM_DISCORD_BRIDGE_NOW=5700)
  bridge tick; bridge tick
  [ "$(post_count "$D_OPS")" = 3 ] || fail "the end of the window posts exactly one summary"
  summary=$(posts "$D_OPS" | tail -n 1)
  assert_contains "$(jq -r .content <<<"$summary")" "3 more operational notices" "the summary counts every held-back notice"
  assert_contains "$(jq -r .content <<<"$summary")" "(1 needing attention)" "the summary counts attention notices"
  assert_contains "$(jq -r .content <<<"$summary")" "Tasks: t3, t4, t5" "the summary names the held-back tasks"
  [ "$(jq -c .mentions <<<"$summary")" = "[\"$D_OWNER\"]" ] || fail "a summary holding an attention notice mentions the owner"
  FM_HOME="$W_HOME" "$LEDGER" pr_ready t6 https://github.com/o/r/pull/6 || fail "pr_ready t6 failed"
  bridge tick
  [ "$(post_count "$D_OPS")" = 4 ] || fail "a fresh window posts normally again"
  assert_contains "$(posts "$D_OPS" | tail -n 1 | jq -r .content)" "PR ready for review - t6" "the next notice is the event itself"
  pass "ledger rate limit: notices over the window cap are held back, logged, and summarized once with counts, tasks, and an owner mention"
}

test_transient_failures_end_after_max_attempts() {
  discord_world exhaust
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_MAX_ATTEMPTS=3 FM_DISCORD_BRIDGE_NOW=1000)
  fresh_beat
  bridge tick
  printf '503\n503\n503\n' > "$W_FAKE/responses"
  mirror_say "never delivered"
  bridge tick
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_MAX_ATTEMPTS=3 FM_DISCORD_BRIDGE_NOW=1010); bridge tick
  [ -z "$(ls "$W_HOME/state/discord-bridge/failed")" ] || fail "two attempts are still under the limit"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_MAX_ATTEMPTS=3 FM_DISCORD_BRIDGE_NOW=1030); bridge tick
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "the third attempt is the last"
  [ "$(find "$W_HOME/state/discord-bridge/failed" -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail "an exhausted message is kept for diagnosis"
  [ -z "$(ls "$W_HOME/state/discord-bridge/outbox/replies")" ] || fail "an exhausted message no longer holds the queue"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "gave up after 3 attempts, last http 503" "the give-up is reported in operations"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_MAX_ATTEMPTS=3 FM_DISCORD_BRIDGE_NOW=2000); bridge tick
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "an exhausted message is never retried"
  pass "bounded retries: transient failures stop after DISCORD_MAX_ATTEMPTS, are kept in failed/, and reported once"
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

test_settled_extraction_final_reply_only() {
  pi_driver_available || return 0
  pi_world piextract
  lock_owned_by_test
  # A plain reply, then a tool-loop turn whose final assistant text must win.
  pi_scenario "$(scenario '[
    {"event": "session_start", "entries": []},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "first question")"',
      '"$(assistant_entry "the first reply")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 1 ] || fail "one settled reply must record exactly one event: $(ls "$(pi_spool)")"
  [ "$(spool_text 1)" = "the first reply" ] || fail "the settled reply text must be complete"
  [ "$(jq -r .schema "$(spool_files | sed -n 1p)")" = firstmate.discord-reply-event.v1 ] \
    || fail "the event carries the existing schema"
  [ "$(jq -r .session_id "$(spool_files | sed -n 1p)")" = "pi-session-1.jsonl" ] \
    || fail "session_id is the session file basename"
  [ "$(jq -r .continuation "$(spool_files | sed -n 1p)")" = false ] || fail "a first reply is not a continuation"

  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "a tool question")"',
      '"$(assistant_entry "working on it" true)"',
      '"$(tool_result_entry)"',
      '"$(assistant_entry "the final answer")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 2 ] || fail "a tool-loop turn records only its final reply: $(ls "$(pi_spool)")"
  [ "$(spool_text 2)" = "the final answer" ] || fail "the final text after a tool loop wins"
  [ "$(jq -r .seq "$(spool_files | sed -n 2p)")" = 2 ] \
    || fail "the per-feed seq counter rises monotonically"

  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "tool only")"',
      '"$(assistant_entry "loop step" true)"'
    ]}
  ]')" || fail "driver failed"
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "blank")"',
      '"$(assistant_entry "   ")"'
    ]}
  ]')" || fail "driver failed"
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "aborted": true, "entries": [
      '"$(user_entry "aborted")"',
      '"$(assistant_entry "half a reply")"'
    ]}
  ]')" || fail "driver failed"
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "with custom")"',
      '"$(custom_entry "{\"seq\":1}")"',
      '"$(assistant_entry "the reply anyway")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 3 ] || fail "toolCall-only, blank, and aborted settles must record nothing: $(ls "$(pi_spool)")"
  [ "$(spool_text 3)" = "the reply anyway" ] || fail "a branch-processing custom entry is not mistaken for MAIN text"
  assert_absent "$W_HOME/state/.host-mirror.jsonl" "the Pi extension never writes the upstream host mirror"
  # Over the hook's 100000-char ceiling: capped with a stated note, and
  # text_length keeps the ORIGINAL size so the cap cannot hide the true one.
  local huge
  huge=$(python3 -c 'print("word " * 30000)')
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "huge")"',
      '"$(assistant_entry "$huge")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 4 ] || fail "the long reply must still record"
  [ "$(jq -r .text_length "$(spool_files | sed -n 4p)")" = "${#huge}" ] \
    || fail "text_length must keep the original length"
  assert_contains "$(jq -r .text "$(spool_files | sed -n 4p)")" "characters not shown" "the cap states what it removed"
  assert_contains "$(jq -r .text "$(spool_files | sed -n 4p)")" "$(printf '%s' "$huge" | tail -c 50 | sed 's/["\\]/\\&/g')" "the cap keeps the reply's tail"
  pass "extraction: only the settled final assistant text records, full length, one event per settle, toolCall-only/blank/aborted skipped, custom entries ignored, long replies capped with original text_length, no host-mirror write"
}

test_operational_and_background_replies_are_preserved() {
  pi_driver_available || return 0
  pi_world piop
  lock_owned_by_test
  # Captain parity decision: replies to operational and background wakes are
  # MAIN replies too and must reach Discord unfiltered.
  pi_scenario "$(scenario '[
    {"event": "session_start", "entries": []},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "FIRSTMATE wake: fm-task-7 is blocked on credentials")"',
      '"$(assistant_entry "Captain, the worker needs the API token; see the report.")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 1 ] || fail "an operational-wake reply must be recorded"
  assert_contains "$(spool_text 1)" "needs the API token" "the operational reply's text is preserved"
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "<task-notification> task fm-x done")"',
      '"$(assistant_entry "The fix landed; PR is up for review.")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 2 ] || fail "a background-notification reply must be recorded"
  bridge tick || fail "delivery pass failed"
  [ "$(post_count "$W_REPLIES")" = 2 ] || fail "both operational replies must reach the replies channel: $(posts)"
  assert_contains "$(posts "$W_REPLIES" | sed -n 1p | jq -r .content)" "needs the API token" "the wake reply is delivered verbatim"
  pass "parity: replies to operational wakes and background notifications are captured and delivered unfiltered"
}

test_continuation_marks_second_settle_of_one_turn() {
  pi_driver_available || return 0
  pi_world picont
  lock_owned_by_test
  # One driver run = one Pi process: the extension's instance state persists
  # across settles exactly as inside a live session.
  pi_scenario "$(scenario '[
    {"event": "session_start", "entries": []},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "blocked stop")"',
      '"$(assistant_entry "first part")"'
    ]},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "blocked stop")"',
      '"$(assistant_entry "first part")"',
      '"$(assistant_entry "second part")"'
    ]},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "blocked stop")"',
      '"$(assistant_entry "first part")"',
      '"$(assistant_entry "second part")"',
      '"$(user_entry "and now something else")"',
      '"$(assistant_entry "a fresh reply")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 3 ] || fail "three settles record three events: $(ls "$(pi_spool)")"
  # No new user message: the second settle continues the same turn (the
  # hook's stop_hook_active case); a new user message starts a fresh reply.
  [ "$(jq -r .continuation "$(spool_files | sed -n 2p)")" = true ] \
    || fail "a second settle with no new user message is a continuation"
  [ "$(jq -r .continuation "$(spool_files | sed -n 3p)")" = false ] || fail "a new user message is a fresh reply"
  bridge tick || fail "delivery pass failed"
  [ "$(posts "$W_REPLIES" | sed -n 2p | jq -r .content)" = $'(continued)\nsecond part' ] \
    || fail "a continuation is delivered marked (continued): $(posts "$W_REPLIES")"
  pass "continuation: a second settle of one turn is marked (continued), a new user message starts fresh"
}

test_session_start_replaces_stale_state() {
  pi_driver_available || return 0
  pi_world pistate
  lock_owned_by_test
  pi_scenario "$(scenario '[
    {"event": "session_start", "entries": []},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "old session question")"',
      '"$(assistant_entry "old session reply")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 1 ] || fail "the first session's reply must be recorded"
  # A /resume restores the transcript; the new generation must treat it as
  # already recorded and never replay it, and a stale continuation anchor
  # must not survive into the new session.
  pi_scenario "$(scenario '[
    {"event": "session_start", "entries": [
      '"$(user_entry "old session question")"',
      '"$(assistant_entry "old session reply")"'
    ]},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "old session question")"',
      '"$(assistant_entry "old session reply")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 1 ] || fail "a restored transcript must not replay old replies: $(ls "$(pi_spool)")"
  pi_scenario "$(scenario '[
    {"event": "agent_settled", "entries": [
      '"$(user_entry "old session question")"',
      '"$(assistant_entry "old session reply")"',
      '"$(user_entry "new question after resume")"',
      '"$(assistant_entry "new reply after resume")"'
    ]}
  ]')" || fail "driver failed"
  [ "$(spool_count)" = 2 ] || fail "a post-resume reply must be recorded"
  [ "$(jq -r .continuation "$(spool_files | sed -n 2p)")" = false ] \
    || fail "the new generation must not treat the post-resume reply as a continuation of the old session"
  [ "$(spool_text 2)" = "new reply after resume" ] || fail "the post-resume text is complete"
  pass "lifecycle: session_start re-derives state; a restored transcript is never replayed and stale continuation anchors do not survive"
}

test_gates_block_foreign_and_worktree_writes() {
  pi_driver_available || return 0
  pi_world pigate
  local wt_steps
  wt_steps="$(scenario '[
    {"event": "session_start", "entries": []},
    {"event": "agent_settled", "entries": [
      '"$(user_entry "question")"',
      '"$(assistant_entry "must not be recorded")"'
    ]}
  ]')"
  # No lock at all: a session that never acquired the fleet lock writes nothing.
  pi_scenario "$wt_steps" || fail "driver failed"
  [ "$(spool_count)" = 0 ] || fail "without the fleet lock the extension must be inert"
  # A lock held by another live process: not this session's ancestry.
  sh -c "exec sleep 30" & local other=$!
  printf '%s\n' "$other" > "$W_HOME/state/.lock"
  pi_scenario "$wt_steps" || fail "driver failed"
  [ "$(spool_count)" = 0 ] || fail "a lock owned by another process must refuse the write"
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  # A linked task worktree is never a primary checkout.
  git -C "$PRIMARY_ROOT" worktree add --quiet -b fm/pi-gate "$DTMP/pi-gate-wt" 2>/dev/null \
    || fail "fixture worktree creation failed"
  lock_owned_by_test
  printf '%s' "$wt_steps" > "$DTMP/pi-gate-scenario.json"
  FM_HOME="$W_HOME" FM_ROOT_OVERRIDE="$DTMP/pi-gate-wt" \
    node "$PI_EXT_DRIVER" "$PI_REPLY_MIRROR" "$DTMP/pi-gate-scenario.json" || fail "driver failed"
  [ "$(spool_count)" = 0 ] || fail "a worktree checkout must refuse the write"
  git -C "$PRIMARY_ROOT" worktree remove --force "$DTMP/pi-gate-wt" 2>/dev/null || true
  # The genuine primary checkout with the lock-owning session records again.
  pi_scenario "$wt_steps" || fail "driver failed"
  [ "$(spool_count)" = 1 ] || fail "the lock-owning session in a primary checkout must record"
  pass "gates: no lock, a foreign lock holder, and a linked worktree all refuse spool writes; the primary session records"
}

test_bridge_delivers_pi_replies_in_both_modes() {
  pi_driver_available || return 0
  local mode spool
  for mode in mirror hook; do
    pi_world "pi-$mode"
    D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
    [ "$mode" = hook ] && D_EXTRA_ENV+=("DISCORD_REPLIES_SOURCE=hook")
    fresh_beat
    lock_owned_by_test
    pi_scenario "$(scenario '[
      {"event": "session_start", "entries": []},
      {"event": "agent_settled", "entries": [
        '"$(user_entry "q1")"',
        '"$(assistant_entry "a complete reply")"'
      ]}
    ]')" || fail "driver failed"
    bridge tick || fail "$mode delivery pass failed"
    [ "$(post_count "$W_REPLIES")" = 1 ] || fail "the Pi reply must reach the replies channel in $mode mode: $(posts)"
    [ "$(posts "$W_REPLIES" | jq -r .content)" = "a complete reply" ] || fail "the $mode reply text is intact"
    [ -z "$(spool_files)" ] || fail "a delivered Pi spool event is removed"
    bridge tick
    [ "$(post_count)" = 1 ] || fail "a delivered Pi reply is never sent again in $mode mode"
    if [ -f "$W_HOME/state/.host-mirror.jsonl" ]; then
      fail "Pi delivery must never touch the host mirror in $mode mode"
    fi
    spool="$W_HOME/state/discord-bridge/replies-spool"
    if [ "$mode" = mirror ]; then
      [ ! -d "$spool" ] || [ -z "$(find "$spool" -name '*.json' 2>/dev/null)" ] \
        || fail "mirror mode must not route Pi events through the hook spool"
    fi
  done
  pass "bridge: Pi spool events deliver in both mirror and hook mode, once, without touching the host mirror or the hook spool"
}

test_pi_and_mirror_sources_interleave_without_duplicates() {
  local before
  pi_world piinter
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  lock_owned_by_test
  bridge tick
  pi_text_event 1 "pi reply one"
  mirror_say "mirror reply one"
  pi_text_event 2 "pi reply two"
  bridge tick
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "both sources must deliver once each: $(posts)"
  [ "$(posts "$W_REPLIES" | jq -r .content | sort | tr '\n' '|')" = "mirror reply one|pi reply one|pi reply two|" ] \
    || fail "each source's text arrives exactly once: $(posts)"
  before=$(post_count)
  # Replaying a Pi event the outbox already knows must not double-post.
  pi_text_event 2 "pi reply two"
  bridge tick
  [ "$(post_count)" = "$before" ] || fail "a replayed Pi event the outbox knows must be suppressed: $(posts)"
  # The mirror cursor must be untouched by Pi traffic.
  [ "$(jq -r .seq "$W_HOME/state/discord-bridge/cursors/mirror.json")" = 1 ] \
    || fail "Pi events must not move the mirror cursor"
  pass "interleave: Pi and mirror sources deliver once each in per-source order; replay is suppressed by the durable outbox; the mirror cursor is untouched"
}

test_restart_resumes_half_consumed_spool() {
  pi_world pirestart
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  pi_text_event 1 "first pi reply"
  pi_text_event 2 "second pi reply"
  # Saturate the replies outbox so the second event stays in the spool, as
  # after a crash between enqueue and unlink.
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OUTBOX_MAX=1 FM_DISCORD_BRIDGE_NOW=1000)
  printf '429 600\n' > "$W_FAKE/responses"
  bridge tick
  [ "$(spool_count)" = 1 ] || fail "an event the full outbox cannot accept must stay in the spool"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "backlog is full" "the full episode is reported once"
  # A fresh bridge process (each `bridge tick` is one stateless pass) drains
  # the held event once capacity returns: the pass that frees the outbox
  # delivers the held head, and the next pass picks up the freed spool file.
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OUTBOX_MAX=1 FM_DISCORD_BRIDGE_NOW=1700)
  bridge tick
  [ "$(spool_count)" = 1 ] || fail "the retry pass delivers the held head first"
  bridge tick
  [ "$(spool_count)" = 0 ] || fail "the held event must drain once capacity returns"
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "one 429 attempt plus two sends: $(posts)"
  [ "$(posts "$W_REPLIES" | tail -n 2 | jq -r .content | tr '\n' '|')" = "first pi reply|second pi reply|" ] \
    || fail "the drained events arrive in order"
  [ -z "$(ls "$W_HOME/state/discord-bridge/outbox/replies")" ] || fail "the outbox empties after delivery"
  bridge tick
  [ "$(post_count "$W_REPLIES")" = 3 ] || fail "a restart never re-sends delivered Pi replies: $(posts "$W_REPLIES")"
  pass "restart: a spool held by a full outbox survives, drains in order after capacity returns, and is never double-sent"
}

test_invalid_pi_events_are_quarantined() {
  pi_world piinvalid
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  pi_text_event 1 "the good reply"
  mkdir -p "$(pi_spool)"
  printf '{"schema":"other.v1","seq":2,"text":"bad"}\n' > "$(pi_spool)/000000000002.json"
  printf 'not json at all\n' > "$(pi_spool)/000000000003.json"
  bridge tick || fail "malformed events must not break the pass"
  [ "$(post_count "$W_REPLIES")" = 1 ] || fail "only the valid event is delivered: $(posts)"
  [ "$(posts "$W_REPLIES" | jq -r .content)" = "the good reply" ] || fail "the valid event's text is intact"
  [ "$(find "$W_HOME/state/discord-bridge/failed" -name 'pi-spool-*.json' | wc -l | tr -d ' ')" = 2 ] \
    || fail "both invalid events are kept for diagnosis with the pi-spool- prefix"
  assert_grep '"feed": "pi"' "$W_HOME/state/discord-bridge/bridge.log" "the pi feed names itself in the log"
  pass "quarantine: malformed Pi events move to failed/ with the pi-spool- prefix; the valid event still delivers"
}

test_fake_transport_has_no_network_path() {
  # Every post in this suite lands in the fake's requests.jsonl because
  # bridge_env puts the fake curl first on PATH and points DISCORD_API_BASE
  # at https://discord.test; assert that invariant holds for this file's own
  # worlds and that no case here starts the live gateway.
  pi_world pitransport
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  pi_text_event 1 "transport proof"
  bridge tick || fail "delivery pass failed"
  [ "$(post_count)" = 1 ] || fail "the post must land in the fake log"
  assert_grep '"path": "/channels/' "$W_FAKE/requests.jsonl" "the fake REST log recorded the post"
  case "$(bridge_env env | grep '^DISCORD_API_BASE=' || true)" in
    *discord.test*) : ;;
    *) fail "the fixture must point the API base at the fake host" ;;
  esac
  grep -q 'FAKE_DISCORD_DIR' "$D_FAKEBIN/curl" || fail "the fake curl must be the one PATH resolves"
  pass "transport: every case posts only through the fake REST log; the fake host is pinned and no gateway runs"
}

fork_run_tests
