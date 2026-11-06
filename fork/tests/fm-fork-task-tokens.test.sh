#!/usr/bin/env bash
# Behavioral coverage for fork/bin/fm-task-tokens: the read-only reader's
# aggregation rules proven against fixture stores - a pi session summed and a
# relaunch adding instead of overwriting, a claude transcript rendering the
# columns claude does not record as dash, a pi session with no usage at all
# rendering every token column dash, a task switching harness joining both
# stores, the opencode database pinned through the launcher (the stale
# sibling ignored), the rolling window, an unreadable session skipped and
# named without failing the report, the by-kind and by-model rollups, the
# documented header, the fm-task-tokens.v1 JSON document, usage refusals, and
# the promise that the reader writes nothing. All fixtures live under a
# throwaway HOME/FM_HOME; nothing here touches the network or real stores.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/fork/bin/fm-task-tokens"
TMP_ROOT=$(fm_test_tmproot fm-task-tokens)

# The counting rules are asserted through the --json document; without jq
# there is no precise surface to assert them on.
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required for the json assertions)"; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found (required for the opencode fixture)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the reader)"; exit 0; }

new_home() { # -> path of a fresh fixture home with every store root present
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX") || fail "cannot create a fixture home"
  mkdir -p "$h/state" "$h/.pi/agent/sessions/--fixture--" \
    "$h/.claude/projects/--fixture--" "$h/.local/share/opencode" "$h/.local/bin"
  printf '%s' "$h"
}

run_reader() { # <home> [args...] -> stdout, exit status preserved by caller
  local h=$1
  shift
  HOME="$h" FM_HOME="$h" OPENCODE_DB='' bash "$READER" "$@"
}

jq_ok() { # <json> <jq-expr> <label>
  printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1 || fail "$3"$'\n'"json: $1"
}

row_of() { # <human-output> <task-id> -> the row, whitespace collapsed
  printf '%s\n' "$1" | grep "^$2 " | awk '{$1=$1; print}' | head -1
}

pi_session() { # <home> <file-name> <task-id> <usage-json-or-empty>
  local home=$1 name=$2 task=$3 usage=$4
  local dir="$home/.pi/agent/sessions/--fixture--"
  {
    printf '%s\n' '{"type":"session","version":3,"id":"fixture","timestamp":"2026-11-06T00:00:00.000Z","cwd":"/fixture"}'
    printf '%s\n' "{\"type\":\"message\",\"id\":\"u1\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"FIRSTMATE_OP: v1 launch-brief state/$task.inbox\"}]}}"
    if [ -n "$usage" ]; then
      printf '%s\n' "{\"type\":\"message\",\"id\":\"a1\",\"message\":{\"role\":\"assistant\",\"model\":\"fixture-model\",\"usage\":$usage}}"
    else
      printf '%s\n' '{"type":"message","id":"a1","message":{"role":"assistant","model":"fixture-model","content":[]}}'
    fi
  } > "$dir/$name"
  printf '%s\n' "$dir/$name"
}

claude_session() { # <home> <file-name> <task-id> <usage-json-or-empty>
  local home=$1 name=$2 task=$3 usage=$4
  local dir="$home/.claude/projects/--fixture--"
  {
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"FIRSTMATE_OP: v1 launch-brief state/$task.inbox\"}]}}"
    if [ -n "$usage" ]; then
      printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-fixture\",\"usage\":$usage}}"
    else
      printf '%s\n' '{"type":"assistant","message":{"role":"assistant","model":"claude-fixture","content":[]}}'
    fi
  } > "$dir/$name"
  printf '%s\n' "$dir/$name"
}

