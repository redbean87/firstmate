#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the Pi supervision
# branch (docs/pi-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false,
#     "statusEndpoint":N,"statusIdent":"..."}. Legacy rows without `silent`
#     or status provenance remain valid and are treated as visible. A silent
#     row must have verdict `routine`; the branch prompt and delivery consumers
#     own the additional no-change eligibility rule.
#     Every read and append validates the complete log as a gap-free sequence;
#     malformed, duplicate, or reordered rows fail closed.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq presented
#     by Pi as a routine merge note or sequence-keyed visible captain entry,
#     emitted by Pi's locked session-start replay, silently consumed there
#     because `silent` is true, or presented by the supervision-host drain.
#     Records above the cursor are unread. A captain row advances only after
#     Pi persists its matching visible entry or the host prints its drain
#     section, so interrupted presentation can be retried.
#     A cursor beyond the validated store tail fails closed.
#   - Processed marker: $STATE/.branch-outcomes-processed holds the highest
#     seq whose captain rows main has ACKNOWLEDGED as processed, separately
#     from the read cursor: reading (the visible entry) is the branch's act,
#     processing (main acting on the outcome and calling its acknowledgement
#     tool) is main's. A captain row between the two markers is "unprocessed":
#     delivered and shown, not yet acted on. Routine rows never wait on this
#     marker. It only advances through an explicit sequence-bound
#     acknowledgement naming a currently unprocessed captain row at or below
#     the read cursor; a routine, unread, or already-processed target is
#     refused. It never moves past the read cursor or backwards, so an
#     unrelated or empty model answer cannot move it. An absent marker reads as
#     0 (every delivered captain row is unprocessed, the safe direction), and
#     nothing ever creates it from the read cursor: the Pi branch's visible
#     entries and a supervision-host drain's presentation both advance that
#     cursor without main acknowledging anything, and no stored state tells
#     which one did. So a home without a marker, including one upgraded from
#     before the marker existed or switched between Pi and the host, presents
#     its delivered captain rows again, dated and check-first, until main
#     acknowledges them. A marker ahead of the read cursor fails closed.
#   - Outcome index: $STATE/.<task>.branch-outcome-index stores one bounded
#     cache of the latest outcome's status provenance. The authoritative copy
#     is in the append-only row. $STATE/.branch-outcome-index-ready is removed
#     before append and published only after the cache update; processed-init
#     rebuilds every cache before publishing it, so interruption or upgrade
#     fails closed without making each drain scan lifetime history.
#     bin/fm-teardown.sh removes a retired task's cache with its other records,
#     and append skips the cache for a task that has neither a live meta nor a
#     status log (the outcome itself is still stored), so the branch's report
#     of a teardown it just performed leaves no index behind.
#     Main-actor drain calls processed-init under the outcome lock when that
#     ready marker is absent or invalid, on every harness; only a genuine store
#     fault keeps the lost-wake backstop skipped.
#   - Tail copy: $STATE/.branch-outcomes-tail.jsonl holds the newest
#     OUTCOME_TAIL_ROWS store lines verbatim, and only as many of the newest
#     as fit in OUTCOME_TAIL_MAX_BYTES (1 MiB): older rows leave first, a row
#     is never shortened, and a newest row larger than the budget leaves the
#     copy empty. It is replaced atomically after each append. It is a
#     read-only display source for readers that cannot read the
#     unbounded store (the Claude Code Calm mod's supervision notes, whose file
#     read rejects over 4 MiB); it is never authoritative, and a failed refresh
#     leaves the stored outcome and its delivery untouched. seed-tail creates
#     it from a bounded window of the store's newest complete rows when it is
#     absent, so a home whose store predates it gains one at its next session
#     start without scanning lifetime history.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - Discord outbound (docs/discord-integration.md "Outbound tap" owns the
#     tap contract): after a captain-verdict append whose summary classifies
#     into decision, completion, or blocker is durably stored and its seq
#     printed, the append path launches bin/fm-discord-notify.sh once with
#     an explicit class, a stable logical event key, and sanitized text,
#     detached from the append process: append exits without waiting on the
#     send, so caller bookkeeping and queued deliveries never stall on
#     Discord latency, and the run's one result line is appended to
#     $STATE/.branch-outcome-notify.log. Routine text never notifies,
#     whatever the verdict. The notification runs outside the store lock and
#     never changes the append result: a failed send is a logged warning
#     only, and the tap's own marker release lets a later same-key sighting
#     retry. Non-decision rows notify under a logical key (task, class,
#     summary hash), so the same recurring event shares one marker across
#     re-wakes and re-reports; a keyed decision notifies under
#     decision-<task>-<key> and its marker is released by any later close of
#     that key, whether the closing outcome summary restates the key
#     (resolved/captain-held) or the task status fold shows it resolved, so
#     its next occurrence pings again. The detached send reconciles that
#     marker against the store and the fold before and after delivery, so a
#     delayed send neither strands a stale marker behind a close nor
#     double-pings a repeat.
#   - The store is written BEFORE the outcome is delivered to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-read --through <seq>
#     Advance the cursor (never backwards) after Pi delivers the records or
#     the host presents them in its drain.
#   fm-branch-outcome.sh unprocessed
#     Print read but unprocessed captain records as JSONL in ascending seq, up to 32 per call, each with "recordedAgo".
#     Summaries over 1024 characters are abbreviated within that bound and point to lookup --seqs <n> for the full outcome.
#     Exit 0 with no output when none.
#   fm-branch-outcome.sh mark-processed --through <seq>
#     Advance the processed marker after main acknowledged the captain rows
#     through <seq>; the target itself must be a currently unprocessed captain
#     row at or below the read cursor.
#   fm-branch-outcome.sh present
#     A supervision-host drain's presentation off Pi (bin/fm-wake-drain.sh
#     "BRANCH OUTCOMES", docs/supervision-host.md "Captain outcomes"): under
#     the lock, print every unread record and every unprocessed captain record
#     (JSONL, ascending seq, each with an added "unread" boolean, and each
#     captain record also with "recordedAgo"). It moves nothing: off Pi that
#     drain presentation is what the visible entry is, so the drain runs
#     mark-read once it has presented the rows; it is the only reader that
#     advances the cursor there. Prints nothing when nothing is unread or
#     unprocessed.
#     "recordedAgo" is how long before this read the row was appended, as
#     whole minutes under an hour, whole hours under two days, else whole days
#     (for example "0m", "5h", "6d"; a future epoch reads "0m"). It is the one
#     owner of that wording for both presenters, the drain's BRANCH OUTCOMES
#     section and the Pi branch's processing request, because a row main never
#     acknowledged can be presented again long after its situation settled.
#   fm-branch-outcome.sh processed-init [--held-lock]
#     Validate the read cursor and the processed marker without changing them,
#     then rebuild the bounded per-task outcome indexes. --held-lock is only
#     for a descendant of the process holding $STATE/.branch-outcomes.lock
#     (fm-wake-drain.sh may run its redirected presentation body in a subshell
#     on Bash 3.2); it skips the nested acquire so drain's bounded lock wait
#     remains the deadline.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh lookup --seqs <n,...>
#     Print the requested records in sequence order only when every sequence
#     exists; validate the full store while holding its lock.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print the leading routine unread records under a
#     labeled header into the locked startup digest, skip rows whose `silent`
#     field is true, and mark those leading routine rows read. Stop before the
#     first captain row because only Pi's sequence-keyed visible entry may
#     acknowledge that row. Prints nothing when nothing replayable is unread.
#     Run it only when the session holds the lock (fm-session-start.sh owns the
#     call site).
#   fm-branch-outcome.sh seed-tail
#     Under the lock, when the store has rows and the display tail copy is
#     absent, validate only the newest complete rows within the display-tail
#     row and byte budget and write the copy from them; otherwise read and
#     change nothing. fm-session-start.sh runs it at every locked session
#     start, on every harness and away posture, before the drain.
#   fm-branch-outcome.sh notify-event --task <id> --summary <text>
#     Read-only derivation for the wake-drain relay (bin/fm-wake-drain.sh):
#     print the tap's own decision for one captain-facing summary as one
#     tab-separated "class<TAB>event-key<TAB>text<TAB>decision-key" line, so a
#     MAIN presentation derives the exact class, logical event key, and
#     sanitized text the append path uses instead of reimplementing them.
#     Routine input prints class routine; the caller stays silent. Reads no
#     store state and writes nothing.
set -eu

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-discord-lib.sh
. "$SCRIPT_DIR/fm-discord-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
PROCESSED="$STATE/.branch-outcomes-processed"
LOCK="$STATE/.branch-outcomes.lock"
MAX_SAFE_SEQ=9007199254740991
OUTCOME_INDEX_VERSION=fm-branch-outcome-index-v1
OUTCOME_INDEX_MAX_BYTES=512
OUTCOME_INDEX_READY="$STATE/.branch-outcome-index-ready"
OUTCOME_TAIL="$STATE/.branch-outcomes-tail.jsonl"
OUTCOME_TAIL_ROWS=200
OUTCOME_TAIL_MAX_BYTES=1048576
# The "recordedAgo" field present and unprocessed add to captain rows (see the
# usage above).
# Callers pass --argjson now "$(date +%s)".
# shellcheck disable=SC2016  # jq program text: $now and $s are jq variables.
RECORDED_AGO_JQ='def recorded_ago: ([$now - .epoch, 0] | max) as $s
  | if $s < 3600 then "\($s / 60 | floor)m"
    elif $s < 172800 then "\($s / 3600 | floor)h"
    else "\($s / 86400 | floor)d" end;'

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | mark-read --through <seq> | unprocessed | mark-processed --through <seq> | present | processed-init [--held-lock] | list [--recent <n>] | lookup --seqs <n,...> | startup-replay | seed-tail | notify-event --task <id> --summary <text>" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the outcome cursor is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the outcome cursor is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the outcome cursor is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

