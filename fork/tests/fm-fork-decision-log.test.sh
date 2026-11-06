#!/usr/bin/env bash
# Behavioral coverage for fork/bin/fm-decision-log: ledger creation with its
# format header on first use, add via stdin and via --words-file, verbatim
# multi-line words (quotes, backslashes, and a backtick run that must grow
# the fence), the goal field passed or defaulted to -, append-only
# preservation of every byte already in the ledger across later appends,
# refusal of an empty or whitespace-only ruling with the ledger untouched,
# refusal of a missing or malformed --task, an unreadable --words-file, a
# multi-line --goal, unknown subcommands and arguments, a symlinked ledger,
# and the --help contract that owns the chronology-versus-distilled-rules
# distinction. Fixtures are throwaway FM_HOME directories; no network.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISION_LOG="$ROOT/fork/bin/fm-decision-log"
TMP_ROOT=$(fm_test_tmproot fm-decision-log)
TODAY=$(date -u +%F)

new_home() { # -> path of a fresh fixture home
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX") || fail "cannot create a fixture home"
  mkdir -p "$h/state" "$h/data"
  printf '%s' "$h"
}

run_log() { # <home> [args...] -> stdout, exit status preserved by caller
  local h=$1
  shift
  FM_HOME="$h" bash "$DECISION_LOG" "$@"
}

ledger_of() { printf '%s' "$1/data/decisions.md"; }

entry_words() { # <ledger> <task> -> that entry's words block
  awk -v task="$2" '
    $0 == "- Task: " task { inentry = 1 }
    inentry && $0 == "Words:" { want = 1; next }
    want && /^`+$/ {
      if (fence == "") { fence = $0; next }
      exit
    }
    want && fence != "" { print }
  ' "$1"
}

test_first_add_creates_header_and_entry_from_stdin() {
  local h out l words
  h=$(new_home)
  out=$(printf 'Never merge a red PR.\nKeep the ledger append-only.\n' \
    | run_log "$h" add --task fm-ledger-1 --goal "keep merges honest") \
    || fail "the first add must succeed"
  assert_contains "$out" "decision logged [$TODAY] task=fm-ledger-1" \
    "the confirmation names the date and task"
  l=$(ledger_of "$h")
  assert_present "$l" "the ledger is created on first use"
  assert_contains "$(cat "$l")" "# Decision ledger" "the created file carries its format header"
  assert_contains "$(cat "$l")" "## $TODAY" "the entry is dated today in UTC"
  assert_contains "$(cat "$l")" "- Task: fm-ledger-1" "the entry names the implementing task"
  assert_contains "$(cat "$l")" "- Goal: keep merges honest" "the entry carries the goal"
  words=$(entry_words "$l" fm-ledger-1)
  [ "$words" = $'Never merge a red PR.\nKeep the ledger append-only.' ] \
    || fail "words must be verbatim: got '$words'"
  pass "the first add creates the header and appends a verbatim entry"
}

test_words_file_keeps_bytes_and_fence_grows_for_backticks() {
  local h l words
  h=$(new_home)
  printf 'He said "ship it" and meant it.\nUse a ``` inline fence if needed.\npath C:\\tmp\\file\n' \
    > "$TMP_ROOT/words.txt"
  run_log "$h" add --task fm-ledger-2 --words-file "$TMP_ROOT/words.txt" >/dev/null \
    || fail "add with --words-file must succeed"
  l=$(ledger_of "$h")
  words=$(entry_words "$l" fm-ledger-2)
  [ "$words" = $'He said "ship it" and meant it.\nUse a ``` inline fence if needed.\npath C:\\tmp\\file' ] \
    || fail "file words must be verbatim: got '$words'"
  grep -Fx '````' "$l" >/dev/null \
    || fail "a three-backtick run in the words must grow the fence to four"
  grep -Fx '```' "$l" >/dev/null \
    || fail "the header example fence stays three backticks"
  pass "words from a file stay verbatim and the fence grows around them"
}

test_goal_defaults_to_dash() {
  local h
  h=$(new_home)
  printf 'Always ask before a destructive merge.\n' \
    | run_log "$h" add --task fm-ledger-3 >/dev/null \
    || fail "add without --goal must succeed"
  assert_contains "$(cat "$(ledger_of "$h")")" "- Goal: -" \
    "a ruling without a stated goal records a dash"
  pass "the goal field defaults to a dash when none is given"
}

