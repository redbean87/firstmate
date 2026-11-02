#!/usr/bin/env bash
# Fork-side supervision-noise fixes, behaviour and wiring:
#
# 1. The resurface guard must test what MAIN would actually receive - the same
#    main-eligible filter bin/fm-wake-drain.sh applies - at BOTH wake sites of
#    resurface_after_downtime(): the handling-successor branch (HK5, the site
#    this home's Pi-extension post-wake successor arms actually reach) and the
#    ordinary fall-through (HK3). A queue held wholly by a live
#    supervision-branch grant must not wake main; a main-eligible row still
#    must. The behaviour cases drive the REAL bin/fm-watch.sh end to end and
#    arrange only durable fixture state (queue rows, a real branch grant via
#    bin/fm-wake-grant.sh, the recovery marker).
# 2. A done worker parked awaiting review - status log whose latest event is a
#    whole done: line, a recorded open PR (pr= metadata plus the still-armed
#    merge poll) - is absorbed on the long recheck cadence instead of alarming
#    on every pane-hash change; a genuinely stuck worker (status working, no
#    terminal line) keeps its normal stale detection, and a done task whose PR
#    is not recorded open keeps the ordinary terminal-stale surface.
#
# Wiring cases pin fork/bin/fm-fork-hook-check's knowledge of HK4, HK5, HK6.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/watch-triage-helpers.sh
. "$ROOT/tests/watch-triage-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
CHECK="$ROOT/fork/bin/fm-fork-hook-check"
GRANT="$ROOT/bin/fm-wake-grant.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-watch-parked)
mkdir -p "$TMP_ROOT"

REARM='check: rearm-resurface'

# start_watch <state> <fakebin> <home> <out> [env=val...]: launch the real
# watcher and set WATCH_PID. env(1) carries the trailing per-case assignments:
# a bare "$@" there would expand to a command name, not assignment words.
start_watch() {
  local state=$1 fakebin=$2 home=$3 out=$4
  shift 4
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$@" "$WATCH" > "$out" 2>&1 &
  WATCH_PID=$!
}

# wait_watch_ready <state> <pid>: the pid holds the singleton lock AND the
# first liveness beat exists. The first beat is touched at the top of the first
# poll cycle, which is after startup's recovery-marker arm check - so a marker
# written from here on is consumed by the poll's own resurface path, exactly
# the state the live fleet's restart loop produced.
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

# append_row <state> <key> <payload>: queue one structurally valid row and echo
# its sequence number.
append_row() {
  local state=$1 key=$2 payload=$3
  append_wake "$state" check "$key" "$payload" || fail "fixture: could not append the wake row"
  awk -F '\t' 'NR == 1 { print $2; exit }' "$state/.wake-queue"
}

# grant_rows <state> <seq...>: arm a REAL live branch grant over those rows
# (bin/fm-wake-grant.sh activate + publish), owned by this test process.
grant_rows() {
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" fork-test-gen \
    || fail "fixture: fm-wake-grant activate failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish fork-test-gen "$@" \
    || fail "fixture: fm-wake-grant publish failed"
}

# expect_silent_guarded <state> <out> <label>: with the recovery marker
# already injected, several whole poll cycles must pass with no rearm wake and
# a live watcher, and the granted row must still be queued for the branch.
expect_silent_guarded() { # <state> <out> <label>
  local state=$1 out=$2 label=$3 i=0 cycles=0
  while [ "$i" -lt 20 ]; do
    if grep -qx "$REARM" "$out" 2>/dev/null; then
      reap "$WATCH_PID"
      fail "$label: a branch-granted-only queue produced a main wake: $(cat "$out")"
    fi
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      fail "$label: the watcher exited without a wake: $(cat "$out")"
    fi
    sleep 0.5
    i=$((i + 1))
  done
  while [ "$cycles" -lt 2 ]; do
    wait_poll_cycle "$state" "$WATCH_PID" 300 \
      || fail "$label: the watcher stopped polling: $(cat "$out")"
    cycles=$((cycles + 1))
  done
  assert_not_contains "$(cat "$out")" "$REARM" \
    "$label: a branch-granted-only queue must produce no main wake"
  [ -s "$state/.wake-queue" ] || fail "$label: the granted row must stay queued"
  reap "$WATCH_PID"
}

# --- behaviour: the resurface guard, both wake sites -------------------------

