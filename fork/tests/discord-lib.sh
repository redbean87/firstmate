#!/usr/bin/env bash
# Shared fixtures for the fork Discord bridge tests (fork/tests/fm-fork-discord-*.test.sh).
#
# Every world is an isolated Firstmate home under a test tmproot with a fake
# Discord REST API (fork/tests/discord-fake-curl) first on PATH; nothing
# reaches a real Discord server. Mirror writes go through the REAL upstream
# bin/fm-host-mirror.sh from a fixture primary checkout, exactly as upstream's
# tests/fm-host-mirror.test.sh drives it, and ledger writes through the REAL
# bin/fm-fleet-ledger.sh.
# shellcheck disable=SC2034 # the constants below are read by the test files

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/fork/discord/fm-discord-bridge.py"
SENDER="$ROOT/fork/discord/fm-discord-send.sh"
REPLY_HOOK="$ROOT/fork/discord/fm-discord-reply-hook.sh"
EXT_PACKAGE="$ROOT/fork/discord/extension"
MIRROR="$ROOT/bin/fm-host-mirror.sh"
LEDGER="$ROOT/bin/fm-fleet-ledger.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"
D_GUILD=100000000000000001
D_OWNER=200000000000000002
D_CMD=300000000000000003
D_REPLIES=310000000000000031
D_OPS=400000000000000004
D_OTHER_USER=500000000000000005
D_TOKEN=fixture-bot-token-not-real-0123456789

DTMP=$(fm_test_tmproot fm-fork-discord)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
# Source ownership claims are per user, not per home: without this, a real
# registered source of the same id on this machine owns the fixture's claim.
export FM_PROCEVENT_CLAIM_ROOT="$DTMP/procevent-claims"

# A primary checkout (git, AGENTS.md, this repo's bin) for the mirror writer
# and the reply hook's primary-scope check.
PRIMARY_ROOT="$DTMP/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"
D_FAKEBIN="$DTMP/fakebin"
mkdir -p "$D_FAKEBIN"
cp "$ROOT/fork/tests/discord-fake-curl" "$D_FAKEBIN/curl"
chmod +x "$D_FAKEBIN/curl"
ln -s /bin/bash "$D_FAKEBIN/claude"

# discord_world <name> [replies-channel]: sets W_HOME and W_FAKE.
discord_world() {
  W_HOME="$DTMP/$1/home"
  W_FAKE="$DTMP/$1/fake"
  W_REPLIES=${2:-$D_REPLIES}
  mkdir -p "$W_HOME/state" "$W_HOME/config" "$W_HOME/data" "$W_FAKE/get"
  : > "$W_HOME/config/supervision-host"
  : > "$W_FAKE/requests.jsonl"
  local ch
  for ch in "$D_CMD" "$W_REPLIES" "$D_OPS"; do
    printf '{"id":"%s","guild_id":"%s"}\n' "$ch" "$D_GUILD" > "$W_FAKE/get/_channels_$ch.json"
  done
  printf '{"id":"600000000000000006","bot":true}\n' > "$W_FAKE/get/_users_@me.json"
}

# bridge <args...>: run the bridge in the current world with fixture config.
bridge() { bridge_env python3 "$BRIDGE" "$@"; }

# bridge_env <command...>: run <command> with the world's fixture config.
# With D_EXEC=1 the calling (background) shell is replaced by the command, so
# $! is the command's own pid.
bridge_env() {
  local runner=env
  [ "${D_EXEC:-0}" != 1 ] || runner="exec env"
  $runner FM_HOME="$W_HOME" PATH="$D_FAKEBIN:$PATH" FAKE_DISCORD_DIR="$W_FAKE" FM_DISCORD_BRIDGE_QUIET=1 \
    DISCORD_ENV_FILE="$W_HOME/.env-absent" DISCORD_BOT_TOKEN="$D_TOKEN" DISCORD_GUILD_ID="$D_GUILD" \
    DISCORD_OWNER_USER_ID="$D_OWNER" DISCORD_COMMAND_CHANNEL_IDS="$D_CMD" \
    DISCORD_REPLIES_CHANNEL_ID="$W_REPLIES" DISCORD_OPERATIONS_CHANNEL_ID="$D_OPS" \
    DISCORD_API_BASE="https://discord.test/api/v10" ${D_EXTRA_ENV[@]+"${D_EXTRA_ENV[@]}"} \
    "$@"
}
D_EXTRA_ENV=()

# posts [channel]: one JSON line per POSTed message, optionally for one channel.
posts() {
  jq -c --arg ch "${1:-}" 'select(.method == "POST")
    | select($ch == "" or .path == "/channels/\($ch)/messages")
    | {channel: (.path | split("/")[2]), content: .body.content, nonce: .body.nonce,
       reply_to: (.body.message_reference.message_id // null),
       mentions: (.body.allowed_mentions.users // [])}' "$W_FAKE/requests.jsonl"
}
post_count() { posts "${1:-}" | wc -l | tr -d ' '; }

# as_session <script>: run <script> as the lock-owning primary session of
# W_HOME, under the fake harness whose pid it records as the session lock.
as_session() {
  # shellcheck disable=SC2016 # expanded by the session shell, not here
  FM_HOME="$W_HOME" PRIMARY_ROOT="$PRIMARY_ROOT" MIRROR="$MIRROR" REPLY_HOOK="$REPLY_HOOK" "$D_FAKEBIN/claude" -c \
    'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; '"$1"
}

# mirror_say <text>: one Claude Stop payload through the REAL mirror writer.
mirror_say() {
  # shellcheck disable=SC2016 # expanded by the session shell, not here
  D_TEXT=$1 as_session 'jq -cn --arg t "$D_TEXT" "{hook_event_name: \"Stop\", prompt_id: \"p1\", last_assistant_message: \$t}" \
    | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$MIRROR" hook claude'
}

hook_stop() {  # <payload>: one Stop payload through the reply hook as the session
  # shellcheck disable=SC2016 # expanded by the session shell, not here
  D_PAYLOAD=$1 as_session 'printf "%s" "$D_PAYLOAD" | FM_ROOT_OVERRIDE="$PRIMARY_ROOT" "$REPLY_HOOK"'
}

stop_payload() {  # <text> [continuation]
  jq -cn --arg t "$1" --argjson c "${2:-false}" \
    '{hook_event_name: "Stop", session_id: "sess-1", prompt_id: "prompt-1", stop_hook_active: $c, last_assistant_message: $t}'
}

# owner_event <id> <content> [channel] [author]: a gateway MESSAGE_CREATE file.
owner_event() {
  local file="$DTMP/event-$1.json"
  jq -n --arg id "$1" --arg c "$2" --arg ch "${3:-$D_CMD}" --arg a "${4:-$D_OWNER}" --arg g "$D_GUILD" \
    '{t: "MESSAGE_CREATE", d: {id: $id, guild_id: $g, channel_id: $ch, type: 0, content: $c,
      timestamp: "2026-10-22T12:00:00Z", author: {id: $a, username: "owner"}}}' > "$file"
  printf '%s\n' "$file"
}

fresh_beat() { touch "$W_HOME/state/.last-watcher-beat"; }
