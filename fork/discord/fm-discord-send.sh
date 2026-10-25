#!/usr/bin/env bash
# Discord REST sender for the fork's Discord bridge (fork/discord/README).
#
# Ported from the earlier core-edit implementation (origin/main
# bin/fm-discord-send.sh). The splitting and the single authenticated call are
# unchanged in substance; delivery retry moved to the bridge's durable outbox,
# so this script makes exactly one attempt per call and reports the outcome
# for the bridge to schedule.
#
# Usage:
#   fm-discord-send.sh split [--budget <units>] < text
#       Print the message as a JSON array of chunks. A message that fits stays
#       one unnumbered chunk; a longer one gets " (k/n)" suffixes, with the
#       budget reduced so the suffix never pushes a chunk over the limit.
#   fm-discord-send.sh post-one <channel-id> --nonce <nonce> [--reply-to <message-id>]
#       [--mention <user-id>] --text-file <path>
#       Post one prepared chunk once. Mentions are suppressed except the named
#       user; a reply never pings its author. The nonce is sent with
#       enforce_nonce so Discord drops a repeat of the same nonce.
#   fm-discord-send.sh get <api-path> --out <path>
#       One authenticated GET; the JSON body goes to <path>.
#
# Exit status of post-one and get:
#   0  success; post-one prints "sent <message-id>"
#   2  permanent refusal (HTTP 400-499 other than 429); prints "http <code>"
#   3  rate limited; prints "retry-after <seconds>"
#   4  transient: HTTP 5xx, transport failure, or no response; prints "http <code>"
#   1  local error (missing tool, token, or argument)
# Output never contains the token or the message text.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=fork/discord/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

die() { printf 'fm-discord-send: %s\n' "$1" >&2; exit "${2:-1}"; }
id_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
command -v jq >/dev/null 2>&1 || die "jq not found"

cmd_split() {
  local budget=$DISCORD_CHUNK_BUDGET text chunks n est pass digits b
  if [ "${1:-}" = --budget ]; then budget=${2:-}; fi
  case "$budget" in ''|*[!0-9]*) die "invalid budget" 2 ;; esac
  text=$(cat)
  chunks=$(printf '%s' "$text" | discord_chunk_text "$budget") || die "chunking failed"
  n=$(printf '%s' "$chunks" | jq 'length') || exit 1
  if [ "$n" -gt 1 ]; then
    est=$n pass=0
    while [ "$pass" -lt 3 ]; do
      digits=${#est}
      b=$((budget - 4 - 2 * digits - 1))
      [ "$b" -ge 1 ] || b=1
      chunks=$(printf '%s' "$text" | discord_chunk_text "$b") || die "chunking failed"
      n=$(printf '%s' "$chunks" | jq 'length') || exit 1
      [ "$n" = "$est" ] && break
      est=$n; pass=$((pass + 1))
    done
    chunks=$(printf '%s' "$chunks" | jq -c --argjson n "$n" '[range(0; length) as $i | .[$i] + " (\($i + 1)/\($n))"]') || exit 1
  fi
  printf '%s\n' "$chunks"
}

report() {  # <code> <retry-after> [<out-file>]
  case "$1" in
    2[0-9][0-9]) return 0 ;;
    429) printf 'retry-after %s\n' "$2"; exit 3 ;;
    4[0-9][0-9]) printf 'http %s\n' "$1"; exit 2 ;;
    *) printf 'http %s\n' "${1:-0}"; exit 4 ;;
  esac
}

cmd_post_one() {
  local channel=${1:-} nonce='' reply_to='' mention='' text_file='' payload out code retry rc
  shift || true
  id_ok "$channel" || die "unsafe channel id" 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nonce) nonce=${2:-}; shift ;;
      --reply-to) reply_to=${2:-}; id_ok "$reply_to" || die "unsafe reply-to message id" 2; shift ;;
      --mention) mention=${2:-}; id_ok "$mention" || die "unsafe user id" 2; shift ;;
      --text-file) text_file=${2:-}; shift ;;
      *) die "unknown argument" 2 ;;
    esac
    shift
  done
  case "$nonce" in ''|*[!A-Za-z0-9]*) die "unsafe nonce" 2 ;; esac
  [ "${#nonce}" -le 25 ] || die "nonce longer than 25 characters" 2
  [ -f "$text_file" ] || die "text file missing" 2
  discord_load_config
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || die "DISCORD_BOT_TOKEN not configured"
  payload=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-discord-payload.XXXXXX") || exit 1
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-discord-out.XXXXXX") || { rm -f "$payload"; exit 1; }
  # shellcheck disable=SC2064 # expand now: the locals are gone by exit time
  trap "rm -f '$payload' '$out'" EXIT
  jq -n --rawfile c "$text_file" --arg n "$nonce" --arg r "$reply_to" --arg m "$mention" '
    {content: $c, nonce: $n, enforce_nonce: true,
     allowed_mentions: ({parse: [], replied_user: false} + (if $m != "" then {users: [$m]} else {} end))}
    + (if $r != "" then {message_reference: {message_id: $r, fail_if_not_exists: false}} else {} end)' \
    > "$payload" || exit 1
  rc=0
  read -r code retry < <(discord_api POST "/channels/$channel/messages" "$payload" "$out"; printf '\n') || true
  [ -n "${code:-}" ] || rc=4
  [ "$rc" -eq 0 ] || { printf 'http 0\n'; exit 4; }
  report "$code" "$retry"
  printf 'sent %s\n' "$(jq -r '.id // "unknown"' "$out" 2>/dev/null || printf unknown)"
}

cmd_get() {
  local path=${1:-} out_path='' code retry
  shift || true
  case "$path" in /*) ;; *) die "api path must start with /" 2 ;; esac
  case "$path" in *[!A-Za-z0-9/_?=\&@-]*) die "unsafe api path" 2 ;; esac
  [ "${1:-}" = --out ] && [ -n "${2:-}" ] || die "missing --out" 2
  out_path=$2
  discord_load_config
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || die "DISCORD_BOT_TOKEN not configured"
  read -r code retry < <(discord_api GET "$path" "" "$out_path"; printf '\n') || true
  [ -n "${code:-}" ] || { printf 'http 0\n'; exit 4; }
  report "$code" "$retry"
}

case "${1:-}" in
  split) shift; cmd_split "$@" ;;
  post-one) shift; cmd_post_one "$@" ;;
  get) shift; cmd_get "$@" ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die "usage: fm-discord-send.sh split|post-one|get (see --help)" 2 ;;
esac
