#!/usr/bin/env bash
# The ask-user self-answer guard's own suite: Rule A (close vs the
# steering-inbox delivery firstmate's answer path writes), Rule B (open keyed
# decision vs a run-record disposition), Rule C (disposition with no keyed
# decision at all), the secondmate exclusion, the once-per-finding record, and
# the arm/registration contract - every case against a fixture home and a
# fixture run record, never the machine's real state.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/fork/bin/fm-askuser-guard"
TMP_ROOT=$(fm_test_tmproot fm-fork-askuser-guard)
mkdir -p "$TMP_ROOT"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ok - skipped: sqlite3 is unavailable, so the run-record rules cannot be exercised"
  exit 0
fi

# ag_case <name>: a fresh fixture home and its empty fixture run record in
# HOME_DIR / DB.  ID is set separately per test.
HOME_DIR=
DB=
ID=
ag_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  DB="$CASE/runs.sqlite"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
  sqlite3 "$DB" <<'SQL'
CREATE TABLE runs (id TEXT PRIMARY KEY, branch TEXT, created_at INTEGER);
CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT, approval_reason TEXT, skip_reason TEXT);
CREATE TABLE step_rounds (step_result_id TEXT, findings_json TEXT, selected_finding_ids TEXT, selection_source TEXT);
SQL
}

# ag_meta <id> <branch> <spawn-epoch>
ag_meta() {
  printf '%s\n' "kind=ship" "branch=$2" "spawn_gen=s$3.1.1" > "$HOME_DIR/state/$1.meta"
}

# ag_status <id>: stdin becomes the task's status log.
ag_status() {
  cat > "$HOME_DIR/state/$1.status"
}

# ag_inbox <id> <name>: stdin becomes one steering-inbox record body.
ag_inbox() {
  mkdir -p "$HOME_DIR/state/$1.inbox/handled"
  {
    printf 'schema=fm-task-inbox.v1\n'
    printf 'at=2026-10-29T00:00:00Z\n'
    printf 'body-terminator=1\n'
    printf -- '--\n'
    cat
  } > "$HOME_DIR/state/$1.inbox/handled/$2.msg"
}

# ag_disposition <run> <branch> <created-at> <step> <finding>: the run record
# of a review round whose ask-user finding was selected by the driver.
ag_disposition() {
  sqlite3 "$DB" <<SQL
INSERT INTO runs VALUES ('$1', '$2', $3);
INSERT INTO step_results VALUES ('sr-$1-$4', '$1', '$4', NULL, NULL);
INSERT INTO step_rounds VALUES ('sr-$1-$4', '{"findings":[{"id":"$5","severity":"info","action":"ask-user"}]}', '["$5"]', 'user');
SQL
}

# ag_parked <run> <branch> <created-at> <step> <finding>: ask-user findings
# presented at a gate that is still parked (no selection, no approval).
ag_parked() {
  sqlite3 "$DB" <<SQL
INSERT INTO runs VALUES ('$1', '$2', $3);
INSERT INTO step_results VALUES ('sr-$1-$4', '$1', '$4', NULL, NULL);
INSERT INTO step_rounds VALUES ('sr-$1-$4', '{"findings":[{"id":"$5","severity":"info","action":"ask-user"}]}', NULL, NULL);
SQL
}

# ag_check <id>: run the guard; OUT holds its combined output, RC its code.
OUT=
RC=0
ag_check() {
  OUT=$(FM_HOME="$HOME_DIR" FM_ASKUSER_GUARD_DB="$DB" "$GUARD" check "$1" 2>&1)
  RC=$?
}

test_absent_records_are_silent() {
  ag_case absent
  ag_check no-such-task
  assert_equals 0 "$RC" "an absent task must not error"
  assert_equals "" "$OUT" "an absent task must print nothing"
  pass "absent: a check with no status or record for its task is silent"
}

test_clean_task_is_silent() {
  ag_case clean
  ID=ag-clean
  ag_meta "$ID" "fm/ag-clean" 1000
  ag_status "$ID" <<'EOF'
working [at=900]: implementing
paused [at=950]: driving the pipeline
EOF
  ag_check "$ID"
  assert_equals "" "$OUT" "a task with no keyed decision must print nothing"
  pass "clean: ordinary status lines produce silence"
}

test_backed_close_is_silent() {
  ag_case backed
  ID=ag-backed
  ag_meta "$ID" "fm/ag-backed" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-BACKED1-review]: ask-user findings=f1 file=/x
resolved [key=nm-BACKED1-review] [at=200]: answered: Keep the three verdict outputs as the shared contract for the next slice.
EOF
  # The answer travelled as one steering-inbox record whose body wraps across
  # lines; fm-send's excerpt is the same text with newlines normalised to
  # spaces, so the pairing must survive the wrap.
  ag_inbox "$ID" 001 <<'EOF'
