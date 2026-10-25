#!/usr/bin/env bash
# Pre-activation paths of the fork Discord bridge: the real long-running run
# loop, gateway disconnect/reconnect through a fake transport
# (fork/tests/discord-gateway-harness drives the real Gateway class with only
# the websocket replaced), a full outbox, paginated history recovery, and
# thirty-day cleanup. Fixture homes and a fake Discord REST API only; no real
# socket, server, or credential.
set -u
# shellcheck source=fork/tests/discord-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/discord-lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

QUIET_HEALTH=(DISCORD_WATCHER_STALE_SECS=999999999)
HARNESS="$ROOT/fork/tests/discord-gateway-harness"
BOT=600000000000000006
RUN_PID=

pending_ids() { find "$W_HOME/state/discord-bridge/inbox/pending" -type f -name '*.json' 2>/dev/null | sed 's#.*/##; s#\.json$##' | sort | tr '\n' ' '; }
bridge_log() { cat "$W_HOME/state/discord-bridge/bridge.log" 2>/dev/null; }

wait_for() {  # <seconds> <command...>: poll until the command succeeds
  local limit=$1 i=0
  shift
  while [ "$i" -lt $((limit * 10)) ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_run() {  # [extra env...]: the real run loop in the background, gateway off
  D_EXEC=1 bridge run --no-gateway 2>"$W_HOME/run.err" &
  RUN_PID=$!
  # Each test runs in its own subshell; a failing test must not orphan the loop.
  trap '[ -z "$RUN_PID" ] || kill -KILL "$RUN_PID" 2>/dev/null' EXIT
  wait_for 15 grep -q '"event": "bridge-started"' "$W_HOME/state/discord-bridge/bridge.log" \
    || fail "the run loop did not start: $(cat "$W_HOME/run.err")"
}

stop_run() {  # -> exit status of the run loop
  local rc
  kill -TERM "$RUN_PID" 2>/dev/null
  wait "$RUN_PID"; rc=$?
  RUN_PID=
  return "$rc"
}

trap '[ -z "$RUN_PID" ] || kill -KILL "$RUN_PID" 2>/dev/null; fm_test_cleanup' EXIT

posts_at_least() { [ "$(post_count)" -ge "$1" ]; }
replies_outbox_empty() { [ -z "$(find "$W_HOME/state/discord-bridge/outbox/replies" -name '*.json')" ]; }
prune_runs_at_least() { [ "$(grep -c '"event": "prune"' "$W_HOME/state/discord-bridge/bridge.log")" -ge "$1" ]; }

# --- A: the long-running loop ----------------------------------------------

test_run_loop_delivers_idles_and_stops_without_losing_work() {
  local out rc cpu entry
  discord_world runloop
  D_EXTRA_ENV=(DISCORD_OPERATIONS_CHANNEL_ID=)
  out=$(bridge run --no-gateway 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the run loop must refuse an invalid configuration"
  assert_contains "$out" "DISCORD_OPERATIONS_CHANNEL_ID must be a Discord id" "the refusal names the problem"
  assert_absent "$W_HOME/state/discord-bridge" "a refused run creates no state"

  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_QUIET=0)
  fresh_beat
  : > "$W_HOME/config/fleet-ledger"
  start_run
  wait_for 10 test -f "$W_HOME/state/discord-bridge/cursors/mirror.json" || fail "the loop never initialized its cursors"
  out=$(bridge run --no-gateway 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a second loop must be refused"
  assert_contains "$out" "already running" "the second loop names the running one"
  mirror_say "live reply from the loop"
  printf 'blocked: waiting on the build host\n' > "$W_HOME/state/t1.status"
  FM_HOME="$W_HOME" "$LEDGER" capture
  wait_for 15 posts_at_least 2 \
    || fail "the loop must deliver the reply and the ledger event: $(posts)"
  [ "$(posts "$W_REPLIES" | jq -r .content)" = "live reply from the loop" ] || fail "the reply is delivered to replies"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "Blocked - t1: waiting on the build host" "the ledger event is delivered to operations"
  [ "$(jq -r .seq "$W_HOME/state/discord-bridge/cursors/mirror.json")" = 1 ] || fail "the mirror cursor records the delivered entry"

  cpu=$(ps -o time= -p "$RUN_PID" | tr -d ' ')
  sleep 3
  [ "$(post_count)" = 2 ] || fail "an idle loop sends nothing"
  python3 - "$cpu" "$(ps -o time= -p "$RUN_PID" | tr -d ' ')" <<'PY' || fail "an idle loop must not spin"
import sys
def secs(t):
    parts = [float(p) for p in t.replace("-", ":").split(":")]
    total = 0.0
    for p in parts:
        total = total * 60 + p
    return total
sys.exit(0 if secs(sys.argv[2]) - secs(sys.argv[1]) < 1.0 else 1)
PY

  printf 'fail\nfail\nfail\nfail\nfail\nfail\n' > "$W_FAKE/responses"
  mirror_say "pending at shutdown"
  wait_for 15 grep -q '"event": "outbox-retry"' "$W_HOME/state/discord-bridge/bridge.log" || fail "the failing send was not retried"
  stop_run; rc=$?
  expect_code 0 "$rc" "SIGTERM ends the loop cleanly"
  entry=$(find "$W_HOME/state/discord-bridge/outbox/replies" -name '*.json')
  [ -n "$entry" ] || fail "pending work survives shutdown"
  [ "$(jq -r '.chunks[0]' "$entry")" = "pending at shutdown" ] || fail "the pending entry is intact"
  : > "$W_FAKE/responses"
  start_run
  wait_for 20 replies_outbox_empty \
    || fail "the restarted loop must deliver the pending reply"
  stop_run
  [ "$(posts "$W_REPLIES" | jq -r .content | grep -c 'pending at shutdown')" -ge 1 ] || fail "the pending reply was delivered"
  assert_no_grep "$D_TOKEN" "$W_HOME/state/discord-bridge/bridge.log" "the log never carries the token"
  assert_no_grep "$D_TOKEN" "$W_HOME/run.err" "stderr never carries the token"
  assert_no_grep "live reply from the loop" "$W_HOME/state/discord-bridge/bridge.log" "the log never carries message text"
  pass "run loop: refuses bad configuration, one instance, delivers replies and ledger events, idles without spinning, SIGTERM keeps pending work, restart delivers it"
}

# --- B: gateway disconnect and reconnect -----------------------------------

hello='{"op":10,"d":{"heartbeat_interval":100000000}}'
ready() { jq -cn --arg s "$1" --arg b "$BOT" '{op: 0, s: 1, t: "READY", d: {session_id: $s, resume_gateway_url: "wss://resume.test", user: {id: $b}}}'; }
msg() { jq -c --argjson s "$2" '{op: 0, s: $s, t: "MESSAGE_CREATE", d: .d}' "$(owner_event "$1" "${3:-gateway message $1}")"; }
canned_page() { printf '%s\n' "${2:-[]}" > "$W_FAKE/get/_channels_${D_CMD}_messages_after_${1}_limit_100.json"; }
set_cursor() {
  mkdir -p "$W_HOME/state/discord-bridge/cursors"
  printf '{"after":"%s"}\n' "$1" > "$W_HOME/state/discord-bridge/cursors/inbound-$D_CMD.json"
}
run_harness() {  # <scenario-file>
  bridge_env python3 "$HARNESS" "$BRIDGE" "$1"
}

test_gateway_reconnects_resumes_and_keeps_state() {
  local scen report before after
  discord_world gateway
  set_cursor 750000000000000000
  canned_page 750000000000000000 "$(jq -cn --arg o "$D_OWNER" '[{id: "750000000000000001", type: 0, content: "missed", author: {id: $o}}]')"
  for c in 750000000000000001 760000000000000001 760000000000000002 760000000000000003; do canned_page "$c"; done
  mkdir -p "$W_HOME/state/discord-bridge/outbox/replies"
  printf '{"schema":"firstmate.discord-outbox.v1","event_id":"pre","chunks":["x"],"next_chunk":0,"attempts":0,"next_attempt_at":0}' \
    > "$W_HOME/state/discord-bridge/outbox/replies/00000000000000000001-pre.json"
  before=$(shasum "$W_HOME/state/discord-bridge/outbox/replies/00000000000000000001-pre.json")
  scen="$DTMP/gw-scenario.json"
  jq -n --argjson h "$hello" --argjson r1 "$(ready sess-a)" --argjson r2 "$(ready sess-b)" \
    --argjson m1 "$(msg 760000000000000001 2)" --argjson m1b "$(msg 760000000000000001 3)" \
    --argjson m2 "$(msg 760000000000000002 5)" --argjson m3 "$(msg 760000000000000003 2)" \
    '{connections: [
      [$h, $r1, "pause", $m1, $m1b, "drop"],
      [$h, {op: 0, s: 4, t: "RESUMED", d: {}}, $m2, {op: 7, d: null}],
      [$h, {op: 9, d: false}],
      [$h, $r2, "pause", $m3, "pause"]]}' > "$scen"
  report=$(run_harness "$scen") || fail "the harness failed"
  [ "$(printf '%s' "$report" | jq -c .ops)" = '[2,6,6,2]' ] || fail "identify, resume after a drop, resume after op 7, fresh identify after op 9: $report"
  [ "$(printf '%s' "$report" | jq -c .resume_sessions)" = '["sess-a","sess-a"]' ] || fail "resumes carry the READY session"
  [ "$(printf '%s' "$report" | jq -r '.targets[1]')" = "resume.test/?v=10&encoding=json" ] || fail "a resume uses the resume URL with the gateway query"
  [ "$(printf '%s' "$report" | jq -r '.targets[3]')" = "gateway.discord.gg/?v=10&encoding=json" ] || fail "an invalid session reconnects to the main gateway"
  printf '%s' "$report" | jq -e '[.waits[] | numbers] | length == 3 and (.[0] >= 5 and .[0] <= 7) and (.[1] >= 5 and .[1] <= 7) and (.[2] >= 10 and .[2] <= 12)' >/dev/null \
    || fail "backoff resets after READY/RESUMED and doubles across a failed attempt: $(printf '%s' "$report" | jq -c .waits)"
  [ "$(printf '%s' "$report" | jq -r .down_since)" = null ] || fail "a READY clears the disconnected state"
  [ "$(pending_ids)" = "750000000000000001 760000000000000001 760000000000000002 760000000000000003 " ] \
    || fail "gateway and recovered messages are each in the inbox once: $(pending_ids)"
  assert_grep '"event": "inbound-duplicate"' "$W_HOME/state/discord-bridge/bridge.log" "a repeated gateway delivery is a duplicate"
  after=$(shasum "$W_HOME/state/discord-bridge/outbox/replies/00000000000000000001-pre.json")
  [ "$before" = "$after" ] || fail "a disconnect never touches pending outbound work"
  pass "gateway (fake transport): resume after drop and op 7, fresh identify after op 9, backoff reset/doubling, duplicates once, recovery on READY, outbox untouched"
}

test_gateway_backoff_doubles_while_refused() {
  local scen report
  discord_world gwbackoff
  set_cursor 770000000000000000
  canned_page 770000000000000000
  scen="$DTMP/gw-backoff.json"
  jq -n --argjson h "$hello" --argjson r "$(ready sess-c)" '{connections: ["refuse", "refuse", "refuse", "refuse", [$h, $r, "pause"]]}' > "$scen"
  report=$(run_harness "$scen") || fail "the harness failed"
  printf '%s' "$report" | jq -e '[.waits[] | numbers] as $w | ($w | length) == 4
    and ($w[0] >= 5 and $w[0] <= 7) and ($w[1] >= 10 and $w[1] <= 12) and ($w[2] >= 20 and $w[2] <= 22) and ($w[3] >= 40 and $w[3] <= 42)' >/dev/null \
    || fail "backoff doubles while connections are refused: $(printf '%s' "$report" | jq -c .waits)"
  [ "$(printf '%s' "$report" | jq -r .down_since)" = null ] || fail "the eventual READY ends the outage"
  pass "gateway (fake transport): refused connections back off 5, 10, 20, 40 seconds, then recover"
}

test_gateway_outage_alerts_once_and_recovers() {
  local scen
  discord_world gwhealth
  scen="$DTMP/gw-health.json"
  jq -n '{health: [[1000, 1100], [1000, 1301], [1000, 1500], [1000, 9000], [null, 9100], [null, 9200], [5000, 5400]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(post_count "$D_OPS")" = 3 ] || fail "one outage notice, one restored notice, one new outage notice: $(posts "$D_OPS")"
  assert_contains "$(posts "$D_OPS" | sed -n 1p | jq -r .content)" "Discord connection lost for 5 minutes" "the first notice names the outage"
  assert_contains "$(posts "$D_OPS" | sed -n 2p | jq -r .content)" "Discord connection restored." "recovery is announced"
  [ "$(post_count "$W_REPLIES")" = 0 ] || fail "connection notices never go to replies"
  pass "gateway health: an outage over 5 minutes alerts once however long it lasts, recovery is announced once, a new outage alerts again"
}

test_gateway_recovery_retries_after_a_failed_history_fetch() {
  local scen
  discord_world gwretry
  set_cursor 780000000000000000
  canned_page 780000000000000000 "$(jq -cn --arg o "$D_OWNER" '[{id: "780000000000000001", type: 0, content: "missed", author: {id: $o}}]')"
  canned_page 780000000000000001
  printf '1\n' > "$W_FAKE/get-fail"
  scen="$DTMP/gw-retry.json"
  jq -n --argjson h "$hello" --argjson r "$(ready sess-d)" '{connections: [[$h, $r, "pause", "pause"]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(pending_ids)" = "780000000000000001 " ] || fail "a history fetch that failed after READY must be retried: $(pending_ids)"
  pass "gateway recovery: a failed history fetch after READY is retried until the missed message is recovered"
}

refusals_of() { grep '"event": "inbound-refused"' "$W_HOME/state/discord-bridge/bridge.log" | grep -c "\"message_id\": \"$1\""; }
cursor_after() { jq -r .after "$W_HOME/state/discord-bridge/cursors/inbound-$D_CMD.json"; }

test_a_final_live_refusal_is_not_read_again_after_restart() {
  local scen echo_id=790000000000000005 gap_id=790000000000000009 echo_page
  discord_world gwrefused
  set_cursor 790000000000000000
  canned_page 790000000000000000
  # The bot's own reply arrives live after this session's recovery is done.
  scen="$DTMP/gw-refused.json"
  jq -n --argjson h "$hello" --argjson r "$(ready sess-e)" \
    --argjson e "$(jq -c '.d.author = {id: "'"$BOT"'", bot: true}' <(msg "$echo_id" 2 "queue line 0001 (1/2)"))" \
    '{connections: [[$h, $r, "pause", $e, "pause"]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(refusals_of "$echo_id")" = 1 ] || fail "the live echo is refused once"
  [ "$(cursor_after)" = "$echo_id" ] || fail "a final live refusal moves the cursor past it: $(cursor_after)"
  [ -z "$(pending_ids)" ] || fail "a refusal creates no inbox work"
  assert_absent "$W_HOME/state/discord-bridge/inbound-seen/$echo_id" "a refusal claims no duplicate marker"
  [ -z "$(ls "$W_HOME/state/discord-bridge/inbox/batches")" ] || fail "a refusal creates no batch"

  # Restart: history after the old cursor would hold the echo again.
  echo_page=$(jq -cn --arg b "$BOT" --arg i "$echo_id" '[{id: $i, type: 0, content: "queue line 0001 (1/2)", author: {id: $b, bot: true}}]')
  canned_page 790000000000000000 "$echo_page"
  canned_page "$echo_id"
  bridge recover-history || fail "recovery after restart failed"
  [ "$(refusals_of "$echo_id")" = 1 ] || fail "the next recovery does not read the refused echo again"
  [ "$(cursor_after)" = "$echo_id" ] || fail "the cursor stays past the echo"

  # While a session's recovery is still failing, a live refusal must not move
  # the cursor past messages that recovery has not read yet.
  set_cursor 790000000000000006
  canned_page 790000000000000006 "$(jq -cn --arg o "$D_OWNER" '[{id: "790000000000000007", type: 0, content: "missed during the outage", author: {id: $o}}]')"
  canned_page 790000000000000007
  printf '1000\n' > "$W_FAKE/get-fail"
  jq -n --argjson h "$hello" --argjson r "$(ready sess-f)" \
    --argjson e "$(jq -c '.d.author = {id: "'"$BOT"'", bot: true}' <(msg "$gap_id" 2 "echo during recovery"))" \
    '{connections: [[$h, $r, $e, "pause"]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(refusals_of "$gap_id")" = 1 ] || fail "the echo during recovery is refused"
  [ "$(cursor_after)" = 790000000000000006 ] || fail "a live refusal during unfinished recovery leaves the cursor: $(cursor_after)"
  : > "$W_FAKE/get-fail"
  bridge recover-history || fail "the later recovery failed"
  [ "$(pending_ids)" = "790000000000000007 " ] || fail "the message missed during the outage is still recovered: $(pending_ids)"

  # Incomplete data and other channels never move the cursor.
  jq 'del(.d.author)' "$(owner_event 790000000000000020 "no author")" > "$DTMP/event-noauthor.json"
  [ "$(bridge ingest "$DTMP/event-noauthor.json")" = malformed ] || fail "a message without an author is malformed"
  jq 'del(.d.content) | .d.author = {id: "'"$BOT"'", bot: true}' "$(owner_event 790000000000000021 "x")" > "$DTMP/event-nocontent.json"
  [ "$(bridge ingest "$DTMP/event-nocontent.json")" = bot ] || fail "a bot message is refused"
  [ "$(bridge ingest "$(owner_event 790000000000000022 "decoy" 320000000000000032)")" = wrong-channel ] || fail "the decoy is refused"
  [ "$(cursor_after)" = 790000000000000007 ] || fail "malformed, incomplete, and other-channel refusals leave the cursor: $(cursor_after)"
  assert_absent "$W_HOME/state/discord-bridge/cursors/inbound-320000000000000032.json" "no cursor is created for a refused channel"
  pass "history cursor: a final live refusal is passed once recovery is caught up and is not read again after restart; during unfinished recovery, or for malformed, incomplete, or other-channel messages, the cursor stays"
}

page_for() { printf '%s\n' "$3" > "$W_FAKE/get/_channels_$1_messages_after_$2_limit_100.json"; }  # <channel> <after> <json>
owner_msgs() {  # <id>...: a history page of owner messages
  local id out='[]'
  for id in "$@"; do
    out=$(jq -c --arg i "$id" --arg o "$D_OWNER" '. + [{id: $i, type: 0, content: "history \($i)", author: {id: $o}}]' <<<"$out")
  done
  printf '%s\n' "$out"
}
log_count() { grep "\"event\": \"$1\"" "$W_HOME/state/discord-bridge/bridge.log" | grep -c "${2:-}"; }  # <event> [message id]

test_a_live_message_during_failing_recovery_does_not_skip_missed_history() {
  local scen missed=791000000000000001 live=791000000000000002
  discord_world gwlivegap
  set_cursor 791000000000000000
  page_for "$D_CMD" 791000000000000000 "$(owner_msgs "$missed" "$live")"
  printf '100000\n' > "$W_FAKE/get-fail"
  scen="$DTMP/gw-livegap.json"
  # History fails while the live connection works; an owner message arrives;
  # then history comes back.
  jq -n --argjson h "$hello" --argjson r "$(ready sess-g)" --argjson m "$(msg "$live" 2)" \
    '{connections: [[$h, $r, $m, "pause", {harness: "write", file: "get-fail", text: "0"}, "pause", "pause"]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(pending_ids)" = "$missed $live " ] || fail "the message missed during the outage is recovered: $(pending_ids)"
  [ "$(log_count inbound-accepted "$live")" = 1 ] || fail "the live message is accepted once"
  [ "$(log_count inbound-duplicate "$live")" = 1 ] || fail "recovery reads the live message again only as a duplicate"
  [ "$(log_count inbound-accepted "$missed")" = 1 ] || fail "the missed message is accepted once"
  [ "$(cursor_after)" = "$live" ] || fail "the cursor ends past both: $(cursor_after)"
  [ "$(log_count history-caught-up)" = 1 ] || fail "failed fetches never log caught up; the successful pass logs it once"
  pass "issue A: a live owner message accepted while history fails leaves the cursor, so the missed message is recovered and the live one is recorded once"
}

test_a_failed_inbox_write_during_recovery_holds_the_cursor() {
  local m1=792000000000000001 m2=792000000000000002 m3=792000000000000003 rc
  discord_world histwrite
  set_cursor 792000000000000000
  page_for "$D_CMD" 792000000000000000 "$(owner_msgs "$m1" "$m2" "$m3")"
  mkdir -p "$W_HOME/state/discord-bridge/inbox/pending/$m2.json"  # m2's record cannot be written
  bridge recover-history; rc=$?
  [ "$rc" -ne 0 ] || fail "recovery reports that it did not finish"
  [ "$(pending_ids)" = "$m1 " ] || fail "nothing after the failed write is processed: $(pending_ids)"
  [ "$(cursor_after)" = "$m1" ] || fail "the cursor stops before the failed message: $(cursor_after)"
  assert_absent "$W_HOME/state/discord-bridge/inbound-seen/$m2" "the failed message keeps no duplicate marker"
  [ "$(log_count history-held "$m2")" = 1 ] || fail "the hold is logged"
  rmdir "$W_HOME/state/discord-bridge/inbox/pending/$m2.json"
  page_for "$D_CMD" "$m1" "$(owner_msgs "$m2" "$m3")"
  bridge recover-history || fail "the next recovery finishes"
  [ "$(pending_ids)" = "$m1 $m2 $m3 " ] || fail "the failed message and the ones after it are recovered: $(pending_ids)"
  for m in "$m1" "$m2" "$m3"; do
    [ "$(log_count inbound-accepted "$m")" = 1 ] || fail "$m is accepted exactly once"
  done
  [ "$(cursor_after)" = "$m3" ] || fail "the cursor ends past all three"
  pass "issue B: an inbox write failure during recovery holds the cursor before that message; the next recovery takes it and the ones after it, once each"
}

test_a_ready_during_recovery_runs_another_pass() {
  local scen second=300000000000000033 late=793000000000000005
  discord_world gwrepass
  D_EXTRA_ENV=(DISCORD_COMMAND_CHANNEL_IDS="$D_CMD,$second")
  set_cursor 793000000000000000
  printf '{"after":"793000000000000000"}\n' > "$W_HOME/state/discord-bridge/cursors/inbound-$second.json"
  page_for "$D_CMD" 793000000000000000 '[]'
  page_for "$second" 793000000000000000 '[]'
  printf '_channels_%s_' "$second" > "$W_FAKE/get-hold"  # hold the pass inside the second channel
  scen="$DTMP/gw-repass.json"
  # Channels are read in order, so the second channel's request (held) means
  # the first pass has finished the first channel; a message then reaches
  # the first channel's history during a new outage.
  jq -n --argjson h "$hello" --argjson r1 "$(ready sess-h)" --argjson r2 "$(ready sess-i)" \
    --arg page "get/_channels_${D_CMD}_messages_after_793000000000000000_limit_100.json" --arg late "$(owner_msgs "$late")" \
    --arg held "/channels/$second/messages" --arg log "$W_HOME/state/discord-bridge/bridge.log" \
    '{connections: [
      [$h, $r1, {harness: "await", file: "requests.jsonl", text: $held},
       {harness: "write", file: $page, text: $late}, "drop"],
      [$h, $r2, {harness: "remove", file: "get-hold"}, {harness: "await", file: $log, text: "history-caught-up"}]]}' > "$scen"
  run_harness "$scen" >/dev/null || fail "the harness failed"
  [ "$(pending_ids)" = "$late " ] || fail "the follow-up pass recovers the message the first pass could not see: $(pending_ids)"
  [ "$(log_count history-repass)" = 1 ] || fail "the READY during the pass asks for exactly one more pass"
  [ "$(log_count inbound-accepted "$late")" = 1 ] || fail "it is accepted once"
  [ "$(cursor_after)" = "$late" ] || fail "the first channel's cursor ends past it"
  [ "$(log_count history-caught-up)" = 1 ] || fail "caught up is logged once, after the follow-up pass"
  [ "$(grep -n 'history-repass' "$W_HOME/state/discord-bridge/bridge.log" | cut -d: -f1)" \
    -lt "$(grep -n 'history-caught-up' "$W_HOME/state/discord-bridge/bridge.log" | cut -d: -f1)" ] \
    || fail "caught up is logged only after the follow-up pass"
  pass "issue C: a READY during a running recovery pass makes it pass again from the durable cursors, so nothing posted meanwhile is skipped; caught up is logged once, after it"
}