opencode_dbs() { # <home>: a pinned v1 database plus a stale sibling, and the launcher pinning v1
  local h=$1 dir now_ms
  dir="$h/.local/share/opencode"
  now_ms=$(( $(date +%s) * 1000 ))
  sqlite3 "$dir/opencode-v1.db" <<SQL
CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT, directory TEXT,
  tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
  tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL,
  time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
INSERT INTO session VALUES ('ses-pin', '{"id":"oc-fixture","providerID":"test"}', '/fixture',
  11, 22, 33, 44, 55, 0.75, $now_ms, $now_ms);
INSERT INTO message VALUES ('msg-pin', 'ses-pin', $now_ms, '{"role":"user","time":$now_ms}');
INSERT INTO part VALUES ('part-pin', 'msg-pin', 'ses-pin', $now_ms,
  '{"type":"text","text":"FIRSTMATE_OP: v1 launch-brief state/oc-c1.inbox"}');
SQL
  sqlite3 "$dir/opencode.db" <<SQL
CREATE TABLE session (id TEXT PRIMARY KEY, model TEXT, directory TEXT,
  tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
  tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL,
  time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
INSERT INTO session VALUES ('ses-stale', '{"id":"stale-model","providerID":"test"}', '/fixture',
  999999, 999999, 999999, 999999, 999999, 9.99, $now_ms, $now_ms);
INSERT INTO message VALUES ('msg-stale', 'ses-stale', $now_ms, '{"role":"user","time":$now_ms}');
INSERT INTO part VALUES ('part-stale', 'msg-stale', 'ses-stale', $now_ms,
  '{"type":"text","text":"FIRSTMATE_OP: v1 launch-brief state/stale-c1.inbox"}');
SQL
  cat > "$h/.local/bin/opencode" <<'LAUNCH'
#!/bin/sh
: "${OPENCODE_DB:=$HOME/.local/share/opencode/opencode-v1.db}"
export OPENCODE_DB
exec /bin/true "$@"
LAUNCH
}

test_pi_session_sums_and_relaunch_adds() {
  local h out row
  h=$(new_home)
  fm_write_meta "$h/state/alpha.meta" "kind=ship" "model=test-model" "harness=pi"
  pi_session "$h" "2026-11-06T00-00-00-000Z_a.jsonl" alpha \
    '{"input":100,"output":50,"cacheRead":1000,"cacheWrite":200,"reasoning":30,"totalTokens":1380,"cost":{"total":0.25}}' >/dev/null
  pi_session "$h" "2026-11-06T01-00-00-000Z_b.jsonl" alpha \
    '{"input":10,"output":5,"cacheRead":80,"cacheWrite":20,"reasoning":5,"totalTokens":115,"cost":{"total":0.05}}' >/dev/null

  out=$(run_reader "$h") || fail "the reader must exit 0"
  assert_contains "$out" "task token and cost figures for the last 7 days" "header names the window"
  assert_contains "$out" "What each column counts:" "the column legend is printed"
  assert_contains "$out" "prompt tokens sent to the model" "the input column is explained"
  assert_contains "$out" "recorded spend in US dollars" "the cost column is explained"
  row=$(row_of "$out" alpha)
  [ "$row" = "alpha ship pi test-model 110 55 1,300 35 1,500 0.3" ] \
    || fail "unexpected alpha row: '$row'"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks | length == 1' "one task in the document"
  jq_ok "$out" '.tasks[0] | .sessions == 2 and .input == 110 and .output == 55 and .cache == 1300 and .reasoning == 35 and .total == 1500 and .cost == 0.3' \
    "the relaunch's second session adds to the first"
  jq_ok "$out" '.tasks[0] | .kind == "ship" and .model == "test-model" and .harness == "pi"' \
    "kind, model, and harness fill the row"
  pass "a pi session sums and a relaunch adds instead of overwriting"
}

test_claude_session_renders_unrecorded_columns_dash() {
  local h out row
  h=$(new_home)
  fm_write_meta "$h/state/beta.meta" "kind=scout" "model=claude-fixture" "harness=claude"
  claude_session "$h" "b.jsonl" beta \
    '{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}' >/dev/null

  out=$(run_reader "$h") || fail "the reader must exit 0"
  row=$(row_of "$out" beta)
  [ "$row" = "beta scout claude claude-fixture 10 20 70 - 100 -" ] \
    || fail "claude must render reasoning and cost as dash: '$row'"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[0] | .reasoning == null and .cost == null and .total == 100' \
    "unrecorded columns are null in json and the total still adds up"
  pass "a claude transcript renders the columns it does not record as dash"
}

test_session_without_usage_renders_every_token_column_dash() {
  local h out row
  h=$(new_home)
  pi_session "$h" "nu.jsonl" nousage '' >/dev/null

  out=$(run_reader "$h") || fail "a session without usage must not fail the report"
  row=$(row_of "$out" nousage)
  [ "$row" = "nousage - pi - - - - - - -" ] \
    || fail "a task with no recorded usage must render dashes: '$row'"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[0] | .input == null and .output == null and .cache == null and .reasoning == null and .total == null and .cost == null' \
    "every token column is null when no usage was recorded"
  jq_ok "$out" '.tasks[0] | .kind == null and .model == null' \
    "absent task facts are null"
  pass "a session whose messages record no usage renders every token column dash"
}

test_task_switching_harness_joins_both_stores() {
  local h out row
  h=$(new_home)
  fm_write_meta "$h/state/gamma.meta" "kind=scout" "model=mixed-model"
  pi_session "$h" "g.jsonl" gamma \
    '{"input":100,"output":50,"cacheRead":80,"cacheWrite":20,"reasoning":5,"totalTokens":155,"cost":{"total":0.5}}' >/dev/null
  claude_session "$h" "g2.jsonl" gamma \
    '{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}' >/dev/null

  out=$(run_reader "$h") || fail "the reader must exit 0"
  row=$(row_of "$out" gamma)
  [ "$row" = "gamma scout claude+pi mixed-model 110 70 170 5 355 0.5" ] \
    || fail "unexpected mixed-harness row: '$row'"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.tasks[0] | .harness == "claude+pi" and .input == 110 and .output == 70 and .cache == 170 and .total == 355 and .cost == 0.5' \
    "both stores sum into one row and the cost covers the store that records it"
  pass "a task that switched harness joins both stores into one row"
}

test_opencode_reads_the_pinned_database_not_the_stale_one() {
  local h out row
  h=$(new_home)
  fm_write_meta "$h/state/oc-c1.meta" "kind=ship" "model=oc-fixture"
  opencode_dbs "$h"

  out=$(run_reader "$h") || fail "the reader must exit 0"
  assert_contains "$out" "$h/.local/share/opencode/opencode-v1.db" \
    "the pinned opencode database is named in the output"
  if printf '%s\n' "$out" | grep -q 'share/opencode/opencode\.db'; then
    fail "the stale opencode database must not be read or named"
  fi
  row=$(row_of "$out" oc-c1)
  [ "$row" = "oc-c1 ship opencode oc-fixture 11 22 99 33 165 0.75" ] \
    || fail "unexpected opencode row: '$row'"
  [ -z "$(row_of "$out" stale-c1)" ] || fail "the stale database's task must not appear"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.sources.opencode_db == "'"$h"'/.local/share/opencode/opencode-v1.db" and .sources.opencode_db_read == true' \
    "the json sources name the pinned database"
  pass "opencode rows come from the launcher-pinned database, never the stale sibling"
}

test_window_excludes_sessions_outside_it() {
  local h out
  h=$(new_home)
  pi_session "$h" "old.jsonl" oldtask \
    '{"input":7,"output":7,"cacheRead":7,"cacheWrite":0,"reasoning":0,"totalTokens":21,"cost":{"total":0.01}}' >/dev/null
  touch -t 202610100000 "$h/.pi/agent/sessions/--fixture--/old.jsonl"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '(.tasks | length) == 0' "the default 7-day window excludes the old session"

  out=$(run_reader "$h" --days 40 --json) || fail "--days 40 must exit 0"
  jq_ok "$out" '(.tasks | map(.task)) == ["oldtask"]' \
    "a wider window brings the old session back"
  pass "the window reads session mtimes and excludes sessions outside it"
}

test_unreadable_session_is_skipped_and_named() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/ok.meta" "kind=ship" "model=test-model"
  pi_session "$h" "ok.jsonl" ok \
    '{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5,"totalTokens":15,"cost":{"total":0.1}}' >/dev/null
  # A directory wearing a .jsonl name cannot be read as a session file.
  mkdir -p "$h/.pi/agent/sessions/--fixture--/bad.jsonl"
  # A readable session whose brief names no task is silently not a task session.
  printf '%s\n' 'not a firstmate brief at all' \
    > "$h/.pi/agent/sessions/--fixture--/unbriefed.jsonl"

  out=$(run_reader "$h") || fail "an unreadable session must not fail the report"
  assert_contains "$out" "skipped (unreadable session or store):" "the skip section is printed"
  assert_contains "$out" "bad.jsonl: cannot read" "the unreadable session is named with its reason"
  [ "$(printf '%s\n' "$out" | grep -c 'bad.jsonl: cannot read')" = 1 ] \
    || fail "the unreadable session must be named exactly once"
  [ -n "$(row_of "$out" ok)" ] || fail "the healthy session must still be rowed"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.skipped | length == 1' "the skip is in the document"
  jq_ok "$out" '.tasks | length == 1' "only the attributable healthy task is rowed"
  pass "an unreadable session is skipped, named once, and never fails the report"
}