read_processed() {
  local value
  [ -e "$PROCESSED" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$PROCESSED" 2>/dev/null); then
    echo "error: refusing operation because the processed marker is unreadable" >&2
    return 1
  fi
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      echo "error: refusing operation because the processed marker is malformed" >&2
      return 1
      ;;
  esac
  if ! bounded_uint "$value"; then
    echo "error: refusing operation because the processed marker is out of range" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

last_seq() { # [<file> [<first expected seq, or null for a bounded suffix>]]
  local file=${1:-$STORE} start=${2:-1}
  [ -s "$file" ] || { printf '0\n'; return 0; }
  jq -Rse --argjson start "$start" '
    def valid:
      type == "object"
      and (
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (
          keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and ((.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint <= 9007199254740991 and .statusEndpoint == (.statusEndpoint | floor))
          and ((.statusIdent | type) == "string" and (.statusIdent | test("[\\t\\n]") | not))
        )
      )
      and ((.seq | type) == "number" and .seq >= 1 and .seq <= 9007199254740991 and .seq == (.seq | floor))
      and ((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
      and ((.task | type) == "string" and (.wake | type) == "string")
      and ((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
      and (.silent != true or .verdict == "routine");
    if endswith("\n") then split("\n")[:-1]
    else error("unterminated outcome store")
    end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + ($start // $rows[0].seq))))
      then .[-1].seq
      else error("malformed or non-sequential outcome store")
      end
  ' "$file" 2>/dev/null
}

record_seq() { # <jsonl-line>
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | jq -er '.seq'
}

outcome_index_path() { # <task>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.branch-outcome-index' "$STATE" "$1"
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0
  size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  case "$ident" in *$'\t'*|*$'\n'*|'') return 0 ;; esac
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

write_outcome_index() { # <task> <seq> [<endpoint> <identity>]
  local task=$1 seq=$2 endpoint=${3:-$CAPTURED_STATUS_ENDPOINT} ident=${4:-$CAPTURED_STATUS_IDENT} path tmp record
  path=$(outcome_index_path "$task") || return 1
  record=$(printf '%s\t%s\t%s\t%s\n' "$OUTCOME_INDEX_VERSION" "$seq" \
    "$endpoint" "$ident") || return 1
  [ "${#record}" -le "$OUTCOME_INDEX_MAX_BYTES" ] || return 1
  tmp=$(mktemp "$STATE/.branch-outcome-index.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$record" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

publish_outcome_index_ready() { # <seq>
  local tmp
  tmp=$(mktemp "$STATE/.branch-outcome-index-ready.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OUTCOME_INDEX_READY"
}

rebuild_outcome_indexes() {
  local rows task seq epoch endpoint ident f mtime
  rm -f -- "$OUTCOME_INDEX_READY" || return 1
  [ -s "$STORE" ] || { publish_outcome_index_ready 0; return; }
  rows=$(jq -r -s '
    map(select(.task != "fleet"))
    | group_by(.task)
    | map(.[-1])[]
    | [.task, (.seq | tostring), (.epoch | tostring),
       ((.statusEndpoint // "") | tostring), (.statusIdent // "")]
    | @tsv
  ' "$STORE") || return 1
  while IFS=$(printf '\t') read -r task seq epoch endpoint ident; do
    [ -n "$task" ] || continue
    if [ -z "$endpoint" ] || [ -z "$ident" ]; then
      f="$STATE/$task.status"
      endpoint=0
      ident=-
      if [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ]; then
        mtime=$(_fm_status_file_mtime "$f") || mtime=
        case "$mtime" in ''|*[!0-9]*) ;;
          *)
            # Legacy rows have only whole-second epochs, so equal timestamps
            # cannot prove whether the status preceded the outcome. Leave that
            # span uncovered: migration may rarely duplicate an old handled
            # event, but it will not hide a plausibly later captain-facing one.
            if [ "$mtime" -lt "$epoch" ]; then
              capture_status_position "$task"
              endpoint=$CAPTURED_STATUS_ENDPOINT
              ident=$CAPTURED_STATUS_IDENT
            fi
            ;;
        esac
      fi
    fi
    write_outcome_index "$task" "$seq" "$endpoint" "$ident" || return 1
  done <<EOF
$rows
EOF
  publish_outcome_index_ready "$(last_seq)"
}

write_outcome_tail() { # [<bounded input file>] (append uses the store)
  local tmp input=${1:-$STORE}
  tmp=$(mktemp "$STATE/.branch-outcomes-tail.XXXXXX") || return 1
  if ! { tail -n "$OUTCOME_TAIL_ROWS" "$input" | LC_ALL=C awk -v budget="$OUTCOME_TAIL_MAX_BYTES" '
        { row[NR] = $0 }
        END {
          first = NR + 1
          while (first > 1 && total + length(row[first - 1]) + 1 <= budget) {
            first--
            total += length(row[first]) + 1
          }
          for (i = first; i <= NR; i++) print row[i]
        }' > "$tmp" && mv -f -- "$tmp" "$OUTCOME_TAIL"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

print_unread() {
  local cursor last
  cursor=$(read_cursor)
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -c --argjson cursor "$cursor" 'select(.seq > $cursor)' "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor processed tmp
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing cursor advancement because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

write_processed() { # <seq>
  local through=$1 tmp
  tmp=$(mktemp "$STATE/.branch-outcomes-processed.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$PROCESSED"
}

# Captain rows above the processed marker and at or below the read cursor.
print_unprocessed() {
  local cursor processed last
  cursor=$(read_cursor) || return 1
  processed=$(read_processed) || return 1
  if ! last=$(last_seq); then
    echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if [ "$cursor" -gt "$last" ]; then
    echo "error: refusing read because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if [ "$processed" -gt "$cursor" ]; then
    echo "error: refusing read because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  [ -s "$STORE" ] || return 0
  jq -cn --argjson processed "$processed" --argjson cursor "$cursor" --argjson now "$(date +%s)" \
    "$RECORDED_AGO_JQ"'(reduce inputs as $row ([];
        if length < 32 and $row.verdict == "captain" and $row.seq > $processed and $row.seq <= $cursor
        then . + [$row] else . end))[]
      | ("… [summary abbreviated; read the full outcome with bin/fm-branch-outcome.sh lookup --seqs \(.seq)]") as $note
      | .summary |= (if length > 1024 then .[:(1024 - ($note | length))] + $note else . end)
      | . + {recordedAgo: recorded_ago}' "$STORE"
}

# Assumes $LOCK is already held. Callers that do not already hold it use the
# processed-init command, which acquires and releases around this body.
processed_init_locked() {
  local store_last cursor_seq processed_seq
  if ! store_last=$(last_seq); then
    echo "error: refusing processed initialization because the outcome store is malformed or non-sequential" >&2
    return 1
  fi
  if ! cursor_seq=$(read_cursor); then
    return 1
  fi
  if [ "$cursor_seq" -gt "$store_last" ]; then
    echo "error: refusing processed initialization because the outcome cursor is ahead of the store" >&2
    return 1
  fi
  if ! processed_seq=$(read_processed); then
    return 1
  fi
  if [ "$processed_seq" -gt "$cursor_seq" ]; then
    echo "error: refusing processed initialization because the processed marker is ahead of the read cursor" >&2
    return 1
  fi
  if ! rebuild_outcome_indexes; then
    echo "error: outcome index migration could not be completed safely" >&2
    return 1
  fi
}

# Discord outbound wiring. This script's append path is the production
# invocation boundary for the outbound tap: every captain-verdict append
# whose summary classifies into one of the tap's three classes notifies
# once, routine text never does, and no posture, presence, or gateway state
# gates the call, so decisions and blockers still ping while away or quiet.
# Classification runs the tap's shared rule (discord_classify_notify_text
# in bin/fm-discord-lib.sh), so the marker key and the tap's own
# classification stay in step.
outcome_notify_class() { # <summary> -> decision|completion|blocker|routine
  discord_classify_notify_text "$1"
}

# The decision-key grammar shared by marker creation and release: the
# status fold's own key parse (a stated [key=...] token in a documented
# position, valid slug, namespace transition allowed), so a marker is
# created and released under exactly one identity.
outcome_notify_dkey() { # <summary> -> decision key slug, or nothing
  local key
  key=$(_fm_decision_key "$1" "") || return 0
  [ -n "$key" ] || return 0
  _fm_decision_key_transition_allowed "$key" "$(status_line_note "$1")" || return 0
  printf '%s\n' "$key"
}

# 0 when the summary closes a keyed decision rather than opening one: the
# resolve/captain-held verbs, with the classify library's overrides.
outcome_decision_closing() { # <summary>
  local verb
  status_line_verb "$1" verb
  case "$verb" in
    "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") return 0 ;;
  esac
  return 1
}

outcome_release_decision_marker() { # <task> <summary>
  local key
  outcome_decision_closing "$2" || return 0
  key=$(outcome_notify_dkey "$2")
  [ -n "$key" ] || return 0
  rm -f -- "$STATE/discord-notify/decision-$1-$key" 2>/dev/null \
    || echo "warning: discord decision marker decision-$1-$key could not be released" >&2
  return 0
}

# Stable logical event key for the tap's send-once marker. A decision row
# for a keyed still-open decision notifies under decision-<task>-<key>, so
# re-handled rows share one marker; a line closing that decision releases
# the marker, so its next keyed occurrence pings again. Every other row
# notifies under branch-outcome-<task>-<class>-<summary-hash>: logical
# event identity that is stable across re-wakes, re-reports, and
# re-presentations, so a failed send retries on the next sighting of the
# same event and identical repeats never double-ping. Neither form derives
# from wake ids, store seqs, polling cycles, timestamps, or process
# attempts.
outcome_notify_key() { # <task> <class> <decision-key> <summary> -> event key
  local sig
  if [ "$2" = decision ] && [ -n "$3" ]; then
    printf 'decision-%s-%s\n' "$1" "$3"
  else
    sig=$(printf '%s' "$4" | cksum)
    printf 'branch-outcome-%s-%s-%s-%s\n' "$1" "$2" "${sig%% *}" "${sig##* }"
  fi
}

# Concise phone-safe text: collapse whitespace, drop absolute scratch paths,
# cap length. Secret shapes are additionally redacted by the tap itself; the
# branch owns keeping internal wording out of the summary it records. A
# decision summary is instead rendered through the shared decision-message
# contract (bin/fm-discord-lib.sh), which strips every internal metadata
# class and emits outcome, consequence, options, recommendation, and the
# reply path; the tap and the drain relay share that same renderer.
outcome_notify_text() { # <summary> -> text on stdout
  if [ "$(outcome_notify_class "$1")" = decision ]; then
    discord_decision_message "$1"
    return 0
  fi
  printf '%s' "$1" | tr '\n\t\r' '   ' \
    | sed -E -e 's:(^| )/(Users|tmp|private|var|home|root|opt|srv|etc)/[^ ]*::g' \
    | sed -e 's/  */ /g; s/^ *//; s/ *$//' \
    | jq -Rr 'if length > 500 then .[0:497] + "..." else . end'
}

# Latest lifecycle state of decision <key> for <task> in the outcome store:
# close when the most recent keyed row on the <before|after> side of <seq>
# closes the decision, open when it opens one, none when no keyed row is on
# that side. Keyed means the summary states [key=<key>] under the status
# fold's key grammar; closers are the resolve/captain-held verbs and openers
# are still-open decision or blocker sightings. A completion restating a key
# is neither: like the fold, it does not move the decision.
outcome_key_latest() { # <task> <key> <before|after> <seq> -> close|open|none
  local task=$1 key=$2 dir=$3 seq=$4 state=none line lseq summary k class
  [ -s "$STORE" ] || { printf 'none\n'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lseq=$(printf '%s' "$line" | jq -r '.seq // empty' 2>/dev/null) || continue
    case "$lseq" in ''|*[!0-9]*) continue ;; esac
    case "$dir" in
      before) [ "$lseq" -lt "$seq" ] 2>/dev/null || continue ;;
      *) [ "$lseq" -gt "$seq" ] 2>/dev/null || continue ;;
    esac
    summary=$(printf '%s' "$line" | jq -r '.summary // empty' 2>/dev/null) || continue
    k=$(outcome_notify_dkey "$summary")
    [ "$k" = "$key" ] || continue
    if outcome_decision_closing "$summary"; then state=close; continue; fi
    class=$(outcome_notify_class "$summary")
    case "$class" in decision|blocker) state=open ;; esac
  done <<EOF
$(jq -c --arg task "$task" 'select(.task == $task)' "$STORE" 2>/dev/null)
EOF
  printf '%s\n' "$state"
}

# 0 when the status fold shows <key> for <task> closed: a resolved or
# captain-held status line states the key and the fold no longer lists it
# as open. This is the keyless-close path: the closing outcome summary may
# never restate the key while the status log carries the resolution.
outcome_status_key_closed() { # <task> <key>
  local f="$STATE/$1.status" open line verb k
  case "$2" in ''|default|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  open=$(status_open_decisions "$f" 2>/dev/null) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      "$2"$'\t'*) return 1 ;;
    esac
  done <<EOF
$open
EOF
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" verb 2>/dev/null || continue
    case "$verb" in
      "${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}"|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") ;;
      *) continue ;;
    esac
    k=$(_fm_decision_key "$line" "") 2>/dev/null || continue
    [ "$k" = "$2" ] || continue
    _fm_decision_key_transition_allowed "$k" "$(status_line_note "$line")" 2>/dev/null || continue
    return 0
  done < "$f"
  return 1
}

outcome_release_closed_decision_markers() { # <task>
  local m base key
  for m in "$STATE/discord-notify/decision-$1-"*; do
    [ -e "$m" ] || continue
    [ -f "$m" ] && [ ! -L "$m" ] || continue
    base=${m##*/}
    key=${base#"decision-$1-"}
    case "$key" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    if outcome_status_key_closed "$1" "$key" 2>/dev/null; then
      rm -f -- "$m" 2>/dev/null \
        || echo "warning: discord decision marker decision-$1-$key could not be released" >&2
    fi
  done
  return 0
}

# Reconcile one decision marker after a detached delivery settles: drop the
# marker when the episode it pinged is now closed (a keyed close landed past
# its row, or the fold shows the key closed with no reopen past its row),
# so the next same-key occurrence pings again. A still-open decision keeps
# its marker, so repeats stay silent. Always returns 0.
outcome_reconcile_decision_marker() { # <task> <key> <seq>; always 0
  local latest
  latest=$(outcome_key_latest "$1" "$2" after "$3" 2>/dev/null) || return 0
  case "$latest" in
    close)
      rm -f -- "$STATE/discord-notify/decision-$1-$2" 2>/dev/null \
        || echo "warning: discord decision marker decision-$1-$2 could not be reconciled" >&2
      return 0
      ;;
    open) return 0 ;;
  esac
  outcome_status_key_closed "$1" "$2" 2>/dev/null || return 0
  rm -f -- "$STATE/discord-notify/decision-$1-$2" 2>/dev/null \
    || echo "warning: discord decision marker decision-$1-$2 could not be reconciled" >&2
  return 0
}

# Fire the tap for one stored captain row. Always returns 0: the row is
# already durable, so a failed send is a stderr warning, never an append
# failure (failing the append would record a duplicate row on retry).
outcome_maybe_notify_discord() { # <task> <summary> <seq>; always 0
  local task=$1 summary=$2 seq=$3 class event text dkey out rc=0 marker had_marker=0 sent=0
  class=$(outcome_notify_class "$summary")
  if [ "$class" = routine ]; then
    echo "discord-notify: $task: silent (routine)" >&2
    return 0
  fi
  dkey=
  if [ "$class" = decision ] && ! outcome_decision_closing "$summary"; then
    dkey=$(outcome_notify_dkey "$summary")
  fi
  event=$(outcome_notify_key "$task" "$class" "$dkey" "$summary")
  text=$(outcome_notify_text "$summary")
  [ -n "$text" ] || text="update on $task"
  marker="$STATE/discord-notify/$event"
  if [ -e "$marker" ]; then had_marker=1; fi
  trap '[ "$had_marker" = 1 ] || [ "$sent" = 1 ] || rm -f -- "$marker"' HUP INT TERM
  if [ -n "$dkey" ]; then
    if [ "$(outcome_key_latest "$task" "$dkey" before "$seq" 2>/dev/null)" = close ]; then
      rm -f -- "$marker" 2>/dev/null \
        || echo "warning: discord decision marker $event could not be reconciled" >&2
      had_marker=0
      if [ -e "$marker" ]; then had_marker=1; fi
    fi
  fi
  set -- --event "$event" --class "$class" --text "$text"
  [ -z "$dkey" ] || set -- "$@" --decision-key "$dkey"
  # The || exempts the send from set -e: a failed delivery is a warning,
  # never an append failure.
  out=$("$SCRIPT_DIR/fm-discord-notify.sh" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then sent=1; fi
  if [ "$rc" -eq 0 ]; then
    [ -n "$out" ] || out="silent (already notified, unconfigured, or suppressed)"
    echo "discord-notify: $event [$class]: $out" >&2
  else
    echo "warning: discord-notify: $event [$class] failed (exit $rc): ${out:-no detail}; marker released, a later same-key sighting retries" >&2
  fi
  if [ -n "$dkey" ]; then
    outcome_reconcile_decision_marker "$task" "$dkey" "$seq" || true
  fi
  trap - HUP INT TERM
  return 0
}

held_lock_owned_by_ancestor() {
  local owner owner_pid pid parent depth=0
  case "$PPID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  if [ -L "$LOCK" ]; then
    owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null) || return 1
    fm_lock_points_to_owner "$LOCK" "$owner" || return 1
  elif [ -d "$LOCK" ]; then
    owner=$LOCK
  else
    return 1
  fi
  owner_pid=$(cat "$owner/pid" 2>/dev/null) || return 1
  fm_pid_alive "$owner_pid" || return 1

  # Bash 3.2 keeps $$ unchanged in a redirected subshell while that subshell's
  # real pid becomes this script's parent. Walk the bounded live ancestry so
  # that legitimate drain shape is accepted without trusting an arbitrary
  # caller merely because it can name or observe the lock owner.
  pid=$PPID
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$owner_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    outcome_index_path "$TASK" >/dev/null || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
      echo "error: silent outcomes must have the routine verdict" >&2
      exit 2
    fi
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome cursor is invalid or ahead of the store" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    capture_status_position "$TASK"
    rm -f -- "$OUTCOME_INDEX_READY" || { fm_lock_release "$LOCK"; exit 1; }
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
    write_outcome_tail || echo "warning: outcome $SEQ was stored but its display tail copy could not be refreshed" >&2
    # A task with neither a live meta nor a status log is retired: the branch
    # reports the teardown it just performed, and writing the index here would
    # recreate the footprint teardown removed. The outcome itself is still
    # stored and delivered; only the reader-less cache is skipped.
    if { [ -e "$STATE/$TASK.meta" ] || [ -e "$STATE/$TASK.status" ]; } \
        && ! write_outcome_index "$TASK" "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    if ! publish_outcome_index_ready "$SEQ"; then
      fm_lock_release "$LOCK"
      echo "error: outcome was stored but its bounded task index could not be updated" >&2
      exit 1
    fi
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    outcome_release_decision_marker "$TASK" "$SUMMARY"
    outcome_release_closed_decision_markers "$TASK"
    if [ "$VERDICT" = captain ]; then
      ( outcome_maybe_notify_discord "$TASK" "$SUMMARY" "$SEQ" ) \
        >>"$STATE/.branch-outcome-notify.log" 2>&1 </dev/null &
    fi
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored outcome" >&2
      exit 1
    fi
    if ! advance_cursor "$THROUGH"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  present)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing presentation because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ] || [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing presentation because the outcome cursor or processed marker is out of order" >&2
      exit 1
    fi
    if [ -s "$STORE" ] && ! jq -c --argjson cursor "$CURSOR_SEQ" --argjson processed "$PROCESSED_SEQ" \
        --argjson now "$(date +%s)" "$RECORDED_AGO_JQ"'
        select(.seq > $cursor or (.verdict == "captain" and .seq > $processed))
        | . + {unread: (.seq > $cursor)}
        | if .verdict == "captain" then . + {recordedAgo: recorded_ago} else . end' "$STORE"; then
      fm_lock_release "$LOCK"
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  unprocessed)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unprocessed
    STATUS=$?
    fm_lock_release "$LOCK"
    exit "$STATUS"
    ;;
  mark-processed)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! CURSOR_SEQ=$(read_cursor) || ! PROCESSED_SEQ=$(read_processed); then
      fm_lock_release "$LOCK"
      exit 1
    fi
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ "$CURSOR_SEQ" -gt "$LAST_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the outcome cursor is ahead of the store" >&2
      exit 1
    fi
    if [ "$PROCESSED_SEQ" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because the processed marker is ahead of the read cursor" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement beyond the read cursor ($CURSOR_SEQ)" >&2
      exit 1
    fi
    if [ "$THROUGH" -le "$PROCESSED_SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is already processed" >&2
      exit 1
    fi
    VERDICT=$(jq -r --argjson through "$THROUGH" 'select(.seq == $through) | .verdict' "$STORE")
    if [ "$VERDICT" != captain ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing processed advancement because seq $THROUGH is not an unprocessed captain outcome" >&2
      exit 1
    fi
    write_processed "$THROUGH"
    fm_lock_release "$LOCK"
    ;;
  processed-init)
    HELD_LOCK=0
    if [ "${1:-}" = --held-lock ]; then
      HELD_LOCK=1
      shift
    fi
    [ "$#" -eq 0 ] || usage
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_acquire_wait "$LOCK"
    elif ! held_lock_owned_by_ancestor; then
      echo "error: --held-lock requires an ancestor process to own the outcome lock" >&2
      exit 1
    fi
    if ! processed_init_locked; then
      if [ "$HELD_LOCK" -eq 0 ]; then
        fm_lock_release "$LOCK"
      fi
      exit 1
    fi
    if [ "$HELD_LOCK" -eq 0 ]; then
      fm_lock_release "$LOCK"
    fi
    ;;
  notify-event)
    NOTIFY_TASK=''
    NOTIFY_SUMMARY=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) NOTIFY_TASK=${2:-}; shift 2 || usage ;;
        --summary) NOTIFY_SUMMARY=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$NOTIFY_TASK" ] && [ -n "$NOTIFY_SUMMARY" ] || usage
    NOTIFY_CLASS=$(outcome_notify_class "$NOTIFY_SUMMARY")
    NOTIFY_DKEY=''
    if [ "$NOTIFY_CLASS" = decision ] && ! outcome_decision_closing "$NOTIFY_SUMMARY"; then
      NOTIFY_DKEY=$(outcome_notify_dkey "$NOTIFY_SUMMARY") || NOTIFY_DKEY=''
    fi
    if [ "$NOTIFY_CLASS" = routine ]; then
      printf 'routine\t\t\t\n'
      exit 0
    fi
    NOTIFY_EVENT=$(outcome_notify_key "$NOTIFY_TASK" "$NOTIFY_CLASS" "$NOTIFY_DKEY" "$NOTIFY_SUMMARY")
    NOTIFY_TEXT=$(outcome_notify_text "$NOTIFY_SUMMARY" 2>/dev/null) || NOTIFY_TEXT=''
    # The relay consumes one tab-separated line, and a rendered decision
    # message is multi-line, so encode newlines as a literal \n for the wire
    # and let the tap decode them back into real line breaks before sending.
    NOTIFY_TEXT=$(printf '%s' "$NOTIFY_TEXT" | awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }')
    printf '%s\t%s\t%s\t%s\n' "$NOTIFY_CLASS" "$NOTIFY_EVENT" "$NOTIFY_TEXT" "$NOTIFY_DKEY"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if [ -s "$STORE" ]; then
      tail -n "$RECENT" "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  lookup)
    [ "$#" -eq 2 ] && [ "$1" = --seqs ] || usage
    SEQS=$2
    case "$SEQS" in ''|,*|*,|*,,*) usage ;; esac
    IFS=, read -r -a REQUESTED <<< "$SEQS"
    [ "${#REQUESTED[@]}" -gt 0 ] || usage
    WANT='['
    SEP=
    for SEQ in "${REQUESTED[@]}"; do
      bounded_uint "$SEQ" || usage
      WANT="${WANT}${SEP}${SEQ}"
      SEP=,
    done
    WANT="${WANT}]"
    printf '%s\n' "$WANT" | jq -e 'length == (unique | length)' >/dev/null || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing lookup because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! jq -cs --argjson wanted "$WANT" '
      . as $rows
      | [ $wanted[] as $seq | $rows[] | select(.seq == $seq) ]
      | if length == ($wanted | length) then .[] else error("requested outcome sequence is missing") end
    ' "$STORE" 2>/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing lookup because one or more requested outcome sequences are missing" >&2
      exit 1
    fi
    fm_lock_release "$LOCK"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    UNREAD=$(print_unread)
    if [ -n "$UNREAD" ]; then
      REPLAYABLE=$(printf '%s\n' "$UNREAD" | jq -sc '
        map(.verdict) as $verdicts
        | ($verdicts | index("captain")) as $captain
        | .[0:($captain // length)][]
      ')
      VISIBLE=$(printf '%s\n' "$REPLAYABLE" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$REPLAYABLE" | tail -n 1)")
      if [ -n "$LAST" ] && ! advance_cursor "$LAST"; then
        fm_lock_release "$LOCK"
        exit 1
      fi
    fi
    fm_lock_release "$LOCK"
    ;;
  seed-tail)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if [ -e "$OUTCOME_TAIL" ] || [ ! -s "$STORE" ]; then
      fm_lock_release "$LOCK"
      exit 0
    fi
    WINDOW=$(mktemp "$STATE/.branch-outcomes-window.XXXXXX") || { fm_lock_release "$LOCK"; exit 1; }
    # One extra byte distinguishes a complete first row from a partial one.
    # Discard the first line when the store exceeds this window: it may be
    # partial (or empty when the boundary falls exactly on a newline).
    START=1
    STORE_SIZE=$(_fm_status_file_size "$STORE") || { rm -f -- "$WINDOW"; fm_lock_release "$LOCK"; exit 1; }
    if [ "$STORE_SIZE" -gt "$((OUTCOME_TAIL_MAX_BYTES + 1))" ]; then
      START=null
      tail -c "$((OUTCOME_TAIL_MAX_BYTES + 1))" "$STORE" | awk 'NR > 1' | tail -n "$OUTCOME_TAIL_ROWS" > "$WINDOW"
    else
      tail -n "$OUTCOME_TAIL_ROWS" "$STORE" > "$WINDOW"
      # Even a short store can have more rows than the display limit.
      [ "$(wc -l < "$STORE")" -le "$OUTCOME_TAIL_ROWS" ] || START=null
    fi
    if ! last_seq "$WINDOW" "$START" >/dev/null; then
      rm -f -- "$WINDOW"
      fm_lock_release "$LOCK"
      echo "error: refusing to seed the display tail copy because the outcome store is malformed or non-sequential" >&2
      exit 1
    fi
    if ! write_outcome_tail "$WINDOW"; then
      rm -f -- "$WINDOW"
      fm_lock_release "$LOCK"
      echo "error: the display tail copy could not be seeded from the outcome store" >&2
      exit 1
    fi
    rm -f -- "$WINDOW"
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