test_a_failed_live_write_makes_recovery_take_it() {
  local scen m1=794000000000000001 m2=794000000000000002 report log
  discord_world gwlivewrite
  set_cursor 794000000000000000
  page_for "$D_CMD" 794000000000000000 '[]'
  log="$W_HOME/state/discord-bridge/bridge.log"
  mkdir -p "$W_HOME/state/discord-bridge/inbox/pending/$m1.json"  # m1's record cannot be written
  scen="$DTMP/gw-livewrite.json"
  # Caught up; m1 arrives live and its write fails; m2 arrives live and is
  # written; then the fault clears.
  jq -n --argjson h "$hello" --argjson r "$(ready sess-j)" --argjson a "$(msg "$m1" 2)" --argjson b "$(msg "$m2" 3)" \
    --arg log "$log" --arg page "get/_channels_${D_CMD}_messages_after_794000000000000000_limit_100.json" \
    --arg both "$(owner_msgs "$m1" "$m2")" --arg pending "$W_HOME/state/discord-bridge/inbox/pending/$m1.json" \
    '{connections: [[$h, $r, {harness: "await", file: $log, text: "history-caught-up"},
      {harness: "write", file: $page, text: $both}, $a, {harness: "await", file: $log, text: "history-held"}, $b,
      {harness: "remove", file: $pending},
      {harness: "await", file: $log, text: "history-caught-up", count: 2}]]}' > "$scen"
  report=$(run_harness "$scen") || fail "the harness failed (the failed message was never recovered?)"
  [ "$(pending_ids)" = "$m1 $m2 " ] || fail "the message whose live write failed is recovered: $(pending_ids)"
  [ "$(log_count inbound-write-failed "$m1")" -ge 1 ] || fail "the live write failure is logged"
  [ "$(log_count inbound-accepted "$m1")" = 1 ] || fail "m1 is accepted once, by recovery"
  [ "$(log_count inbound-accepted "$m2")" = 1 ] || fail "m2 is accepted once, live"
  [ "$(log_count inbound-duplicate "$m2")" = 1 ] || fail "recovery reads m2 again only as a duplicate"
  [ "$(cursor_after)" = "$m2" ] || fail "the cursor ends past both: $(cursor_after)"
  [ "$(log_count history-caught-up)" = 2 ] || fail "caught up is logged at start and after the recovery, never after a held pass"
  printf '%s' "$report" | jq -e '[.waits[] | numbers] | length > 0 and all(. >= 5)' >/dev/null \
    || fail "a held recovery backs off rather than spinning: $(printf '%s' "$report" | jq -c .waits)"
  pass "issue D: a live write failure makes recovery take that message from history; later live messages leave the cursor until it is recovered; once each; retries back off"
}