test_ledger_is_append_only_across_entries() {
  local h l size0 size1 size2
  h=$(new_home)
  l=$(ledger_of "$h")
  # A pre-existing ledger without the header keeps its bytes: the header is
  # written only when the file is empty, and never into existing content.
  printf 'PREEXISTING CONTENT WITHOUT NEWLINE' > "$l"
  size0=$(wc -c < "$l" | tr -d ' ')
  printf 'First ruling stands.\n' | run_log "$h" add --task fm-first >/dev/null \
    || fail "the first append must succeed"
  [ "$(head -c "$size0" "$l")" = "PREEXISTING CONTENT WITHOUT NEWLINE" ] \
    || fail "existing bytes must be preserved exactly"
  assert_not_contains "$(cat "$l")" "# Decision ledger" \
    "a non-empty ledger never gains the created-file header"
  size1=$(wc -c < "$l" | tr -d ' ')
  cp "$l" "$TMP_ROOT/after-first"

  printf 'Second ruling appends.\n' | run_log "$h" add --task fm-second >/dev/null \
    || fail "the second append must succeed"
  size2=$(wc -c < "$l" | tr -d ' ')
  [ "$size2" -gt "$size1" ] || fail "the ledger must grow with the second entry"
  head -c "$size1" "$l" | cmp -s - "$TMP_ROOT/after-first" \
    || fail "the second append must not disturb earlier bytes"
  [ "$(grep -c '^## ' "$l")" = 2 ] \
    || fail "two adds must leave exactly two entry headings"
  pass "later appends never disturb bytes already in the ledger"
}

test_empty_ruling_is_refused_and_ledger_untouched() {
  local h l before
  h=$(new_home)
  l=$(ledger_of "$h")
  printf 'A real ruling exists.\n' | run_log "$h" add --task fm-real >/dev/null \
    || fail "the seeding add must succeed"
  before=$(cksum < "$l")

  run_log "$h" add --task fm-empty <<< '   ' >/dev/null 2>&1
  expect_code 2 "$?" "whitespace-only stdin must be refused"
  : > "$TMP_ROOT/empty.txt"
  run_log "$h" add --task fm-empty --words-file "$TMP_ROOT/empty.txt" >/dev/null 2>&1
  expect_code 2 "$?" "an empty words file must be refused"
  [ "$(cksum < "$l")" = "$before" ] \
    || fail "a refused ruling must leave the ledger byte-identical"
  pass "an empty ruling is refused with the ledger untouched"
}

test_argument_refusals() {
  local h rc target
  h=$(new_home)
  run_log "$h" add <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "a missing --task must be refused"
  run_log "$h" add --task 'bad task id' <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "a malformed --task must be refused"
  run_log "$h" drop <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "an unknown subcommand must be refused"
  run_log "$h" add --task fm-x --bogus <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "an unknown argument must be refused"
  run_log "$h" add --task fm-x --goal $'two\nlines' <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "a multi-line --goal must be refused"
  run_log "$h" add --task fm-x --words-file "$TMP_ROOT/nope.txt" <<< 'words' >/dev/null 2>&1
  expect_code 2 "$?" "an unreadable --words-file must be refused"

  target="$TMP_ROOT/elsewhere.md"
  printf 'untouched target\n' > "$target"
  ln -s "$target" "$(ledger_of "$h")"
  run_log "$h" add --task fm-symlink <<< 'words' >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a symlinked ledger must be refused"
  [ "$(cat "$target")" = "untouched target" ] \
    || fail "the symlink target must stay untouched"
  pass "every documented refusal exits 2 without writing"
}

test_help_owns_the_contract() {
  local out
  out=$(bash "$DECISION_LOG" --help) || fail "--help must exit 0"
  assert_contains "$out" "Usage:" "--help prints the usage block"
  assert_contains "$out" "data/decisions.md" "--help names the ledger location"
  assert_contains "$out" "CHRONOLOGY" "--help states the ledger is the chronology"
  assert_contains "$out" "DISTILLED" "--help states the preference file stays the distilled rules"
  assert_contains "$out" "## <YYYY-MM-DD>" "--help documents the entry format"
  pass "--help documents the location, the distinction, and the entry format"
}

fork_run_tests
