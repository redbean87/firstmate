#!/usr/bin/env bash
# Fork progress-stall guard, the latch's own suite: a declared `paused:` wait
# stays silent however long its evidence has been aged, one stall wakes once
# with a second sweep silent, the hourly cap holds a re-armed question, a new
# status line re-arms the wake once the cap allows, and an uncaptured answer is
# repeated by the same host request id instead of being suppressed.
#
# Every case drives the REAL extension host (bin/fm-extension.mjs) and the REAL
# process-event runner (bin/fm-procevent.sh) against an isolated fixture home,
# except the two request-id cases, which drive the shipped entrypoint's poll
# with a crafted request id because only the host can mint those. No test
# contacts a network, a live fleet, or the running session's own home.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/progress-guard/extension"
ENTRY="$PKG_SRC/fm-progress-guard.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"

PTMP=$(fm_test_tmproot fm-fork-progress-guard-latch)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

record() {  # <home> <id> <key=value>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

make_worktree() {
  mkdir -p "$1/src"
  printf 'export const x = 1;\n' > "$1/src/main.js"
}

# Pin evidence to fixed old instants (years before any legal threshold) with
# the portable touch -t form, so the shipped 25-minute default applies with no
# test waiting. The three instants differ so the newest-evidence line has a
# deterministic winner: the data file.
backdate_status() { touch -t 202001010000 "$1"; }
backdate_tree() { find "$1" -exec touch -t 202001020000 {} +; }
backdate_data() { find "$1" -exec touch -t 202001030000 {} +; }

working_status() {  # <home> <id>
  printf 'working [at=1793000000]: building the guard\n' > "$1/state/$2.status"
}

# build_stalled_home <home> <id>: a working task whose every evidence source
# is aged far past the threshold.
build_stalled_home() {
  p_home "$1"
  make_worktree "$1/worktree"
  record "$1" "$2" kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4400.7 worktree="$1/worktree"
  working_status "$1" "$2"
  mkdir -p "$1/data/$2"
  printf 'report\n' > "$1/data/$2/report.md"
  backdate_status "$1/state/$2.status"
  backdate_tree "$1/worktree"
  backdate_data "$1/data/$2"
  fast_poll "$1"
}

fast_poll() {
  mkdir -p "$1/state/progress-guard"
  printf '100\n' > "$1/state/progress-guard/poll-wait-ms"
}

poll_request() {  # <request-hex> <config-ref>
  jq -cn --arg rid "sha256:$1" --arg ref "$2" '{schema: "firstmate.extension-request.v1", request_id: $rid,
    host_protocol: 1, extension_id: "org.firstmate.fork.progress-guard", extension_version: "0.1.0",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "progress-guard",
    operation: "source.poll", input: {source_id: "progress-guard", config_ref: $ref}}'
}

adapter_poll() {  # <config-ref>
  poll_request "$(printf '3%.0s' $(seq 1 64))" "$1" | node "$ENTRY" invoke
}

