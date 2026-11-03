#!/usr/bin/env bash
# HK3, the fork's resurface guard: bin/fm-watch.sh may announce "check:
# rearm-resurface" only while a wake row is actually queued, so a recovery
# episode whose row was already handled no longer costs main an empty
# "watching resumed" turn - including the recovery-pending fall-through, where
# WATCHER_RECOVERY_PENDING=1 skips the ordinary branch and control reaches the
# trailing wake directly. The behaviour cases drive the REAL bin/fm-watch.sh
# end to end and arrange only its durable fixture state; the wiring cases pin
# fork/bin/fm-fork-hook-check's HK3 knowledge - byte-identical block, anchored
# between the ordinary branch's fi and the trailing wake, and --base covering
# every hook block each file adds over upstream. Previous behaviour: both
# empty-queue cases wake (the recovery-pending one reproduced the empty-ping
# leak), the queued-row cases wake exactly once (unchanged either way).
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$ROOT/tests/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
CHECK="$ROOT/fork/bin/fm-fork-hook-check"
TMP_ROOT=$(fm_test_tmproot fm-fork-watch-resurface)
mkdir -p "$TMP_ROOT"

REARM='check: rearm-resurface'

# start_watch <state> <fakebin> <home> <out>: launch the real watcher and set
# WATCH_PID. The fixture env mirrors the upstream recovery suites: a 1s poll,
# no signal grace, no slow checks, no heartbeat wake.
start_watch() {
  local state=$1 fakebin=$2 home=$3 out=$4
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
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

# make_watch_case <name>: a case home with make_case's state and fakebin.
# Echoes "<state> <fakebin> <home> <out>" as one line.
make_watch_case() {
  local dir state fakebin home out
  dir=$(make_case "$1")
  state="$dir/state"
  fakebin="$dir/fakebin"
  home="$dir/home"
  out="$dir/watch.out"
  mkdir -p "$home/data"
  printf '%s %s %s %s\n' "$state" "$fakebin" "$home" "$out"
}

# --- behaviour: the resurface path, driven end to end -------------------------

# The durable state the bug leaves behind: a recovery marker announcing
# downtime while the wake queue is empty (the row behind the episode was
# already handled). The old code announced an empty recovery wake on the next
# poll cycle; the guard must keep the watcher supervising in silence.
test_empty_queue_produces_no_recovery_wake() {
  local state fakebin home out i
  read -r state fakebin home out < <(make_watch_case resurface-empty)
  start_watch "$state" "$fakebin" "$home" "$out"
  if ! wait_watch_ready "$state" "$WATCH_PID"; then
    stop_watch "$WATCH_PID"
    fail "fixture: watcher never became ready: $(cat "$out")"
  fi
  printf 'pending:downtime:fixture.1.emptyresurface\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  i=0
  while [ "$i" -lt 24 ]; do
    if grep -qx "$REARM" "$out" 2>/dev/null; then
      stop_watch "$WATCH_PID"
      fail "an empty queue produced a recovery wake: $(cat "$out")"
    fi
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      fail "the watcher exited without a wake: $(cat "$out")"
    fi
    sleep 0.5
    i=$((i + 1))
  done
  assert_not_contains "$(cat "$out")" "$REARM" \
    "an empty queue must produce no recovery wake"
  stop_watch "$WATCH_PID"
  pass "resurface: an empty wake queue stays silent - no empty watching-resumed turn"
}

# A row genuinely queued must still resurface exactly as upstream: one wake,
# one announcement, no silence.
test_queued_row_resurfaces_exactly_once() {
  local state fakebin home out i wakes
  read -r state fakebin home out < <(make_watch_case resurface-queued)
  start_watch "$state" "$fakebin" "$home" "$out"
  if ! wait_watch_ready "$state" "$WATCH_PID"; then
    stop_watch "$WATCH_PID"
    fail "fixture: watcher never became ready: $(cat "$out")"
  fi
  append_wake "$state" check resurface-fixture \
    'check: fixture row queued while the watcher restarts' \
    || fail "fixture: could not append the wake row"
  i=0
  while [ "$i" -lt 30 ] && ! grep -qx "$REARM" "$out" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
  done
  wakes=$(grep -c "^$REARM$" "$out" 2>/dev/null || true)
  if [ "${wakes:-0}" -ne 1 ]; then
    stop_watch "$WATCH_PID"
    fail "a queued row must resurface exactly once (got ${wakes:-0}): $(cat "$out")"
  fi
  grep "$(printf '\tcheck\tresurface-fixture\t')" "$state/.wake-queue" >/dev/null \
    || fail "the fixture row must stay queued for main: $(cat "$state/.wake-queue")"
  stop_watch "$WATCH_PID"
  pass "resurface: a queued row wakes exactly once and stays queued for main"
}

# The leak's real shape: the recovery marker is ALREADY durable when the
# watcher starts, so WATCHER_RECOVERY_PENDING=1 skips the ordinary branch and
# the trailing wake is reached with no guard at all - the empty ping this
# guard exists to silence. Before the fix this case fired an empty
# "check: rearm-resurface"; now the guard keeps the watcher supervising in
# silence.
test_startup_pending_empty_queue_stays_silent() {
  local state fakebin home out i
  read -r state fakebin home out < <(make_watch_case resurface-pending-empty)
  printf 'pending:downtime:fixture.1.pendingempty\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  start_watch "$state" "$fakebin" "$home" "$out"
  i=0
  while [ "$i" -lt 24 ]; do
    if grep -qx "$REARM" "$out" 2>/dev/null; then
      stop_watch "$WATCH_PID"
      fail "recovery pending with an empty queue fired an empty wake: $(cat "$out")"
    fi
    sleep 0.5
    i=$((i + 1))
  done
  if ! kill -0 "$WATCH_PID" 2>/dev/null; then
    fail "the watcher exited without waking: $(cat "$out")"
  fi
  assert_not_contains "$(cat "$out")" "$REARM" \
    "a pending recovery with an empty queue must stay silent"
  stop_watch "$WATCH_PID"
  pass "resurface: recovery pending at startup with an empty queue stays silent"
}

# The same fall-through with a row genuinely queued must still wake main
# exactly once - the guard changes nothing about a real resurface.
test_startup_pending_queued_row_wakes_once() {
  local state fakebin home out i wakes
  read -r state fakebin home out < <(make_watch_case resurface-pending-queued)
  printf 'pending:downtime:fixture.1.pendingqueued\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  append_wake "$state" check resurface-fixture \
    'check: fixture row queued while recovery is pending' \
    || fail "fixture: could not append the wake row"
  start_watch "$state" "$fakebin" "$home" "$out"
  i=0
  while [ "$i" -lt 40 ] && ! grep -qx "$REARM" "$out" 2>/dev/null; do
    sleep 0.5
    i=$((i + 1))
  done
  sleep 1  # let a duplicate wake land if the guard is broken
  wakes=$(grep -c "^$REARM$" "$out" 2>/dev/null || true)
  if [ "${wakes:-0}" -ne 1 ]; then
    stop_watch "$WATCH_PID"
    fail "a queued row with recovery pending must wake exactly once (got ${wakes:-0}): $(cat "$out")"
  fi
  grep "$(printf '\tcheck\tresurface-fixture\t')" "$state/.wake-queue" >/dev/null \
    || fail "the fixture row must stay queued for main: $(cat "$state/.wake-queue")"
  stop_watch "$WATCH_PID"
  pass "resurface: a queued row with recovery pending still wakes exactly once"
}

# --- wiring: fork/bin/fm-fork-hook-check's HK3 knowledge ----------------------

# copy_watch_tree <name>: a minimal tree with the six hooked files, the
# canonical blocks, one unhooked upstream bin file, and the four upstream
# libraries the hook check greps for HK4/HK6's contract names. Echoes its root.
copy_watch_tree() {
  local t="$TMP_ROOT/$1"
  mkdir -p "$t/bin" "$t/fork/hooks"
  cp "$ROOT/bin/fm-spawn.sh" "$ROOT/bin/fm-control.sh" "$ROOT/bin/fm-watch.sh" \
    "$ROOT/bin/fm-extension.mjs" "$ROOT/bin/fm-tool-update-check.sh" \
    "$ROOT/bin/fm-composer-lib.sh" \
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
ns = {}
for name in ("hk1-spawn", "hk2-control", "hk3-watch", "hk4-main-eligible",
             "hk5-resurface-successor", "hk6-parked-review"):
    ns[name.replace("-", "_")] = open(f"{root}/fork/hooks/{name}.block").read()
ns["hk1"] = ns["hk1_spawn"]
ns["hk2"] = ns["hk2_control"]
ns["hk3"] = ns["hk3_watch"]
ns["hk4"] = ns["hk4_main_eligible"]
ns["hk5"] = ns["hk5_resurface_successor"]
ns["hk6"] = ns["hk6_parked_review"]
ns["s"] = s
s2 = eval(expr, ns)
assert s2 != s, "mutation did not change the file"
open(p, "w").write(s2)
PY
}

expect_hk3_detected() {  # <root> <expected FAIL text> <label>
  local out rc
  out=$("$CHECK" --root "$1" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$3: the hook check did not fail"$'\n'"$out"
  assert_contains "$out" "FAIL: $2" "$3: the hook check must name the problem"
}

test_hk3_wires_on_this_tree() {
  local out rc
  out=$("$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "the hook check must pass on this tree"$'\n'"$out"
  assert_contains "$out" "ok: HK3: present once and identical to fork/hooks/hk3-watch.block" \
    "HK3 must be byte-identical to its canonical block"
  assert_contains "$out" "ok: HK3: inside resurface_after_downtime(), after the recover check" \
    "HK3 must sit at its anchor inside resurface_after_downtime()"
  pass "wiring: HK3 present once, identical, and anchored on this tree"
}

test_detects_missing_hk3() {
  local t; t=$(copy_watch_tree no-hk3)
  mutate "$t/bin/fm-watch.sh" 's.replace(hk3, "")'
  expect_hk3_detected "$t" "HK3: expected exactly one hook block" "missing HK3"
  pass "wiring: a removed HK3 is detected"
}

test_detects_edited_hk3() {
  local t; t=$(copy_watch_tree edit-hk3)
  # shellcheck disable=SC2016 # a literal weakened guard is the point
  mutate "$t/bin/fm-watch.sh" 's.replace("fork_main_eligible_queued_row || return 0\n  # <<< fork resurface-guard hook HK3", "fork_main_eligible_queued_row || true\n  # <<< fork resurface-guard hook HK3")'
  expect_hk3_detected "$t" "HK3: hook block in bin/fm-watch.sh differs" "edited HK3"
  pass "wiring: an HK3 block that no longer refuses (|| true) is detected"
}

test_detects_hk3_moved_before_the_branch_fi() {
  local t; t=$(copy_watch_tree moved-hk3)
  # shellcheck disable=SC2016 # Python source, not shell expansion
  mutate "$t/bin/fm-watch.sh" 's.replace(hk3, "").replace("\n  fi\n  wake \"check: rearm-resurface\"", "\n" + hk3 + "  fi\n  wake \"check: rearm-resurface\"", 1)'
  expect_hk3_detected "$t" "HK3: block must sit between the ordinary branch's fi" \
    "HK3 before the branch fi"
  pass "wiring: HK3 moved back inside the recover-check branch is detected"
}

test_base_covers_exactly_the_hook_blocks() {
  local t out rc
  t=$(copy_watch_tree base-blocks)
  git -C "$t" init -q
  git -C "$t" config user.email fork-test@invalid
  git -C "$t" config user.name fork-test
  cp "$t/bin/fm-spawn.sh" "$t/spawn.hooked"
  cp "$t/bin/fm-control.sh" "$t/control.hooked"
  cp "$t/bin/fm-watch.sh" "$t/watch.hooked"
  mutate "$t/bin/fm-spawn.sh" 's.replace(hk1, "")'
  mutate "$t/bin/fm-control.sh" 's.replace(hk2, "")'
  mutate "$t/bin/fm-watch.sh" 's.replace(hk3, "").replace(hk4, "").replace(hk5, "").replace(hk6, "")'
  git -C "$t" add bin
  git -C "$t" commit -q -m upstream
  mv "$t/spawn.hooked" "$t/bin/fm-spawn.sh"
  mv "$t/control.hooked" "$t/bin/fm-control.sh"
  mv "$t/watch.hooked" "$t/bin/fm-watch.sh"
  out=$("$CHECK" --root "$t" --base HEAD 2>&1); rc=$?
  expect_code 0 "$rc" "--base must accept a tree that differs only by the hook blocks"$'\n'"$out"
  assert_contains "$out" "differ only by the hook blocks" \
    "--base must report the hook-block boundary"
  printf '# local tweak\n' >> "$t/bin/fm-watch.sh"
  out=$("$CHECK" --root "$t" --base HEAD 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--base must reject a watch edit beyond the blocks"$'\n'"$out"
  assert_contains "$out" "differ by more than their hook block" \
    "--base must reject an HK3 file changed beyond its blocks"
  assert_contains "$out" "bin/fm-watch.sh" "--base must name the extra watch edit"
  pass "wiring: --base accepts exactly the hook blocks and rejects any other upstream edit"
}

fork_run_tests
