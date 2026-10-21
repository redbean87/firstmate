#!/usr/bin/env bash
# tests/fm-owner-only-writes.test.sh - durable owner-only CREATION under
# FM_HOME/data and FM_HOME/state at the central write chokepoints.
#
# The one-time permission sweep drifts back to 644/755 whenever a fleet process
# recreates a file under the ambient umask 0022 (report 8b of
# data/fm-workflow-perm-plan-c1), so the invariant has to live at creation
# time. Each case below drives a production writer - never a re-implementation
# of it - from a deliberately OPEN caller umask (0022, the defect condition) and
# asserts the created artifact is owner-only, covering the four acceptance
# classes plus the shared-library chokepoints:
#   1. backlog backing file: fm-tasks-axi.sh create AND a full rewrite (tasks-axi
#      renames a fresh temp over the file, so a plain-umask rewrite used to drop
#      a 600 backlog back to 644 with a new inode).
#   2. status record: a real fixture fm-spawn pre-creates state/<id>.status at
#      600, and appends from each writer shape - worker shell, the Node
#      appendFileSync the pi extension uses, and a session-shaped shell append -
#      all preserve the mode and stay readable.
#   3. watcher: a real fm-watch.sh born against a MISSING state dir creates the
#      directory owner-only and its first files owner-only, and a real
#      fm-watch-arm.sh cycle records the cycle-exit ledger owner-only.
#   4. lock records: fm-wake-lib's lock API creates a fresh owner dir (700) and
#      its pid/role records (600) under an open caller umask, and the lock still
#      acquires and releases (consumer cycle).
#   5. Shared chokepoints: task-inbox dirs/records, status markers and the
#      presentation cursor (fm-classify-lib), and the wake queue's first row.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-owner-only-writes)
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
WRAPPER="$ROOT/bin/fm-tasks-axi.sh"

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

# seed_secondmate_home <parent-home> <child-home> <secondmate-id>
# Real seed under the open caller umask, so the routing registry and the child
# home exist exactly as a fleet handoff would leave them.
seed_secondmate_home() { # <parent> <child> <id>
  local parent=$1 child=$2 id=$3 out
  mkdir -p "$parent/data" "$parent/state" "$parent/projects"
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" \
    FM_SECONDMATE_CHARTER='owner-only probe charter' \
    FM_SECONDMATE_SCOPE='owner-only probe scope' \
    "$ROOT/bin/fm-home-seed.sh" "$id" "$child" --no-projects 2>&1) \
    || fail "secondmate seed failed for $id under umask 022: $(printf '%s\n' "$out" | tail -n 5)"
}

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# run_state_lib <lib> <state> <fn> [args...]: call a production library function
# in a child shell whose umask is the open defect condition (0022), against the
# isolated state dir. The child sources the real library, so the executed code
# is the shipped code.
run_state_lib() { # <lib> <state> <fn> [args...]
  local lib=$1 state=$2
  shift 2
  (
    umask 022
    FM_STATE_OVERRIDE="$state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      shift
      "$@"' _ "$ROOT/bin/$lib" "$@"
  )
}

# --- 1. backlog ---------------------------------------------------------------