test_rollups_sum_by_kind_and_by_model() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/one.meta" "kind=ship" "model=model-a"
  fm_write_meta "$h/state/two.meta" "kind=ship" "model=model-b"
  fm_write_meta "$h/state/three.meta" "kind=scout" "model=model-a"
  pi_session "$h" "1.jsonl" one \
    '{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5,"totalTokens":15,"cost":{"total":0.5}}' >/dev/null
  pi_session "$h" "2.jsonl" two \
    '{"input":10,"output":20,"cacheRead":30,"cacheWrite":40,"reasoning":50,"totalTokens":150,"cost":{"total":0.25}}' >/dev/null
  pi_session "$h" "3.jsonl" three \
    '{"input":100,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":100,"cost":{"total":0.125}}' >/dev/null

  out=$(run_reader "$h") || fail "the reader must exit 0"
  assert_contains "$out" "by kind:" "the by-kind section exists"
  assert_contains "$out" "by model:" "the by-model section exists"

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  jq_ok "$out" '.by_kind[] | select(.kind == "ship") | .tasks == 2 and .input == 11 and .output == 22 and .cache == 77 and .reasoning == 55 and .total == 165 and .cost == 0.75' \
    "the ship rollup sums its rows"
  jq_ok "$out" '.by_kind[] | select(.kind == "scout") | .tasks == 1 and .input == 100' \
    "the scout rollup counts its rows"
  jq_ok "$out" '.by_model[] | select(.model == "model-a") | .tasks == 2 and .input == 101 and .cost == 0.625' \
    "the by-model rollup groups across kinds"
  pass "totals by kind and by model sum the rows of each group"
}

