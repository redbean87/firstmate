#!/usr/bin/env bash
# The recovery-episode marker alone never makes the watcher announce "check:
# rearm-resurface" against an empty wake queue. A drain that acknowledges the
# last queued row leaves state/.watcher-down holding acked:handling:<gen> and
# an empty queue; this pins that this state - the one a captain sees right
# after an acknowledgement - stays silent for both watcher roles (a handling
# successor, which is what the Pi extension's post-wake arms are, and an
# ordinary arm), and that the only thing that makes a running successor
# announce again is a row actually appended to the queue, which reopens the
# episode. So the marker lifecycle cannot be the engine of an announcement
# that finds nothing to drain; a row present at the check and drained before
# the follow-up was read can (fork/wake-guard/README "The defect").
#
# Every case drives the REAL bin/fm-watch.sh and the REAL fm_wake_append
# end to end and arranges only durable fixture state.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-watch-acked-marker)
mkdir -p "$TMP_ROOT"

REARM='check: rearm-resurface'
ACKED='acked:handling:27811.1793741269.2iWZWI'

# start_watch <state> <fakebin> <home> <out> <successor:1|0>: launch the real
# watcher and set WATCH_PID. The fixture env mirrors the upstream recovery
# suites: a 1s poll, no signal grace, no slow checks, no heartbeat wake.
start_watch() {
  local state=$1 fakebin=$2 home=$3 out=$4 successor=$5
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR="$successor" "$WATCH" > "$out" 2>&1 &
  WATCH_PID=$!
}

# wait_watch_ready <state> <pid>: the pid holds the singleton lock AND the
# first liveness beat exists, so the startup arm-check and recovery-marker
# handling before the poll loop have all run.
wait_watch_ready() {
  local state=$1 pid=$2 i=0
  while [ "$i" -lt 200 ]; do
    if [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -e "$state/.last-watcher-beat" ]; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

stop_watch() {  # <pid>
  kill -TERM "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# observe_silence <pid> <out> <seconds>: succeed while the watcher stays alive
# and prints no recovery wake for the whole window - several full poll cycles.
observe_silence() {
  local pid=$1 out=$2 i=0 limit=$(( $3 * 4 ))
  while [ "$i" -lt "$limit" ]; do
    grep -qxF "$REARM" "$out" 2>/dev/null && return 1
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.25
    i=$((i + 1))
  done
  return 0
}

# arrange_case <name> <queue:empty|absent>: a case home holding the acked
# marker and the given queue. Echoes "<state> <fakebin> <home> <out>".
arrange_case() {
  local dir state
  dir=$(make_case "$1")
  state="$dir/state"
  mkdir -p "$dir/home/data"
  : > "$state/crew.meta"
  printf '%s\n' "$ACKED" > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  if [ "$2" = empty ]; then
    : > "$state/.wake-queue"
    printf '5\n' > "$state/.wake-queue.seq"
  fi
  printf '%s %s %s %s\n' "$state" "$dir/fakebin" "$dir/home" "$dir/watch.out"
}

run_silent_case() {  # <name> <queue> <successor:1|0>
  local state fakebin home out
  read -r state fakebin home out <<EOF
$(arrange_case "$1" "$2")
EOF
  start_watch "$state" "$fakebin" "$home" "$out" "$3"
  wait_watch_ready "$state" "$WATCH_PID" || { stop_watch "$WATCH_PID"; fail "$1: the watcher never finished startup: $(cat "$out")"; }
  if ! observe_silence "$WATCH_PID" "$out" 6; then
    stop_watch "$WATCH_PID"
    fail "$1: an acked marker with an empty queue must stay silent, got: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { stop_watch "$WATCH_PID"; fail "$1: the fixture queue must stay empty"; }
  stop_watch "$WATCH_PID"
}

test_an_acked_marker_and_an_empty_queue_stay_silent_for_a_handling_successor() {
  run_silent_case acked-empty-successor empty 1
  run_silent_case acked-absent-successor absent 1
  pass "an acked marker with an empty or absent queue never announces to a handling successor"
}

test_an_acked_marker_and_an_empty_queue_stay_silent_for_an_ordinary_arm() {
  run_silent_case acked-empty-ordinary empty 0
  pass "an acked marker with an empty queue never announces to an ordinary arm"
}

# The control that shows the silence above is the queue's doing, not a dead
# watcher: the same running successor announces exactly once the moment a row
# is appended through the real queue writer, which reopens the episode.
test_a_running_successor_announces_only_once_a_row_is_actually_queued() {
  local state fakebin home out i=0
  read -r state fakebin home out <<EOF
$(arrange_case acked-then-row empty)
EOF
  start_watch "$state" "$fakebin" "$home" "$out" 1
  wait_watch_ready "$state" "$WATCH_PID" || { stop_watch "$WATCH_PID"; fail "the watcher never finished startup: $(cat "$out")"; }
  observe_silence "$WATCH_PID" "$out" 3 || { stop_watch "$WATCH_PID"; fail "no announcement before any row exists: $(cat "$out")"; }
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check demo "check: demo row"' _ "$ROOT/bin/fm-wake-lib.sh" \
    || { stop_watch "$WATCH_PID"; fail "fixture: appending a queue row failed"; }
  while [ "$i" -lt 120 ] && ! grep -qxF "$REARM" "$out" 2>/dev/null; do
    sleep 0.25
    i=$((i + 1))
  done
  wait "$WATCH_PID" 2>/dev/null || true
  assert_equals 1 "$(grep -cxF "$REARM" "$out")" "the appended row must be announced exactly once: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "the announced row must still be queued for main to drain"
  pass "a running successor announces exactly once, and only after a row is actually queued"
}

fork_run_tests