Keep the three verdict outputs as the shared
contract for the next slice.
EOF
  ag_disposition BACKED1 "fm/ag-backed" 950 review f1
  ag_check "$ID"
  assert_equals "" "$OUT" "a backed close and its disposition must print nothing"
  pass "backed: an fm-send close paired with its steering-inbox delivery is silent"
}

test_unbacked_close_fires_once() {
  ag_case unbacked
  ID=ag-unbacked
  ag_meta "$ID" "fm/ag-unbacked" 1000
  ag_status "$ID" <<'EOF'
resolved [key=nm-FORGED1-review] [at=200]: answered: DECLINE the code expansion, keep the documentation-only remedy.
EOF
  ag_check "$ID"
  assert_contains "$OUT" "no steering-inbox delivery" "an answered close with no delivery must be surfaced"
  assert_contains "$OUT" "nm-FORGED1-review" "the finding must name its key"
  assert_equals 0 "$RC" "a finding must not change the exit code"
  ag_check "$ID"
  assert_equals "" "$OUT" "the same finding must print only once (record dedup)"
  # A changed answer text on the same key is a new finding.
  ag_status "$ID" <<'EOF'
resolved [key=nm-FORGED1-review] [at=260]: answered: A different decision entirely, recorded by hand.
EOF
  ag_check "$ID"
  assert_contains "$OUT" "no steering-inbox delivery" "a changed answer text must surface as a new finding"
  pass "unbacked: a hand-written close wakes once per answer text"
}

test_prose_close_never_covers() {
  ag_case prose
  ID=ag-prose
  ag_meta "$ID" "fm/ag-prose" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-PROSE1-ci]: ask-user findings=ci-1 file=/x
resolved [key=nm-PROSE1-ci] [at=180]: reattached to the run; still waiting for firstmate
EOF
  ag_disposition PROSE1 "fm/ag-prose" 950 ci ci-1
  ag_check "$ID"
  assert_contains "$OUT" "while no firstmate close exists" "a prose note must not cover a dispositioned decision"
  assert_not_contains "$OUT" "steering-inbox" "a prose note is not an answered close, so Rule A must not judge it"
  pass "prose: a worker's own wait note never covers a keyed decision"
}

test_open_gate_without_disposition_is_silent() {
  ag_case parked
  ID=ag-parked
  ag_meta "$ID" "fm/ag-parked" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-PARKED1-review]: ask-user findings=f2 file=/x
paused [at=160] [key=nm-PARKED1-review]: holding for the decision
EOF
  ag_parked PARKED1 "fm/ag-parked" 950 review f2
  ag_check "$ID"
  assert_equals "" "$OUT" "a parked ask-user gate awaiting a decision must be silent"
  pass "parked: an open keyed decision with no disposition is the normal wait"
}

test_disposition_of_open_decision_fires_rule_b() {
  ag_case openfire
  ID=ag-openfire
  ag_meta "$ID" "fm/ag-openfire" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-OPEN1-ci]: ask-user findings=ci-1 file=/x
EOF
  ag_disposition OPEN1 "fm/ag-openfire" 950 ci ci-1
  ag_check "$ID"
  assert_contains "$OUT" "dispositioned in run OPEN1 while no firstmate close" "a disposition of an open keyed decision must be surfaced"
  assert_not_contains "$OUT" "no keyed decision" "the escalation exists, so Rule C must not also fire"
  ag_check "$ID"
  assert_equals "" "$OUT" "the Rule B finding must print only once"
  pass "open-gate: answering a keyed decision that firstmate never closed is surfaced"
}

test_captain_held_transfer_covers() {
  ag_case held
  ID=ag-held
  ag_meta "$ID" "fm/ag-held" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-HELD1-review]: ask-user findings=f1 file=/x
captain-held [key=nm-HELD1-review]: tracked by ag-held-decision-nm-HELD1-review
EOF
  ag_disposition HELD1 "fm/ag-held" 950 review f1
  ag_check "$ID"
  assert_equals "" "$OUT" "a verified captain-held transfer must count as coverage"
  pass "held: firstmate's verified transfer close satisfies the guard"
}

test_unescalated_disposition_fires_rule_c() {
  ag_case unescalated
  ID=ag-unescalated
  ag_meta "$ID" "fm/ag-unescalated" 1000
  ag_status "$ID" <<'EOF'
working [at=900]: nothing keyed was ever reported here
EOF
  ag_disposition SILENT1 "fm/ag-unescalated" 950 review f9
  ag_check "$ID"
  assert_contains "$OUT" "no keyed decision or firstmate close" "an unescalated disposition must be surfaced"
  assert_contains "$OUT" "SILENT1" "the finding must name the run"
  pass "unescalated: a disposition with no keyed decision anywhere is surfaced"
}