# --- C: outbox capacity ----------------------------------------------------

test_full_outbox_holds_reports_and_resumes() {
  local i
  discord_world full
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OUTBOX_MAX=2 FM_DISCORD_BRIDGE_NOW=1000)
  fresh_beat
  bridge tick
  for i in 1 2 3 4; do mirror_say "reply $i"; done
  printf 'fail\n' > "$W_FAKE/responses"
  bridge tick
  [ "$(find "$W_HOME/state/discord-bridge/outbox/replies" -name '*.json' | wc -l | tr -d ' ')" = 2 ] || fail "the outbox holds at its limit"
  [ "$(jq -r .seq "$W_HOME/state/discord-bridge/cursors/mirror.json")" -lt 4 ] || fail "the source is not consumed past what the outbox holds"
  assert_grep '"event": "outbox-full"' "$W_HOME/state/discord-bridge/bridge.log" "a full outbox is logged"
  assert_contains "$(posts "$D_OPS" | jq -r .content)" "Replies backlog is full" "a full replies outbox is reported in operations"
  assert_not_contains "$(posts "$D_OPS" | jq -r .content)" "reply 3" "the report carries no message text"
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OUTBOX_MAX=2 FM_DISCORD_BRIDGE_NOW=1001); bridge tick
  [ "$(grep -c '"event": "outbox-full"' "$W_HOME/state/discord-bridge/bridge.log")" = 1 ] || fail "one full episode is reported once"
  for i in 1 2 3; do D_EXTRA_ENV=("${QUIET_HEALTH[@]}" DISCORD_OUTBOX_MAX=2 FM_DISCORD_BRIDGE_NOW=$((1100 + i))); bridge tick; done
  [ "$(posts "$W_REPLIES" | jq -r .content | grep -v '^$' | sort -u | tr '\n' ',')" = "reply 1,reply 2,reply 3,reply 4," ] \
    || fail "every reply is delivered once capacity returns: $(posts "$W_REPLIES" | jq -r .content)"
  [ "$(posts "$W_REPLIES" | jq -r .content | uniq | tr '\n' ',')" = "reply 1,reply 2,reply 3,reply 4," ] || fail "order holds across the full episode"
  assert_grep '"event": "outbox-capacity-restored"' "$W_HOME/state/discord-bridge/bridge.log" "the end of the episode is logged"
  pass "full outbox: holds at the limit without discarding, pauses the source, reports once without text, resumes in order"
}