test_backlog_create_and_rewrite_stay_owner_only() {
  local home id before after out
  home="$TMP_ROOT/backlog-home"
  id=ev-owner-bl1
  mkdir -p "$home/data" "$home/state"
  out=$(umask 022; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$WRAPPER" add "$id" "Owner-only backlog probe" 2>&1) \
    || fail "backlog add failed under umask 022: $out"
  [ -f "$home/data/backlog.md" ] || fail "add must create data/backlog.md"
  [ "$(mode_of "$home/data/backlog.md")" = 600 ] \
    || fail "a backlog created under umask 022 must be 600, got $(mode_of "$home/data/backlog.md")"
  before=$(inode_of "$home/data/backlog.md")
  out=$(umask 022; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$WRAPPER" "done" "$id" --note "closed by the owner-only probe" 2>&1) \
    || fail "backlog mutation failed under umask 022: $out"
  after=$(inode_of "$home/data/backlog.md")
  [ "$after" != "$before" ] \
    || fail "the mutation must really rewrite the file (inode unchanged: the fixture is not exercising the rename-over path)"
  [ "$(mode_of "$home/data/backlog.md")" = 600 ] \
    || fail "a plain-umask rewrite must keep the backlog at 600, got $(mode_of "$home/data/backlog.md") (this is the 644-drift regression)"
  out=$(umask 022; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$WRAPPER" show "$id" 2>&1) || fail "owner read of the backlog row failed: $out"
  printf '%s\n' "$out" | grep -F "$id" >/dev/null \
    || fail "the owner must still read the row back: $out"
  pass "backlog: create and a real rewrite under an open umask both land at 600, and the owner still reads the row"
}

# --- 2. status record ---------------------------------------------------------

test_status_record_precreated_and_appends_preserve_mode() {
  local case_dir home proj wt fakebin id status out node_note
  case_dir="$TMP_ROOT/status-case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=ev-owner-status-z1
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-owner-status"
  fm_test_spawn_brief "$home" "$id"
  out=$(umask 022; GROK_HOME="$case_dir/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "fixture spawn failed: $(printf '%s\n' "$out" | tail -n 5)"
  status="$home/state/$id.status"
  [ -f "$status" ] || fail "spawn must pre-create the status record"
  [ "$(mode_of "$status")" = 600 ] \
    || fail "the pre-created status record must be 600, got $(mode_of "$status")"
  # Worker-shell shape: the brief's literal echo line, from an open umask.
  (umask 022; echo "working [at=$(date +%s)]: worker-shape append" >> "$status") \
    || fail "worker-shape append failed"
  [ "$(mode_of "$status")" = 600 ] \
    || fail "a worker-shell append must preserve 600, got $(mode_of "$status")"
  # Hook shape: the exact Node appendFileSync the pi extension uses.
  if command -v node >/dev/null 2>&1; then
    node -e 'require("fs").appendFileSync(process.argv[1], "note [at=1]: hook-shape append\n")' "$status" \
      || fail "hook-shape append failed"
    [ "$(mode_of "$status")" = 600 ] \
      || fail "a hook-shape append must preserve 600, got $(mode_of "$status")"
    node_note=hook-shape
  else
    echo "skip: node absent; hook-shape append not exercised"
    node_note=skipped
  fi
  # Session shape: firstmate's own resolved-line append, from an open umask.
  (umask 022; echo "resolved [key=ev-owner]: session-shape append" >> "$status") \
    || fail "session-shape append failed"
  [ "$(mode_of "$status")" = 600 ] \
    || fail "a session-shape append must preserve 600, got $(mode_of "$status")"
  grep -F "worker-shape append" "$status" >/dev/null || fail "worker line must stay readable"
  tail -n 1 "$status" | grep -F "session-shape append" >/dev/null \
    || fail "the consumer's tail -1 must see the newest line"
  # Sibling spawn-created state records follow the same rule.
  [ "$(mode_of "$home/state/$id.meta")" = 600 ] \
    || fail "the task record must be 600, got $(mode_of "$home/state/$id.meta")"
  [ "$(mode_of "$home/state/$id.pi-ext.ts")" = 600 ] \
    || fail "the pi extension source must be 600, got $(mode_of "$home/state/$id.pi-ext.ts")"
  pass "status: spawn pre-creates at 600 and worker/hook/session appends all preserve it ($node_note)"
}

# --- 3. watcher: private files AND a private directory -------------------------

test_watcher_creates_private_state_dir_and_files() {
  local dir fakebin state wpid i ownerdir old
  dir=$(make_case watcher-owner-birth)
  fakebin="$dir/fakebin"
  state="$dir/state"
  fm_test_track_watcher_state "$state"
  # Remove the fixture's state dir: the watcher must create its own, owner-only.
  rm -rf "$state"
  old=$(umask)
  umask 022
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  wpid=$!
  umask "$old"
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
    || fail "the watcher did not start: $(tail -n 3 "$dir/watch.out" 2>/dev/null)"
  [ -d "$state" ] || fail "the watcher must create its state directory"
  [ "$(mode_of "$state")" = 700 ] \
    || fail "the watcher-created state dir must be 700, got $(mode_of "$state")"
  [ "$(mode_of "$state/.last-watcher-beat")" = 600 ] \
    || fail "the watcher beat must be 600, got $(mode_of "$state/.last-watcher-beat")"
  [ "$(mode_of "$state/.watch.lock/pid")" = 600 ] \
    || fail "the watch-lock pid record must be 600, got $(mode_of "$state/.watch.lock/pid")"
  ownerdir=$(readlink "$state/.watch.lock" 2>/dev/null || true)
  [ -n "$ownerdir" ] || fail "the watch lock must be the symlinked owner dir"
  [ "$(mode_of "$ownerdir")" = 700 ] \
    || fail "the lock owner dir must be 700, got $(mode_of "$ownerdir")"
  [ "$(mode_of "$state/.watch.lock/fm-home")" = 600 ] \
    || fail "the fm-home lock record must be 600, got $(mode_of "$state/.watch.lock/fm-home")"
  kill "$wpid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$wpid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  wait "$wpid" 2>/dev/null || true
  pass "watcher: a fresh state directory is born 700 and its first files and lock records are 600"
}

# --- 4. watcher cycle-exit ledger ---------------------------------------------

test_cycle_log_created_owner_only_after_real_cycle() {
  local dir state fakebin armout armpid watcher i old
  dir=$(make_case cycle-log-owner)
  state="$dir/state"
  fakebin="$dir/fakebin"
  fm_test_track_watcher_state "$state"
  old=$(umask)
  umask 022
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=30 \
    "$WATCH_ARM" --restart > "$dir/arm.out" 2>&1 &
  armpid=$!
  umask "$old"
  # Wait until the arm has confirmed a live watcher of its own (its confirmation
  # budget is 30s; the ceiling outlasts it so a failure reports instead of
  # hanging, mirroring tests/fm-watch-arm.test.sh's poll ceilings).
  watcher=
  i=0
  while [ "$i" -lt 400 ]; do
    watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ -n "$watcher" ] && [ "$watcher" != "$armpid" ] && kill -0 "$watcher" 2>/dev/null; then
      break
    fi
    kill -0 "$armpid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if ! { [ -n "$watcher" ] && [ "$watcher" != "$armpid" ] && kill -0 "$watcher" 2>/dev/null; }; then
    fail "the arm did not confirm a watcher: $(tail -n 5 "$dir/arm.out" 2>/dev/null)"
  fi
  # End the cycle: the owning arm writes the cycle-exit ledger row on its way out.
  kill "$watcher" 2>/dev/null || true
  i=0
  while [ "$i" -lt 400 ] && kill -0 "$armpid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  wait "$armpid" 2>/dev/null || true
  [ -f "$state/.watch-cycle-exits.log" ] \
    || fail "the cycle-exit ledger must exist after a real cycle: $(tail -n 5 "$dir/arm.out" 2>/dev/null)"
  [ "$(mode_of "$state/.watch-cycle-exits.log")" = 600 ] \
    || fail "the cycle-exit ledger must be 600, got $(mode_of "$state/.watch-cycle-exits.log")"
  grep -F "arm_pid=" "$state/.watch-cycle-exits.log" >/dev/null \
    || fail "the ledger must contain a real cycle row"
  pass "cycle log: a real arm cycle creates the watcher ledger at 600"
}

# --- 5. lock records -----------------------------------------------------------

test_lock_records_created_owner_only_under_open_umask() {
  local state out
  state="$TMP_ROOT/lock-case/state"
  mkdir -p "$state"
  out=$(
    umask 022
    FM_STATE_OVERRIDE="$state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1" || exit 1
      fm_lock_try_acquire "$2" || exit 2
      owner=$FM_LOCK_OWNER_DIR
      fm_lock_set_role "$2" task-spawn || exit 3
      [ -L "$2" ] || exit 7
      s() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
      printf "dir=%s pid=%s role=%s link=yes\n" \
        "$(s "$owner")" "$(s "$owner/pid")" "$(s "$owner/role")"
      fm_lock_release "$2" || exit 4
      # Consumer cycle: the lock still acquires, reads and releases.
      fm_lock_try_acquire "$2" || exit 5
      fm_lock_release "$2" || exit 6
      printf "cycle=ok\n"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.probe.lock"
  ) || fail "lock API cycle failed under umask 022"
  printf '%s\n' "$out" | grep -F "dir=700 pid=600 role=600 link=yes" >/dev/null \
    || fail "lock owner dir/pid/role must be 700/600/600 under an open caller umask, got: $out"
  printf '%s\n' "$out" | grep -F "cycle=ok" >/dev/null \
    || fail "the lock must still acquire and release (consumer cycle): $out"
  pass "lock: owner dir 700 with 600 pid and role records, and the lock still cycles"
}

# --- 6. task inbox dirs and records --------------------------------------------

test_inbox_dirs_and_records_created_owner_only() {
  local state rec out
  state="$TMP_ROOT/inbox-case/state"
  mkdir -p "$state"
  rec=$(run_state_lib fm-task-inbox-lib.sh "$state" fm_task_inbox_write \
    "$state" ev-inbox-z1 "owner-only steer body") \
    || fail "fm_task_inbox_write failed under umask 022"
  [ -d "$state/ev-inbox-z1.inbox" ] || fail "the inbox dir must exist"
  [ "$(mode_of "$state/ev-inbox-z1.inbox")" = 700 ] \
    || fail "the inbox dir must be 700, got $(mode_of "$state/ev-inbox-z1.inbox")"
  [ "$(mode_of "$state/ev-inbox-z1.inbox/handled")" = 700 ] \
    || fail "the handled dir must be 700, got $(mode_of "$state/ev-inbox-z1.inbox/handled")"
  [ -f "$rec" ] || fail "the writer must print the record path: $rec"
  [ "$(mode_of "$rec")" = 600 ] || fail "the .msg record must be 600, got $(mode_of "$rec")"
  grep -F "owner-only steer body" "$rec" >/dev/null || fail "the record must stay readable"
  # The sequence lock is released before the writer returns, so inspect a fresh
  # held acquisition through the same library: owner dir 700, pid record 600.
  # shellcheck disable=SC2016  # The child program is intentionally single-quoted; args arrive as $1/$2.
  out=$(run_state_lib fm-task-inbox-lib.sh "$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1" || exit 1
    fm_lock_try_acquire "$2" || exit 2
    s() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
    printf "dir=%s pid=%s\n" "$(s "$FM_LOCK_OWNER_DIR")" "$(s "$FM_LOCK_OWNER_DIR/pid")"
    fm_lock_release "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state/ev-inbox-z1.inbox/.seq.lock") \
    || fail "sequence-lock inspection failed under umask 022"
  printf '%s\n' "$out" | grep -F "dir=700 pid=600" >/dev/null \
    || fail "the sequence lock must be dir 700 with pid 600, got: $out"
  # The busy ladder's first record creation goes through the same lib.
  printf 'x\n' > "$rec.body" || fail "could not stage a dummy record path"
  run_state_lib fm-task-inbox-lib.sh "$state" fm_task_inbox_record_busy \
    "$state" ev-inbox-z1 "$rec" >/dev/null \
    || fail "fm_task_inbox_record_busy failed under umask 022"
  [ "$(mode_of "$state/ev-inbox-z1.inbox/.busy-state")" = 600 ] \
    || fail "the busy-ladder record must be 600, got $(mode_of "$state/ev-inbox-z1.inbox/.busy-state")"
  pass "inbox: dirs 700 and records 600 for the steer path and the busy ladder"
}

# --- 7. status markers and presentation cursor ----------------------------------

test_status_markers_and_cursor_created_owner_only() {
  local state
  state="$TMP_ROOT/marker-case/state"
  mkdir -p "$state"
  printf 'working [at=1]: probe line\n' > "$state/ev-m1.status" \
    || fail "could not stage the probe status file"
  (
    umask 022
    FM_STATE_OVERRIDE="$state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1" || exit 1
      sig=$(status_observed_signature "$2") || exit 2
      [ -n "$sig" ] || exit 3
      status_presentation_marker_report "$3" "$sig" || exit 4
      ident=$(_fm_open_decisions_file_ident "$2") || exit 5
      size=$(_fm_status_file_size "$2") || exit 6
      size=${size//[[:space:]]/}
      [ -n "$size" ] || exit 7
      snapshot=$(printf "ev-m1\t%s\t%s" "$size" "$ident")
      status_commit_presentation_snapshot "${FM_STATE_OVERRIDE}" "$snapshot" || exit 8
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$state/ev-m1.status" "$state/.seen-ev-m1_test"
  ) || fail "classify-lib writers failed under umask 022"
  [ "$(mode_of "$state/.seen-ev-m1_test")" = 600 ] \
    || fail "the seen marker must be 600, got $(mode_of "$state/.seen-ev-m1_test")"
  [ "$(mode_of "$state/.status-presentation-cursor")" = 600 ] \
    || fail "the presentation cursor must be 600, got $(mode_of "$state/.status-presentation-cursor")"
  grep -F "v2" "$state/.seen-ev-m1_test" >/dev/null || fail "the marker must stay readable"
  # Consumer + rewrite: a second report under the open umask rewrites in place.
  (
    umask 022
    FM_STATE_OVERRIDE="$state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1" || exit 1
      sig=$(status_observed_signature "$2") || exit 2
      status_presentation_marker_report "$3" "$sig" || exit 3
      status_presentation_marker_offset "$3" "$2" >/dev/null || exit 4
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$state/ev-m1.status" "$state/.seen-ev-m1_test"
  ) || fail "marker rewrite/read-back failed under umask 022"
  [ "$(mode_of "$state/.seen-ev-m1_test")" = 600 ] \
    || fail "a marker rewrite must stay 600, got $(mode_of "$state/.seen-ev-m1_test")"
  pass "markers: seen marker and presentation cursor are 600 through create and rewrite"
}

# --- 8. wake queue first row -----------------------------------------------------

test_wake_queue_first_row_created_owner_only() {
  local state
  state="$TMP_ROOT/queue-case/state"
  mkdir -p "$state"
  run_state_lib fm-wake-lib.sh "$state" fm_wake_append \
    signal ev-queue-z1 "first row" >/dev/null \
    || fail "the first wake append failed under umask 022"
  [ -f "$state/.wake-queue" ] || fail "the first append must create the queue"
  [ "$(mode_of "$state/.wake-queue")" = 600 ] \
    || fail "the wake queue must be 600, got $(mode_of "$state/.wake-queue")"
  [ "$(mode_of "$state/.wake-queue.seq")" = 600 ] \
    || fail "the wake queue sequence must be 600, got $(mode_of "$state/.wake-queue.seq")"
  # Consumer: a second append lands and both rows are readable by the owner.
  run_state_lib fm-wake-lib.sh "$state" fm_wake_append \
    signal ev-queue-z2 "second row" >/dev/null \
    || fail "the second wake append failed under umask 022"
  [ "$(mode_of "$state/.wake-queue")" = 600 ] \
    || fail "a queue append must keep 600, got $(mode_of "$state/.wake-queue")"
  [ "$(grep -c . "$state/.wake-queue")" -ge 2 ] \
    || fail "both rows must be readable in the queue"
  pass "wake queue: the first row and its sequence file are 600 and appends keep working"
}

# --- 9. per-harness spawn wiring records ----------------------------------------

test_gemini_settings_created_owner_only() {
  local case_dir home proj wt fakebin id out settings
  case_dir="$TMP_ROOT/gemini-settings-case"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=ev-owner-gem1
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gemini)
  fm_test_spawn_home "$home" gemini
  fm_git_worktree "$proj" "$wt" "wt-owner-gemini"
  fm_test_spawn_brief "$home" "$id"
  out=$(umask 022; GROK_HOME="$case_dir/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "gemini fixture spawn failed: $(printf '%s\n' "$out" | tail -n 5)"
  settings="$home/state/$id.gemini-settings.json"
  [ -f "$settings" ] || fail "a gemini spawn must write its hook settings"
  [ "$(mode_of "$settings")" = 600 ] \
    || fail "the gemini hook settings must be 600 under an open caller umask, got $(mode_of "$settings")"
  grep -F '"BeforeAgent"' "$settings" >/dev/null \
    || fail "the gemini hook settings must carry the real hook wiring"
  pass "spawn: gemini hook settings are created 600 under an open caller umask"
}

# --- 10. open-decisions cursor ---------------------------------------------------

test_open_decisions_cursor_created_owner_only() {
  local state f cursor before
  state="$TMP_ROOT/open-decisions-case/state"
  mkdir -p "$state"
  f="$state/ev-od1.status"
  printf 'needs-decision [key=ev-od]: probe open decision\n' > "$f" \
    || fail "could not stage the probe status file"
  run_state_lib fm-classify-lib.sh "$state" status_open_decisions_incremental "$f" >/dev/null \
    || fail "the open-decisions fold failed under umask 022"
  cursor="$state/.ev-od1.open-decisions-cursor"
  [ -f "$cursor" ] || fail "the fold must persist the open-decisions cursor"
  [ "$(mode_of "$cursor")" = 600 ] \
    || fail "the open-decisions cursor must be 600, got $(mode_of "$cursor")"
  before=$(inode_of "$cursor")
  # Consumer + real rewrite: appending a line makes the next fold rewrite the
  # cursor through a fresh temp renamed over it, exactly the drift shape.
  printf 'resolved [key=ev-od]: probe resolved\n' >> "$f" \
    || fail "could not append to the probe status file"
  run_state_lib fm-classify-lib.sh "$state" status_open_decisions_incremental "$f" >/dev/null \
    || fail "the incremental fold failed under umask 022"
  [ "$(inode_of "$cursor")" != "$before" ] \
    || fail "the fold must really rewrite the cursor (inode unchanged: the rewrite path was not exercised)"
  [ "$(mode_of "$cursor")" = 600 ] \
    || fail "a cursor rewrite must stay 600, got $(mode_of "$cursor")"
  grep -F 'version=' "$cursor" >/dev/null || fail "the cursor must stay readable by the owner"
  pass "open decisions: the cursor is 600 on creation and after a real rewrite"
}

# --- 11. seeded home data files --------------------------------------------------

test_home_seed_data_files_created_owner_only() {
  local case_dir home sub out
  case_dir="$TMP_ROOT/home-seed-case"
  home="$case_dir/home"
  sub="$case_dir/subhome"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$case_dir/alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md" \
    || fail "could not stage the parent project registry"
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_SECONDMATE_CHARTER='owner-only seed charter' \
    FM_SECONDMATE_SCOPE='owner-only seed scope' \
    "$ROOT/bin/fm-home-seed.sh" design "$sub" alpha 2>&1) \
    || fail "home seed failed under umask 022: $(printf '%s\n' "$out" | tail -n 5)"
  [ "$(mode_of "$home/data/secondmates.md")" = 600 ] \
    || fail "the parent secondmate registry must be 600, got $(mode_of "$home/data/secondmates.md")"
  [ "$(mode_of "$sub/data/projects.md")" = 600 ] \
    || fail "the seeded project registry must be 600, got $(mode_of "$sub/data/projects.md")"
  [ "$(mode_of "$sub/data/charter.md")" = 600 ] \
    || fail "the seeded charter copy must be 600, got $(mode_of "$sub/data/charter.md")"
  grep -F 'alpha' "$sub/data/projects.md" >/dev/null \
    || fail "the seeded project registry must stay readable by the owner"
  grep -F 'owner-only seed charter' "$sub/data/charter.md" >/dev/null \
    || fail "the seeded charter must stay readable by the owner"
  pass "seed: the parent registry, seeded projects registry and charter copy are 600 under an open caller umask"
}

# --- 12. captain-hold dispatch under every caller umask ---------------------

test_captain_hold_keeps_backlog_owner_only() {
  local home caller id out before after show
  home="$TMP_ROOT/captain-hold-case/home"
  mkdir -p "$home/data" "$home/state"
  for caller in 000 0022 077; do
    id="ev-hold-$caller"
    rm -f "$home/data/backlog.md"
    out=$(umask "$caller"; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_STATE_OVERRIDE="$home/state" "$WRAPPER" add "$id" "hold probe $caller" 2>&1) \
      || fail "seeding the captain-hold row under umask $caller failed: $out"
    [ "$(mode_of "$home/data/backlog.md")" = 600 ] \
      || fail "the seeded backlog must start 600, got $(mode_of "$home/data/backlog.md")"
    before=$(inode_of "$home/data/backlog.md")
    out=$(umask "$caller"; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
      FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
      --reason "captain held by the owner-only probe $caller" 2>&1) \
      || fail "captain hold under caller umask $caller failed: $out"
    after=$(inode_of "$home/data/backlog.md")
    [ "$after" != "$before" ] \
      || fail "the hold must really rewrite the backlog (inode unchanged under umask $caller)"
    [ "$(mode_of "$home/data/backlog.md")" = 600 ] \
      || fail "a hold under caller umask $caller must keep the backlog at 600, got $(mode_of "$home/data/backlog.md")"
    show=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
      "$WRAPPER" show "$id" 2>&1) \
      || fail "the owner could not read the held row back under umask $caller: $show"
    printf '%s\n' "$show" | grep -F 'held: yes' >/dev/null \
      || fail "the held row must still report held: yes under umask $caller: $show"
    printf '%s\n' "$show" | grep -F "hold_reason: \"captain held by the owner-only probe $caller\"" >/dev/null \
      || fail "the hold reason must survive under umask $caller: $show"
  done
  pass "captain hold: the backlog stays 600 and keeps its reason under caller umasks 000, 0022 and 077"
}

# --- 13. backlog handoff dispatch ----------------------------------------------

test_backlog_handoff_keeps_backlog_owner_only() {
  local case_dir parent child id key out before after rc
  case_dir="$TMP_ROOT/handoff-case"
  parent="$case_dir/parent"
  child="$case_dir/child"
  id=ev-smhandoff
  key=ev-handoff1
  seed_secondmate_home "$parent" "$child" "$id"
  out=$(umask 022; FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" \
    "$WRAPPER" add "$key" "handoff probe row" 2>&1) \
    || fail "seeding the handoff row failed: $out"
  before=$(inode_of "$parent/data/backlog.md")
  rc=0
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" \
    FM_STATE_OVERRIDE="$parent/state" "$ROOT/bin/fm-backlog-handoff.sh" "$id" "$key" 2>&1) \
    || rc=$?
  printf '%s\n' "$out" | grep -F "handed off 1 item(s) to $id: $key" >/dev/null \
    || fail "the handoff must report the staged move (rc=$rc): $out"
  after=$(inode_of "$parent/data/backlog.md")
  [ "$after" != "$before" ] || fail "the handoff must really rewrite the main backlog"
  [ "$(mode_of "$parent/data/backlog.md")" = 600 ] \
    || fail "the main backlog must stay 600 after a handoff, got $(mode_of "$parent/data/backlog.md")"
  if grep -F "$key" "$parent/data/backlog.md" >/dev/null; then
    fail "the handed-off row must leave the main backlog"
  fi
  [ "$(mode_of "$child/data/backlog.md")" = 600 ] \
    || fail "the destination backlog must be 600, got $(mode_of "$child/data/backlog.md")"
  grep -F "$key" "$child/data/backlog.md" >/dev/null \
    || fail "the destination must own the handed-off row"
  pass "handoff: the main backlog stays 600 with the row moved into a 600 destination (wake rc=$rc)"
}

# --- 14. backlog receive dispatch ----------------------------------------------

test_backlog_receive_keeps_backlog_owner_only() {
  local case_dir parent child id key out before after bytes hash
  case_dir="$TMP_ROOT/receive-case"
  parent="$case_dir/parent"
  child="$case_dir/child"
  id=ev-smrecv
  key=ev-recv1
  seed_secondmate_home "$parent" "$child" "$id"
  out=$(umask 022; FM_HOME="$child" FM_DATA_OVERRIDE="$child/data" \
    "$WRAPPER" add existing-row "row already in the destination" 2>&1) \
    || fail "seeding the destination backlog failed: $out"
  mkdir -p "$child/state/handoff"
  printf '## Queued\n\n- [ ] %s - delivered row (repo: %s)\n' "$key" "$id" \
    > "$child/state/handoff/$id.outbox.md" \
    || fail "could not stage the delivered outbox"
  bytes=$(LC_ALL=C wc -c < "$child/state/handoff/$id.outbox.md" | tr -d ' ')
  if command -v shasum >/dev/null 2>&1; then
    hash=$(shasum -a 256 "$child/state/handoff/$id.outbox.md" | awk '{print $1}')
  else
    hash=$(sha256sum "$child/state/handoff/$id.outbox.md" | awk '{print $1}')
  fi
  printf '1\n%s\n%s\n' "$bytes" "$hash" > "$child/state/handoff/.$id.upload-generation" \
    || fail "could not stage the upload generation record"
  before=$(inode_of "$child/data/backlog.md")
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$child" \
    "$ROOT/bin/fm-backlog-receive.sh" "state/handoff/$id.outbox.md" "$bytes" "$hash" 1 2>&1) \
    || fail "backlog receipt failed under umask 022: $out"
  printf '%s\n' "$out" | grep -F 'moved=1' >/dev/null \
    || fail "the receipt must report the delivered move: $out"
  after=$(inode_of "$child/data/backlog.md")
  [ "$after" != "$before" ] || fail "the receipt must really rewrite the destination backlog"
  [ "$(mode_of "$child/data/backlog.md")" = 600 ] \
    || fail "the destination backlog must stay 600 after a receipt, got $(mode_of "$child/data/backlog.md")"
  grep -F "$key" "$child/data/backlog.md" >/dev/null \
    || fail "the delivered row must land in the destination backlog"
  grep -F 'existing-row' "$child/data/backlog.md" >/dev/null \
    || fail "the receipt must preserve the destination's existing rows"
  pass "receive: the destination backlog stays 600 and the delivered row lands for the owner"
}

# --- run ------------------------------------------------------------------------

if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_backlog_create_and_rewrite_stay_owner_only
  test_captain_hold_keeps_backlog_owner_only
  test_backlog_handoff_keeps_backlog_owner_only
  test_backlog_receive_keeps_backlog_owner_only
else
  echo "skip: tasks-axi not found; backlog creation, hold, handoff and receipt cases not run"
fi
test_lock_records_created_owner_only_under_open_umask
test_inbox_dirs_and_records_created_owner_only
test_status_markers_and_cursor_created_owner_only
test_wake_queue_first_row_created_owner_only
test_status_record_precreated_and_appends_preserve_mode
test_gemini_settings_created_owner_only
test_open_decisions_cursor_created_owner_only
test_home_seed_data_files_created_owner_only
test_watcher_creates_private_state_dir_and_files
test_cycle_log_created_owner_only_after_real_cycle
