#!/usr/bin/env bash
# Claude Code Stop hook for the fork's Discord bridge (fork/discord/README).
#
# Records the turn's complete final assistant message (the Stop payload's
# last_assistant_message) as one spool event for the bridge to deliver to the
# replies channel. Installed only into the untracked local Claude settings by
# `fm-discord-bridge.py install-hook`; the tracked .claude/settings.json is
# never touched.
#
# Inert unless the bridge runs with DISCORD_REPLIES_SOURCE=hook, which creates
# state/discord-bridge/replies-spool/. Like upstream bin/fm-host-mirror.sh's
# writer, it records only a Stop event from this home's lock-owning primary
# session in a genuine primary checkout, so a worker, a second read-only
# session, or another harness loading these settings writes nothing.
#
# Always exits 0 and prints nothing: a Stop hook's output can steer the
# harness, and this hook must never block or alter a turn. A stop another
# hook blocks fires Stop again for the same prompt; each firing is its own
# event, marked as a continuation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPOOL="$STATE/discord-bridge/replies-spool"
TEXT_MAX=100000

record() {
  local payload lock seq tries=0 tmp
  [ -d "$SPOOL" ] && [ ! -L "$SPOOL" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  payload=$(cat) || return 0
  [ -n "$payload" ] || return 0
  [ "$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')" = Stop ] || return 0
  [ -n "$(printf '%s' "$payload" | jq -r '.last_assistant_message // "" | gsub("^\\s+|\\s+$"; "")')" ] || return 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/../../bin/fm-hook-host-lib.sh"
  fm_hook_payload_is_foreign_host "$payload" && return 0
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/../../bin/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/../../bin/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE" || return 0
  umask 077
  lock="$SPOOL/.lock"
  until mkdir "$lock" 2>/dev/null; do
    # A lock left by a killed hook is broken once it is clearly older than
    # any live holder (each holds it for well under a second).
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 0
    sleep 0.1
  done
  seq=$(cat "$SPOOL/.seq" 2>/dev/null || printf 0)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  tmp="$SPOOL/.tmp-$$"
  if printf '%s' "$payload" | jq -c --argjson seq "$seq" --argjson at "$(date +%s)" --argjson max "$TEXT_MAX" '
      (.last_assistant_message | tostring) as $t
      | {schema: "firstmate.discord-reply-event.v1", seq: $seq, captured_at: $at,
         session_id: (.session_id // "" | tostring), prompt_id: (.prompt_id // "" | tostring),
         continuation: (.stop_hook_active == true), text_length: ($t | length),
         text: (if ($t | length) > $max
                then $t[0:$max] + "\n\n[Shortened by the Discord reply hook: \(($t | length) - $max) characters not shown.]"
                else $t end)}' > "$tmp" 2>/dev/null \
    && printf '%s\n' "$seq" > "$SPOOL/.seq" \
    && mv -f "$tmp" "$SPOOL/$(printf '%012d' "$seq").json"; then
    :
  else
    rm -f "$tmp"
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

record >/dev/null 2>&1
exit 0