# --- D: history pagination -------------------------------------------------

page_json() {  # <cursor-base> <first-id> <count>: one shuffled page; noise is fixed per message id
  python3 - "$1" "$2" "$3" "$D_OWNER" "$D_OTHER_USER" <<'PY2'
import json, random, sys
base, first, count, owner, other = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
msgs = []
for mid in range(first, first + count):
    kind = (mid - base - 1) % 10
    m = {"id": str(mid), "type": 0, "content": "history %d" % mid, "author": {"id": owner}}
    if kind == 3:
        m["author"] = {"id": other}
    if kind == 5:
        m["author"] = {"id": "600000000000000006", "bot": True}
    if kind == 7:
        m["webhook_id"] = "1"
    if kind == 8:
        m["content"] = "x" * 4001
    msgs.append(m)
random.Random(first).shuffle(msgs)
print(json.dumps(msgs))
PY2
}

eligible_between() {  # <cursor-base> <last-offset>: the eligible ids base+1..base+last, one per line
  python3 -c 'import sys; b,n=int(sys.argv[1]),int(sys.argv[2]); print("\n".join(str(b+i) for i in range(1,n+1) if (i-1)%10 not in (3,5,7,8)))' "$1" "$2"
}

inbox_ids() { find "$W_HOME/state/discord-bridge/inbox/pending" -name '*.json' | sed 's#.*/##; s#\.json$##' | sort; }

