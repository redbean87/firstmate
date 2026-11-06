#!/usr/bin/env bash
# fm-decision-log.sh - append one captain ruling to the decision ledger.
#
# Usage:
#   bin/fm-decision-log.sh add --task <id> [--goal <text>] [--words-file <path>]
#   bin/fm-decision-log.sh add --task <id> [--goal <text>]   # words on stdin
#   bin/fm-decision-log.sh --help
#
# The ledger lives at data/decisions.md under FM_HOME (default: this
# checkout's home) and is created with its format header on first use; it is
# never committed to a branch, because data/ is captain-private. The ledger is
# the CHRONOLOGY of the captain's rulings: one append-only entry per ruling
# carrying the date, the captain's exact words, the goal it serves, and the
# task id that implemented it. The captain-preference file stays the DISTILLED
# rules: a rule refined later is edited there, while the ledger keeps the
# original words - never rewrite, reorder, or edit an entry that already
# exists.
#
# Entry format (this script owns it):
#
#   ## <YYYY-MM-DD>            the UTC date the ruling was logged
#
#   - Task: <task id>          the task that implemented the ruling
#   - Goal: <one line>         the goal it serves, or - when none was given
#
#   Words:
#
#   <fence>                    one more backtick than the longest backtick run
#   <the captain's exact words, trailing newlines trimmed>
#   <fence>
#
# Refusals exit 2 and append nothing: an unknown subcommand or argument, a
# missing or malformed --task, an unreadable --words-file, a multi-line
# --goal, a terminal with no piped words, and an empty or whitespace-only
# ruling. I/O failures exit 1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="$FM_HOME/data"
LEDGER="$DATA/decisions.md"

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'fm-decision-log: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  add) shift ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown subcommand: $1 (expected 'add')" ;;
esac

TASK=
GOAL=
WORDS_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ "$#" -ge 2 ] || die "--task needs a value"
      TASK=$2
      shift 2
      ;;
    --task=*) TASK=${1#*=}; shift ;;
    --goal)
      [ "$#" -ge 2 ] || die "--goal needs a value"
      GOAL=$2
      shift 2
      ;;
    --goal=*) GOAL=${1#*=}; shift ;;
    --words-file)
      [ "$#" -ge 2 ] || die "--words-file needs a value"
      WORDS_FILE=$2
      shift 2
      ;;
    --words-file=*) WORDS_FILE=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$TASK" in
  ''|*[!A-Za-z0-9._-]*) die "--task must be a non-empty task id of letters, digits, dot, underscore, or dash" ;;
esac

if [ -n "$WORDS_FILE" ]; then
  [ -f "$WORDS_FILE" ] && [ -r "$WORDS_FILE" ] \
    || die "words file is not a readable regular file: $WORDS_FILE"
  words=$(cat -- "$WORDS_FILE") || die "cannot read words from $WORDS_FILE"
else
  [ -t 0 ] && die "no ruling words: pipe them on stdin or pass --words-file"
  words=$(cat) || die "cannot read words from stdin"
fi
[ -n "${words//[[:space:]]/}" ] || die "refusing to append an empty ruling"

if [ -z "$GOAL" ]; then
  GOAL=-
else
  case "$GOAL" in
    *$'\n'*) die "--goal must be a single line" ;;
  esac
fi

date=$(date -u +%F) || { echo "fm-decision-log: cannot read the clock" >&2; exit 1; }

# Fence long enough that the words can never close it: one backtick more than
# the longest backtick run inside them, minimum three.
runs=$(printf '%s' "$words" | awk '{
  while (match($0, /`+/)) {
    if (RLENGTH > m) m = RLENGTH
    $0 = substr($0, RSTART + RLENGTH)
  }
} END { print m + 1 }')
case "$runs" in ''|*[!0-9]*) runs=3 ;; esac
[ "$runs" -ge 3 ] || runs=3
fence=$(printf '%*s' "$runs" '' | tr ' ' '`')

if [ -L "$LEDGER" ]; then
  die "ledger is a symlink, refusing to append: $LEDGER"
fi
if [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]; then
  die "ledger exists and is not a regular file: $LEDGER"
fi
mkdir -p "$DATA" 2>/dev/null || { echo "fm-decision-log: cannot create $DATA" >&2; exit 1; }
touch "$LEDGER" 2>/dev/null || { echo "fm-decision-log: cannot create $LEDGER" >&2; exit 1; }

if [ ! -s "$LEDGER" ]; then
  {
    printf '# Decision ledger\n\n'
    printf 'Append-only chronology of the captain rulings, one entry per ruling, never edited or reordered. Format:\n\n'
    printf '## YYYY-MM-DD\n\n'
    printf -- '- Task: <the task id that implemented the ruling>\n'
    printf -- '- Goal: <the goal it serves, or ->\n\n'
    printf 'Words:\n\n'
    printf '```\n<the captain'"'"'s exact words>\n```\n'
  } >> "$LEDGER" || { echo "fm-decision-log: cannot write $LEDGER" >&2; exit 1; }
fi

# One blank line between entries, and a missing final newline repaired first,
# so every entry starts exactly one \n\n after the previous bytes.
prefix=$'\n'
if [ -n "$(tail -c 1 "$LEDGER" 2>/dev/null)" ]; then
  prefix=$'\n'"$prefix"
fi

entry=$(mktemp "$DATA/.decisions-entry.XXXXXX") || { echo "fm-decision-log: cannot stage an entry" >&2; exit 1; }
{
  printf '## %s\n\n' "$date"
  printf -- '- Task: %s\n' "$TASK"
  printf -- '- Goal: %s\n\n' "$GOAL"
  printf 'Words:\n\n'
  printf '%s\n' "$fence"
  printf '%s\n' "$words"
  printf '%s\n' "$fence"
} > "$entry" || { rm -f "$entry"; echo "fm-decision-log: cannot stage an entry" >&2; exit 1; }

{ printf '%s' "$prefix"; cat -- "$entry"; } >> "$LEDGER" \
  || { rm -f "$entry"; echo "fm-decision-log: cannot append to $LEDGER" >&2; exit 1; }
rm -f "$entry"

printf 'decision logged [%s] task=%s -> %s\n' "$date" "$TASK" "$LEDGER"
exit 0