# The site that actually fires on this home: after every actionable wake the Pi
# extension restores continuity with FM_WATCH_PREDECESSOR_ARM_PID, so the next
# watcher runs with FM_WATCH_HANDLING_SUCCESSOR=1 and reaches the branch's own
# gate (upstream's non-emptiness check) before its trailing wake. The live
# incident: every queued row belonged to the supervision branch's grant, the
# gate passed on mere non-emptiness, and main drained an empty queue.
test_branch_only_queue_holds_successor_silent() {
  local dir state fakebin home out seq
  dir=$(make_case successor-branch-only); state="$dir/state"; fakebin="$dir/fakebin"
  home="$dir/home"; out="$dir/watch.out"
  mkdir -p "$home/data"
  seq=$(append_row "$state" resurface-fixture 'check: fixture row granted wholly to the branch')
  grant_rows "$state" "$seq"
  start_watch "$state" "$fakebin" "$home" "$out" FM_WATCH_HANDLING_SUCCESSOR=1
  if ! wait_watch_ready "$state" "$WATCH_PID"; then
    reap "$WATCH_PID"
    fail "fixture: watcher never became ready: $(cat "$out")"
  fi
  # Inject the pending recovery the live restart loop kept re-announcing; the
  # next poll's arm check recovers, and the guard - not the marker state - must
  # keep main silent.
  printf 'pending:downtime:fixture.1.branchonly\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  expect_silent_guarded "$state" "$out" "handling-successor branch-only"
  pass "resurface: a branch-granted-only queue produces no main wake at the handling-successor site"
}

# The mirror direction at the same site: the same pending recovery with a
# main-eligible row still wakes main exactly once, and the row stays queued.
test_main_eligible_row_wakes_successor() {
  local dir state fakebin home out wakes
  dir=$(make_case successor-main-row); state="$dir/state"; fakebin="$dir/fakebin"
  home="$dir/home"; out="$dir/watch.out"
  mkdir -p "$home/data"
  append_row "$state" resurface-fixture 'check: fixture row that belongs to main' >/dev/null
  start_watch "$state" "$fakebin" "$home" "$out" FM_WATCH_HANDLING_SUCCESSOR=1
  if ! wait_watch_ready "$state" "$WATCH_PID"; then
    fail "fixture: watcher never became ready: $(cat "$out")"
  fi
  printf 'pending:downtime:fixture.1.mainrow\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  if ! wait_for_exit "$WATCH_PID" 100; then
    reap "$WATCH_PID"
    fail "a main-eligible row with recovery pending must wake main: $(cat "$out")"
  fi
  wakes=$(grep -c "^$REARM$" "$out" 2>/dev/null || true)
  [ "${wakes:-0}" -eq 1 ] || fail "expected exactly one rearm wake (got ${wakes:-0}): $(cat "$out")"
  grep "$(printf '\tcheck\tresurface-fixture\t')" "$state/.wake-queue" >/dev/null \
    || fail "the fixture row must stay queued for main: $(cat "$state/.wake-queue")"
  pass "resurface: a main-eligible row still wakes main exactly once at the handling-successor site"
}

# The ordinary fall-through (HK3) with the same branch-granted-only queue:
# recovery pending at startup must keep the watcher supervising in silence.
test_branch_only_queue_holds_ordinary_path_silent() {
  local dir state fakebin home out seq
  dir=$(make_case ordinary-branch-only); state="$dir/state"; fakebin="$dir/fakebin"
  home="$dir/home"; out="$dir/watch.out"
  mkdir -p "$home/data"
  seq=$(append_row "$state" resurface-fixture 'check: fixture row granted wholly to the branch')
  grant_rows "$state" "$seq"
  printf 'pending:downtime:fixture.1.ordinarybranch\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  start_watch "$state" "$fakebin" "$home" "$out"
  if ! wait_watch_ready "$state" "$WATCH_PID"; then
    fail "fixture: watcher never became ready: $(cat "$out")"
  fi
  expect_silent_guarded "$state" "$out" "ordinary path branch-only"
  pass "resurface: a branch-granted-only queue stays silent through HK3's ordinary fall-through"
}

# --- behaviour: the stale path ----------------------------------------------