test_history_pages_through_more_than_100_messages_safely() {
  local base=790000000000000000 rc
  discord_world pages
  bridge check-config >/dev/null || fail "fixture configuration incomplete"
  set_cursor "$base"
  canned_page "$base" "$(page_json "$base" $((base + 1)) 100)"
  printf '1\n' > "$W_FAKE/get-fail"
  bridge recover-history 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an API failure during recovery must be reported"
  [ -z "$(inbox_ids)" ] || fail "a failed fetch accepts nothing"
  bridge recover-history 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "a missing next page is a failure, not a silent end"
  [ "$(jq -r .after "$W_HOME/state/discord-bridge/cursors/inbound-$D_CMD.json")" = $((base + 100)) ] \
    || fail "progress is kept page by page"
  [ "$(inbox_ids)" = "$(eligible_between "$base" 100)" ] || fail "page one yields exactly its eligible owner messages"
  # Page two overlaps page one and repeats one id in place of another; page
  # three overlaps page two and ends the history.
  canned_page $((base + 100)) "$(page_json "$base" $((base + 95)) 100 | jq -c '.[1] = .[0]')"
  canned_page $((base + 194)) "$(page_json "$base" $((base + 190)) 30)"
  canned_page $((base + 219)) '[]'
  bridge recover-history || fail "recovery must finish once the pages are available"
  [ "$(jq -r .after "$W_HOME/state/discord-bridge/cursors/inbound-$D_CMD.json")" = $((base + 219)) ] || fail "the cursor ends at the newest processed message"
  [ "$(inbox_ids)" = "$(eligible_between "$base" 219)" ] || fail "exactly the eligible owner messages are in the inbox, once each"
  bridge recover-history || fail "a repeated recovery must succeed"
  [ "$(inbox_ids)" = "$(eligible_between "$base" 219)" ] || fail "a repeated recovery adds nothing"
  pass "history: 219 messages over three shuffled pages with overlap, a repeated id, an empty page, and API failures; only eligible owner messages, once"
}