test_rule_c_respects_spawn_epoch() {
  ag_case epoch
  ID=ag-epoch
  ag_meta "$ID" "fm/ag-epoch" 1000
  ag_status "$ID" <<'EOF'
working [at=900]: a reused task id with an older same-named run
EOF
  # Created before spawn-600: this run belongs to an earlier incarnation of
  # the branch name, not to this task.
  ag_disposition OLD1 "fm/ag-epoch" 399 review f9
  ag_check "$ID"
  assert_equals "" "$OUT" "a run older than the spawn window must not be judged"
  pass "epoch: Rule C only judges runs from this task's own incarnation"
}

test_secondmate_is_never_evaluated() {
  ag_case mate
  ID=ag-mate
  printf '%s\n' "kind=secondmate" "branch=fm/ag-mate" "spawn_gen=s1000.1.1" > "$HOME_DIR/state/$ID.meta"
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-MATE1-ci]: ask-user findings=ci-1 file=/x
resolved [key=nm-MATE1-ci] [at=200]: answered: a close written without any inbox record at all
EOF
  ag_disposition MATE1 "fm/ag-mate" 950 ci ci-1
  ag_check "$ID"
  assert_equals "" "$OUT" "a secondmate task record must never be judged"
  pass "secondmate: the pairing rule does not cross the remote-inbox boundary"
}

test_missing_run_record_reports_once() {
  ag_case norecord
  ID=ag-norecord
  ag_meta "$ID" "fm/ag-norecord" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=nm-NOREC1-ci]: ask-user findings=ci-1 file=/x
EOF
  OUT=$(FM_HOME="$HOME_DIR" FM_ASKUSER_GUARD_DB="$DB.does-not-exist" "$GUARD" check "$ID" 2>&1)
  assert_contains "$OUT" "run record cannot be read" "an unreadable run record behind an open decision must be surfaced"
  OUT=$(FM_HOME="$HOME_DIR" FM_ASKUSER_GUARD_DB="$DB.does-not-exist" "$GUARD" check "$ID" 2>&1)
  assert_equals "" "$OUT" "the degradation must print only once"
  pass "gap: a missing run record is a visible once-only finding, never silence"
}

test_non_nm_keys_are_out_of_scope() {
  ag_case nonnm
  ID=ag-nonnm
  ag_meta "$ID" "fm/ag-nonnm" 1000
  ag_status "$ID" <<'EOF'
needs-decision [at=150] [key=api-shape]: which field carries the cursor?
resolved [key=api-shape] [at=200]: answered: use an opaque cursor string
EOF
  ag_check "$ID"
  assert_equals "" "$OUT" "non-nm decision keys are outside this seam"
  pass "scope: only nm- run decisions are judged"
}

test_arm_writes_and_registers_the_check() {
  ag_case arm
  ID=ag-arm
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$GUARD" arm "$ID" || fail "arm must succeed for a valid task id"
  local check="$HOME_DIR/state/$ID.check.sh"
  assert_present "$check" "arm must write state/<id>.check.sh"
  # The watcher's own registration verdict: mode 700, hash-bound, and the
  # trust record matching the shim bytes.
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$ROOT/bin/fm-check-lib.sh"
  fm_custom_check_registered "$HOME_DIR/state" "$ID" || fail "the armed check must register with bin/fm-check-register.sh"
  assert_grep "check $ID" "$check" "the shim must exec the guard's check for its task"
  # Re-arming (a relaunch) must stay registered, not strand a stale binding.
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$GUARD" arm "$ID" || fail "re-arm must succeed"
  fm_custom_check_registered "$HOME_DIR/state" "$ID" || fail "a re-armed check must still be registered"
  # The shim itself is the watcher's entry point: run it the way the sweep
  # does and prove the baked environment selects this fixture home.
  ag_status "$ID" <<'EOF'
resolved [key=nm-ARMSHAM-review] [at=200]: answered: a close with nothing behind it
EOF
  OUT=$(FM_ASKUSER_GUARD_DB="$DB" bash "$check" 2>&1)
  assert_contains "$OUT" "no steering-inbox delivery" "the registered shim must run the guard against its own home"
  # arm refuses unusable input rather than registering something else.
  FM_HOME=relative/path "$GUARD" arm "$ID.bad" 2>/dev/null
  assert_equals 2 $? "arm must refuse a relative home or invalid id"
  pass "arm: launch-time arming writes a registered, self-contained watcher check"
}

fork_run_tests