# Fixture for the parked/stuck pair: a stably stale pane at a recorded window
# whose hash is already primed, exactly where first-sight stale triage runs.
# <status-log> is the whole status log, <status-age-secs> backdates it (0 keeps
# it fresh), <meta-extra> appends meta lines such as pr=.
stale_pane_case() { # <name> <status-log> <status-age-secs> [<meta-extra>]
  local name=$1 log=$2 age=$3 extra=${4-} dir state window key
  dir=$(make_case "$name"); state="$dir/state"
  window="test:fm-parked"
  printf 'finished, awaiting review' > "$dir/pane.txt"
  {
    printf 'window=%s\nkind=ship\n' "$window"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$state/parked.meta"
  printf '%s\n' "$log" > "$state/parked.status"
  if [ "$age" -gt 0 ]; then
    set_mtime "$(( $(date +%s) - age ))" "$state/parked.status"
  fi
  printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'finished, awaiting review')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# A genuinely stuck worker must keep its normal stale detection: status still
# `working:`, no terminal line, no PR artifacts - the watcher surfaces the
# stale pane and queues the wake.
test_stuck_working_worker_still_detected_stale() {
  local dir state fakebin out drain_out window
  dir=$(stale_pane_case stuck-working 'working: running the suite' 600)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  window="test:fm-parked"
  start_watch "$state" "$fakebin" "$dir/home" "$out" \
    "FM_FAKE_TMUX_WINDOW=$window" "FM_FAKE_TMUX_CAPTURE=$dir/pane.txt"
  wait_for_exit "$WATCH_PID" 100 || { reap "$WATCH_PID"; fail "a stuck working worker was not surfaced as stale"; }
  grep -Fx "stale: $window" "$out" >/dev/null || fail "the stuck worker's stale wake was not printed: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the stuck-worker stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the stuck worker's stale wake was not queued"
  pass "stale: a genuinely stuck worker (working, no terminal line) is still detected"
}

# The reported noise: a done worker whose open PR is recorded keeps its pane
# hash changing, and the terminal-stale first sight used to alarm every time.
# Parked-awaiting-review absorbs it: no wake, no queued row, the stale
# suppressor advanced, the watcher still supervising.
test_done_open_pr_parked_absorbed() {
  local dir state fakebin out window key pane_hash cycles=0
  dir=$(stale_pane_case parked-done 'done: PR https://example.test/pr/9' 0 \
    'pr=https://example.test/pr/9')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  window="test:fm-parked"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text 'finished, awaiting review')
  : > "$state/parked.pr-poll-registration"
  start_watch "$state" "$fakebin" "$dir/home" "$out" FM_PAUSE_RESURFACE_SECS=999 \
    "FM_FAKE_TMUX_WINDOW=$window" "FM_FAKE_TMUX_CAPTURE=$dir/pane.txt"
  while [ "$cycles" -lt 3 ]; do
    if ! wait_poll_cycle "$state" "$WATCH_PID" 300; then
      reap "$WATCH_PID"
      fail "the parked done worker's watcher exited: $(cat "$out")"
    fi
    cycles=$((cycles + 1))
  done
  assert_not_contains "$(cat "$out")" "stale: $window" \
    "a done worker parked awaiting review must not raise a stale wake"
  [ ! -e "$state/.wake-queue" ] || [ ! -s "$state/.wake-queue" ] \
    || fail "the parked done worker must not queue a stale wake: $(cat "$state/.wake-queue")"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "the parked done worker's stale suppressor was not advanced"
  reap "$WATCH_PID"
  pass "stale: a done worker parked awaiting review is absorbed instead of alarmed"
}