test_history_for_a_newly_added_channel_starts_now() {
  local second=330000000000000033
  discord_world newchannel
  D_EXTRA_ENV=(DISCORD_COMMAND_CHANNEL_IDS="$D_CMD,$second")
  printf '{"id":"%s","guild_id":"%s"}\n' "$second" "$D_GUILD" > "$W_FAKE/get/_channels_$second.json"
  set_cursor 800000000000000000
  canned_page 800000000000000000
  mkdir -p "$W_HOME/state/discord-bridge/cursors"
  printf '{"after":"100000000000000000"}\n' > "$W_HOME/state/discord-bridge/cursors/first-start.json"
  printf '%s\n' "$(jq -cn --arg o "$D_OWNER" '[{id: "100000000000000500", type: 0, content: "months-old message", author: {id: $o}}]')" \
    > "$W_FAKE/get/_channels_${second}_messages_after_100000000000000000_limit_100.json"
  bridge recover-history >/dev/null 2>&1
  [ -z "$(pending_ids)" ] || fail "a channel added later must not import its old history: $(pending_ids)"
  pass "history: a command channel added later starts at the time it was added, not at the bridge's first start"
}

# --- E: retention ----------------------------------------------------------

age_file() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2])*86400; os.utime(sys.argv[1],(t,t))' "$1" "$2"; }

