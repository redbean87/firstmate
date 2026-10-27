# shellcheck shell=bash
# Shared shell library for the fork's Discord bridge (fork/discord/README).
#
# Ported from the earlier core-edit implementation (origin/main
# bin/fm-discord-lib.sh), keeping only what the bridge's sender uses:
#   discord_load_config   resolve DISCORD_BOT_TOKEN and DISCORD_API_BASE;
#                         the environment wins over $FM_HOME/.env, read
#                         through upstream bin/fm-env-lib.sh
#   discord_redact <text> replace token shapes and the loaded token with ***
#   discord_chunk_text [budget]
#                         split stdin into Discord-safe chunks (JSON array),
#                         measured in Discord's UTF-16 units; paragraphs,
#                         then lines, then words, then a hard split
#   discord_chunk_units   UTF-16 unit length of stdin
#   discord_api <method> <api-path> [body-file] [out-file]
#                         one authenticated REST call; prints
#                         "<http-code> <retry-after-seconds-or-0>"
# Authorization, the inbox, and the outbox live in fm-discord-bridge.py.
#
# Sourced, never executed; callers set their own shell options and FM_HOME.
# Nothing here prints a secret.

_DISCORD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-env-lib.sh
. "$_DISCORD_LIB_DIR/../../bin/fm-env-lib.sh"

DISCORD_API_BASE_DEFAULT="https://discord.com/api/v10"
# Chunk budget in Discord UTF-16 code units, below the 2000-unit API limit.
DISCORD_CHUNK_BUDGET=1990

discord_load_config() {
  local env_file=${DISCORD_ENV_FILE:-${FM_HOME:-}/.env}
  if [ -z "${DISCORD_BOT_TOKEN+x}" ]; then DISCORD_BOT_TOKEN=$(fmx_env_get DISCORD_BOT_TOKEN "$env_file"); fi
  if [ -z "${DISCORD_API_BASE+x}" ]; then DISCORD_API_BASE=$(fmx_env_get DISCORD_API_BASE "$env_file"); fi
  [ -n "${DISCORD_API_BASE:-}" ] || DISCORD_API_BASE="$DISCORD_API_BASE_DEFAULT"
  DISCORD_API_BASE=${DISCORD_API_BASE%/}
  export DISCORD_BOT_TOKEN DISCORD_API_BASE
}

discord_redact() {
  # Secrets are substituted with literal bash replacement, never a regex, so
  # hostile characters in a secret cannot alter the match.
  local text=${1:-} secret
  text=$(printf '%s' "$text" | sed -E 's/[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_.-]{5,}\.[A-Za-z0-9_.-]{10,}/***/g')
  secret=${DISCORD_BOT_TOKEN:-}
  if [ -n "$secret" ] && [ "${#secret}" -ge 8 ]; then
    text=${text//"$secret"/***}
  fi
  printf '%s' "$text"
}

discord_chunk_text() {
  # Splits on paragraph boundaries, then line boundaries inside an oversized
  # paragraph (keeping its line breaks), then words inside an oversized line,
  # and hard-splits only a single over-long word.
  local budget=${1:-$DISCORD_CHUNK_BUDGET}
  jq -Rsc --argjson limit "$budget" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def ulen: length + ((explode | map(select(. > 65535)) | length));
    def hardsplit($b):
      explode as $cps
      | (reduce $cps[] as $cp ({runs:[], cur:[], w:0};
           (if $cp > 65535 then 2 else 1 end) as $u
           | if .w + $u > $b and ((.cur | length) > 0)
             then .runs += [(.cur | implode)] | .cur = [$cp] | .w = $u
             else .cur += [$cp] | .w += $u end)) as $st
      | $st.runs + (if ($st.cur | length) > 0 then [($st.cur | implode)] else [] end);
    def wordsplit($b):
      (gsub("[[:space:]]+"; " ") | trim) as $norm
      | if ($norm|ulen) == 0 then []
        else [ $norm | split(" ")[] | if (ulen > $b) then hardsplit($b)[] else . end ]
          | (reduce .[] as $w ({chunks:[],cur:""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand|ulen) <= $b then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $w end))
          as $st | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end) end;
    def group($sep; $b; split_unit):
      (reduce .[] as $u ({chunks:[],cur:""};
        if ($u|ulen) > $b then
          (if .cur != "" then .chunks += [.cur] | .cur = "" else . end)
          | .chunks += ($u | split_unit)
        else (if .cur == "" then $u else .cur + $sep + $u end) as $cand
          | if ($cand|ulen) <= $b then .cur = $cand
            else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $u end
        end)) as $st
      | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end);
    def linesplit($b):
      [split("\n")[] | gsub("[[:space:]]+$"; "") | select(length > 0)]
      | group("\n"; $b; wordsplit($b));
    trim as $norm
    | if ($norm|ulen) == 0 then []
      elif ($norm|ulen) <= $limit then [$norm]
      else ($norm | split("\n\n") | map(trim) | map(select(length > 0)))
        | group("\n\n"; $limit; linesplit($limit)) end
  '
}

discord_chunk_units() {
  jq -Rsc 'length + ((explode | map(select(. > 65535)) | length))'
}

discord_auth_header_file() {
  local file
  case "${DISCORD_BOT_TOKEN:-}" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-discord-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bot %s\n' "$DISCORD_BOT_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

# Runs in a subshell so its temp-file EXIT trap cannot clobber the caller's.
# Honors 429 Retry-After (header first, then the JSON body); never logs the
# token. Exit 127 without curl, 3 without a token, 4 on a transport failure.
discord_api() (
  local method=$1 path=$2 body_file=${3:-} out_file=${4:-/dev/null}
  local auth code retry_after dump
  command -v curl >/dev/null 2>&1 || return 127
  [ -n "${DISCORD_BOT_TOKEN:-}" ] || return 3
  auth=$(discord_auth_header_file) || return 3
  dump=$(mktemp "${TMPDIR:-/tmp}/fm-discord-hdr.XXXXXX") || { rm -f "$auth"; return 1; }
  trap 'rm -f "$auth" "$dump"' EXIT
  trap 'rm -f "$auth" "$dump"; exit 143' HUP INT TERM
  if [ -n "$body_file" ]; then
    code=$(curl -m 15 -s -D "$dump" -o "$out_file" -w '%{http_code}' -X "$method" \
      -H "@$auth" -H 'Content-Type: application/json' --data-binary "@$body_file" \
      "$DISCORD_API_BASE$path" 2>/dev/null)
  else
    code=$(curl -m 15 -s -D "$dump" -o "$out_file" -w '%{http_code}' -X "$method" \
      -H "@$auth" -H 'Accept: application/json' \
      "$DISCORD_API_BASE$path" 2>/dev/null)
  fi
  # shellcheck disable=SC2181
  [ "$?" = 0 ] || return 4
  retry_after=$(grep -i '^retry-after:' "$dump" 2>/dev/null | tail -n1 | awk '{print $2}' | tr -d '\r' || true)
  case "$retry_after" in ''|*[!0-9.]*) retry_after=0 ;; esac
  if [ "$code" = 429 ] && [ "$retry_after" = 0 ] && [ -s "$out_file" ]; then
    retry_after=$(jq -r '.retry_after // 0' "$out_file" 2>/dev/null || printf '0')
    case "$retry_after" in ''|*[!0-9.]*) retry_after=0 ;; esac
  fi
  printf '%s %s\n' "$code" "$retry_after"
)