# ...while the PR requirement stays real: the same done pane WITHOUT the armed
# merge poll keeps the ordinary terminal-stale surface, so a finished task
# whose PR is not recorded open (merged and retired, never registered) is not
# silently parked.
test_done_without_open_pr_still_surfaces() {
  local dir state fakebin out window
  dir=$(stale_pane_case done-no-pr 'done: PR https://example.test/pr/9' 0 \
    'pr=https://example.test/pr/9')
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  window="test:fm-parked"
  start_watch "$state" "$fakebin" "$dir/home" "$out" FM_PAUSE_RESURFACE_SECS=999 \
    "FM_FAKE_TMUX_WINDOW=$window" "FM_FAKE_TMUX_CAPTURE=$dir/pane.txt"
  wait_for_exit "$WATCH_PID" 100 || { reap "$WATCH_PID"; fail "a done worker with no recorded open PR was silently parked"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "a done worker without a recorded open PR must surface as stale: $(cat "$out")"
  pass "stale: a done worker whose PR is not recorded open keeps the ordinary surface"
}

# --- wiring: fork/bin/fm-fork-hook-check's HK4/HK5/HK6 knowledge -------------

# copy_tree <name>: a minimal tree with the three hooked files, the canonical
# blocks, one unhooked upstream bin file, and the four upstream libraries the
# hook check greps for HK4/HK6's contract names. Echoes its root.
copy_tree() {
  local t="$TMP_ROOT/$1"
  mkdir -p "$t/bin" "$t/fork/hooks"
  cp "$ROOT/bin/fm-spawn.sh" "$ROOT/bin/fm-control.sh" "$ROOT/bin/fm-watch.sh" \
    "$ROOT/bin/fm-send.sh" "$ROOT/bin/fm-wake-lib.sh" \
    "$ROOT/bin/fm-push-transition-lib.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-backend.sh" "$t/bin/"
  cp "$ROOT/fork/hooks/"*.block "$t/fork/hooks/"
  printf '%s\n' "$t"
}

# mutate <file> <python-expression>: rewrite a copied file with hk1..hk6
# (its tree's canonical blocks) in scope.
mutate() {
  python3 - "$1" "$2" <<'PY' || fail "fixture mutation did not apply: $2"
import sys
p, expr = sys.argv[1], sys.argv[2]
root = p.rsplit("/bin/", 1)[0]
s = open(p).read()
ns = {"s": s}
for name in ("hk1-spawn", "hk2-control", "hk3-watch", "hk4-main-eligible",
             "hk5-resurface-successor", "hk6-parked-review"):
    ns[name.replace("-", "_")] = open(f"{root}/fork/hooks/{name}.block").read()
ns["hk1"] = ns["hk1_spawn"]
ns["hk2"] = ns["hk2_control"]
ns["hk3"] = ns["hk3_watch"]
ns["hk4"] = ns["hk4_main_eligible"]
ns["hk5"] = ns["hk5_resurface_successor"]
ns["hk6"] = ns["hk6_parked_review"]
s2 = eval(expr, ns)
assert s2 != s, "mutation did not change the file"
open(p, "w").write(s2)
PY
}

expect_detected() { # <root> <expected FAIL text> <label>
  local out rc
  out=$("$CHECK" --root "$1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$3: the hook check did not fail"$'\n'"$out"
  assert_contains "$out" "FAIL: $2" "$3: the hook check must name the problem"
}

test_hook_blocks_wire_on_this_tree() {
  local out rc
  out=$("$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "the hook check must pass on this tree"$'\n'"$out"
  assert_contains "$out" "ok: HK4: present once and identical to fork/hooks/hk4-main-eligible.block" \
    "HK4 must be byte-identical to its canonical block"
  assert_contains "$out" "ok: HK5: inside the handling-successor branch" \
    "HK5 must sit at its anchor inside the handling-successor branch"
  assert_contains "$out" "ok: HK6: after the captain-call absorb" \
    "HK6 must sit at its anchor in the terminal-stale branch"
  pass "wiring: HK4, HK5, HK6 present once, identical, and anchored on this tree"
}

test_detects_missing_hk4() {
  local t; t=$(copy_tree no-hk4)
  mutate "$t/bin/fm-watch.sh" 's.replace(hk4, "")'
  expect_detected "$t" "HK4: expected exactly one hook block" "missing HK4"
  pass "wiring: a removed HK4 is detected"
}

test_detects_weakened_hk5() {
  local t; t=$(copy_tree weak-hk5)
  # shellcheck disable=SC2016 # a literal weakened guard is the point
  mutate "$t/bin/fm-watch.sh" 's.replace("fork_main_eligible_queued_row || return 0\n    # <<< fork resurface-guard hook HK5", "fork_main_eligible_queued_row || true\n    # <<< fork resurface-guard hook HK5")'
  expect_detected "$t" "HK5: hook block in bin/fm-watch.sh differs" "weakened HK5"
  pass "wiring: an HK5 guard that no longer refuses (|| true) is detected"
}

test_detects_missing_hk6() {
  local t; t=$(copy_tree no-hk6)
  mutate "$t/bin/fm-watch.sh" 's.replace(hk6, "")'
  expect_detected "$t" "HK6: expected exactly one hook block" "missing HK6"
  pass "wiring: a removed HK6 is detected"
}

test_detects_moved_hk6() {
  local t; t=$(copy_tree moved-hk6)
  # Move the block far from the captain-call absorb it must follow: the markers
  # still match once, so the position check - not find_block - must object.
  # shellcheck disable=SC2016 # Python source, not shell expansion
  mutate "$t/bin/fm-watch.sh" 's.replace(hk6, "").replace("resurface_after_downtime() {", hk6 + "resurface_after_downtime() {", 1)'
  expect_detected "$t" "HK6: block must sit directly after the captain-call absorb branch" "moved HK6"
  pass "wiring: a parked-review block moved out of the terminal-stale branch is detected"
}

fork_run_tests