test_cleanup_prunes_only_expired_records() {
  local b d
  discord_world prune
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  fresh_beat
  bridge check-config >/dev/null
  bridge tick
  b="$W_HOME/state/discord-bridge"
  for d in inbound-seen events inbox/captured inbox/claimed; do
    printf 'x' > "$b/$d/old-record"; age_file "$b/$d/old-record" 31
    printf 'x' > "$b/$d/recent-record"; age_file "$b/$d/recent-record" 29
  done
  for d in inbox/pending outbox/replies outbox/operations failed inbox/batches cursors; do
    printf '{"schema":"firstmate.discord-outbox.v1","event_id":"kept-%s","kind":"reply","chunks":["kept"],"next_chunk":0,"attempts":1,"next_attempt_at":99999999999,"sent_ids":[]}' \
      "${d//\//-}" > "$b/$d/kept-old.json"
    age_file "$b/$d/kept-old.json" 90
  done
  mkdir -p "$b/events/stuck-dir/inner"; age_file "$b/events/stuck-dir" 40
  start_run
  wait_for 15 grep -q '"event": "prune"' "$b/bridge.log" || fail "cleanup must run and report: $(cat "$W_HOME/run.err")"
  stop_run
  for d in inbound-seen events inbox/captured inbox/claimed; do
    assert_absent "$b/$d/old-record" "a record older than 30 days in $d is removed"
    assert_present "$b/$d/recent-record" "a record younger than 30 days in $d is kept"
  done
  for d in inbox/pending outbox/replies outbox/operations failed inbox/batches cursors; do
    assert_present "$b/$d/kept-old.json" "$d is never pruned by age"
  done
  assert_grep '"errors": 1' "$b/bridge.log" "a record that cannot be removed is reported"
  assert_present "$b/events/stuck-dir" "an unremovable record is left in place"
  start_run
  wait_for 15 prune_runs_at_least 2 || fail "cleanup runs again after a restart"
  stop_run
  assert_present "$b/inbound-seen/recent-record" "a repeated cleanup is idempotent"
  pass "cleanup: removes only 30-day-old duplicate, delivered, captured, and claimed records; inbox, outbox, failed, batches, cursors kept; errors reported; restart-safe"
}

fork_run_tests