test_json_document_shape_and_legend() {
  local h out
  h=$(new_home)
  fm_write_meta "$h/state/shape.meta" "kind=ship" "model=test-model"
  pi_session "$h" "s.jsonl" shape \
    '{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5,"totalTokens":15,"cost":{"total":0.5}}' >/dev/null

  out=$(run_reader "$h" --json) || fail "json mode must exit 0"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "output must parse as one json document"
  jq_ok "$out" '.schema == "fm-task-tokens.v1"' "the schema tag is present"
  jq_ok "$out" '.columns.total | contains("four token columns add up")' \
    "the json legend explains total"
  jq_ok "$out" '.columns.cost | contains("mixing stores")' \
    "the json legend explains cost"
  jq_ok "$out" '.generated_at > 0 and .days == 7 and .cutoff_epoch > 0' \
    "the window metadata is present"
  jq_ok "$out" '.sources.pi_sessions != null and .sources.claude_sessions != null' \
    "the sources name the session stores"
  jq_ok "$out" '.skipped == []' "no skips for a complete fixture"
  pass "the json document carries the schema, legend, sources, and window"
}

test_reader_writes_nothing() {
  local h marker newer out
  h=$(new_home)
  fm_write_meta "$h/state/w.meta" "kind=ship" "model=test-model"
  pi_session "$h" "w.jsonl" w \
    '{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"reasoning":5,"totalTokens":15,"cost":{"total":0.5}}' >/dev/null
  claude_session "$h" "w2.jsonl" w \
    '{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}' >/dev/null
  opencode_dbs "$h"

  marker="$h/.marker"
  touch "$marker"
  out=$(run_reader "$h") || fail "the reader must exit 0"
  newer=$(find "$h" -type f -newer "$marker" -print)
  [ -z "$newer" ] || fail "the reader must write nothing, but these files are new:$newer"
  pass "the reader writes nothing into the home it reads"
}

test_usage_refusals() {
  local h rc out
  h=$(new_home)
  run_reader "$h" --days 0 >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "--days 0 must be refused"
  run_reader "$h" --days soon >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a non-numeric --days must be refused"
  run_reader "$h" --bogus >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "an unknown argument must be refused"
  HOME="$h" FM_HOME="$TMP_ROOT/absent-home" bash "$READER" >/dev/null 2>&1
  rc=$?
  expect_code 1 "$rc" "a missing state directory must be refused loudly"
  out=$(bash "$READER" --help) || fail "--help must exit 0"
  assert_contains "$out" "Usage:" "--help prints the usage block"
  assert_contains "$out" "no network, no writes" "--help states the read-only contract"
  pass "usage refusals exit with the documented codes"
}

fork_run_tests