adapter_poll_with_id() {  # <config-ref> <64-hex-request-id>
  poll_request "$2" "$1" | node "$ENTRY" invoke
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

install_package() {
  local home=$1 pkg=$2
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter progress-guard --trust-same-user-code \
    --consent task-metadata >/dev/null \
    || fail "the real extension host must bind the package"
  FM_HOME="$home" "$PROCEVENT" register-extension progress-guard progress-guard \
    --config-ref "home:$home" >/dev/null || fail "registration failed"
}

run_source_until_result() {
  local home=$1 file=$2 _
  for _ in $(seq 1 50); do
    FM_HOME="$home" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
    [ -f "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

start_source() {  # <home>
  FM_HOME="$1" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
}

result_files() {  # <home>
  local f
  for f in "$1"/state/procevent-inbox/progress-guard.*.result; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

# --- (c) a declared pause never alarms --------------------------------------

test_a_declared_paused_task_stays_silent_however_long_it_waits() {
  local home out err pkg
  home="$PTMP/paused/home"
  p_home "$home"
  make_worktree "$home/worktree"
  record "$home" paused-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4500.7 worktree="$home/worktree"
  printf 'paused [at=1793000100]: waiting for the window until 2026-11-04T00:00Z\n' \
    > "$home/state/paused-ship.status"
  record "$home" blocked-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4500.8 worktree="$home/worktree"
  printf 'blocked [at=1793000200]: waiting on firstmate for the credential\n' \
    > "$home/state/blocked-ship.status"
  mkdir -p "$home/data/paused-ship" "$home/data/blocked-ship"
  printf 'report\n' > "$home/data/paused-ship/report.md"
  printf 'report\n' > "$home/data/blocked-ship/report.md"
  # Age every evidence source years past the window, and set the threshold to
  # its legal minimum: if the gate ever let a paused record through, the seam
  # would fire on the very next poll. It must not.
  backdate_status "$home/state/paused-ship.status"
  backdate_status "$home/state/blocked-ship.status"
  backdate_tree "$home/worktree"
  backdate_data "$home/data/paused-ship"
  backdate_data "$home/data/blocked-ship"
  mkdir -p "$home/state/progress-guard"
  printf '100\n' > "$home/state/progress-guard/poll-wait-ms"
  printf '1\n' > "$home/state/progress-guard/stall-threshold-secs"
  out=$(adapter_poll "home:$home" 2>"$PTMP/paused.err") || fail "the shipped adapter's poll failed"
  err=$(cat "$PTMP/paused.err")
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a declared pause must stay silent: $out"
  assert_contains "$err" "progress-guard: skipped paused-ship verb-paused" "the paused declaration is refused at the gate"
  assert_contains "$err" "progress-guard: skipped blocked-ship verb-blocked" "a blocked declaration is refused at the gate"
  assert_absent "$home/state/paused-ship.progress-guard-latch" "a refused task writes no latch marker"
  # And the same silence holds through the real runner: no capture, no wake.
  pkg="$PTMP/paused/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  start_source "$home"
  [ -z "$(result_files "$home")" ] || fail "a paused task produced a capture"
  [ -z "$(wake_payloads "$home")" ] || fail "a paused task produced a wake: $(wake_payloads "$home")"
  pass "silence: a declared paused: task (and a blocked: one) stays silent however long its evidence has been aged, at any legal threshold"
}

# --- (d) the latch, the hourly cap, and re-arming ---------------------------

test_one_stall_wakes_once_a_new_status_line_rearms_and_the_hourly_cap_holds() {
  local home pkg result marker new_line
  home="$PTMP/latch/home"
  build_stalled_home "$home" latch-ship
  pkg="$PTMP/latch/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the runner published no first progress-stall result"
  result="$home/state/procevent-inbox/progress-guard.1.result"
  marker="$home/state/latch-ship.progress-guard-latch"
  assert_present "$marker" "the first wake publishes its latch marker"
  [ "$(wc -l < "$marker" | tr -d ' ')" = 6 ] || fail "the latch marker is a fixed six-field record"
  FM_HOME="$home" "$PROCEVENT" handled progress-guard 1 >/dev/null || fail "handling the first capture failed"

  # A second sweep of the SAME stall stays silent: same task, same worker,
  # same latest status line - one stall, one wake.
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] || fail "the handled wake is re-announced: $(wake_payloads "$home")"
  start_source "$home"
  [ ! -e "$home/state/procevent-inbox/progress-guard.2.result" ] \
    || fail "the same stall woke twice: $(cat "$home/state/procevent-inbox/progress-guard.2.result")"

  # A NEW status line re-arms the identity, but the hourly cap holds the
  # re-armed question: nothing may wake this task again inside the hour of its
  # first wake, however the stall recurs.
  new_line='working [at=1793000900]: still on it, second push'
  printf '%s\n' "$new_line" >> "$home/state/latch-ship.status"
  backdate_status "$home/state/latch-ship.status"
  local out err
  out=$(adapter_poll "home:$home" 2>"$PTMP/cap.err") || fail "the shipped adapter's poll failed"
  err=$(cat "$PTMP/cap.err")
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a re-armed stall inside the hour must be capped: $out"
  assert_contains "$err" "progress-guard: capped latch-ship" "the hourly cap holds the re-armed question"
  start_source "$home"
  [ ! -e "$home/state/procevent-inbox/progress-guard.2.result" ] \
    || fail "the hourly cap let a second wake through the runner"

  # Once the cap is out of the way (a test may disable it), the new status
  # line's stall wakes again with its own body - the re-arm is real, not a
  # latch that never lets go.
  printf '0\n' > "$home/state/progress-guard/min-wake-interval-secs"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.2.result" \
    || fail "a new status line did not re-arm the wake after the cap"
  result="$home/state/procevent-inbox/progress-guard.2.result"
  assert_contains "$(cat "$result")" "$new_line" "the re-armed wake carries the new latest status line"
  assert_contains "$(wake_payloads "$home")" "procevent progress-guard progress-guard 2" \
    "the re-armed stall is announced as its own wake sequence"
  [ "$(FM_HOME="$home" "$PROCEVENT" classify "$result")" = stall-advisory ] \
    || fail "the re-armed result classifies as stall-advisory"
  pass "latch: one stall wakes once, a second sweep stays silent, the hourly cap holds a re-armed question, and a new status line re-arms the wake when the cap allows"
}

test_an_uncaptured_wake_is_repeated_by_the_same_request_id() {
  local home pkg marker hex out err
  home="$PTMP/witness/home"
  build_stalled_home "$home" witness-ship
  pkg="$PTMP/witness/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the runner published no progress-stall result"
  marker="$home/state/witness-ship.progress-guard-latch"
  assert_present "$marker" "the wake publishes its latch marker"
  hex=$(sed -n '5p' "$marker" | sed 's/^sha256://')
  [ -n "$hex" ] && [ "${#hex}" = 64 ] || fail "the marker records the host request id that produced the wake"

  # The SAME request id means the earlier answer was never captured: a retry
  # after a crash between answering and capture must answer again, never be
  # suppressed by the marker that same answer wrote.
  out=$(adapter_poll_with_id "home:$home" "$hex" 2>"$PTMP/witness-same.err") \
    || fail "the same-request-id poll must answer"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = result ] \
    || fail "an uncaptured wake must be repeated on the same request id: $out"
  assert_contains "$(printf '%s' "$out" | jq -r .result.output)" "PROGRESS STALL (advisory): task witness-ship" \
    "the repeat carries the same advisory body"

  # An ORDINARY later poll carries a different id and is silent: that is the
  # latch, not the repeat.
  out=$(adapter_poll_with_id "home:$home" "$(printf '4%.0s' $(seq 1 64))" 2>"$PTMP/witness-other.err") \
    || fail "the later poll must answer"
  err=$(cat "$PTMP/witness-other.err")
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a later poll of the same stall must be latched: $out"
  assert_contains "$err" "progress-guard: latched witness-ship" "the latch names the suppressed task"
  pass "witness: the same request id repeats an uncaptured wake, a different id is latched silent"
}

fork_run_tests
