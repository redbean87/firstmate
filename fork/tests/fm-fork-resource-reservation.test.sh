#!/usr/bin/env bash
# Resource reservations: the machine-wide per-resource lock and the durable
# reservation that closes the window between admission and the new task's
# record and agent existing. The policy is called directly with the hook
# contract environment. Owners are real processes (a sleeping placeholder for a
# live fm-spawn, a reaped child for a gone one), so PID and start-time identity
# is checked against the real process table.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-resource-reservation)
mkdir -p "$TMP_ROOT"
MODEL_A='strata-local/qwen-test'
OWNERS=()

# new_case <name> [capacity]: sets CASE HOME_DIR OWN_STATE FAKE FAKEBIN RES.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKE="$CASE/fake"
  FAKEBIN="$CASE/fakebin"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  OWN_STATE=$(cd "$HOME_DIR/state" && pwd -P)
  RES="$OWN_STATE/fork-reservations/strata"
  fork_liveness_fakes "$FAKEBIN" "$FAKE"
  fork_policies "$HOME_DIR" resource
  printf '{"strata":{"capacity":%s,"match":{"model_prefix":"strata-local/"}}}\n' "${2:-1}" > "$HOME_DIR/config/fork-resources.json"
}

live_owner() {  # -> pid of a live placeholder process (killed by stop_owners)
  sleep 600 >/dev/null 2>&1 &
  OWNERS+=("$!")
  printf '%s\n' "$!"
}
gone_owner() {  # -> pid of a process that has exited and been reaped
  local p
  sleep 0 >/dev/null 2>&1 &
  p=$!
  wait "$p" 2>/dev/null
  printf '%s\n' "$p"
}
stop_owners() { local p; for p in "${OWNERS[@]}"; do kill "$p" 2>/dev/null; done; OWNERS=(); }
start_of() { local out; out=$(LC_ALL=C ps -o lstart= -p "$1"); out=${out#"${out%%[![:space:]]*}"}; printf '%s' "${out%"${out##*[![:space:]]}"}"; }

# reservation <task> <owner-pid> <owner-start> <age-seconds> [home-state]
reservation() {
  mkdir -p "$RES"
  jq -n --arg task "$1" --arg home "${5:-$OWN_STATE}" --argjson pid "$2" --arg start "$3" \
    --argjson created "$(( $(date +%s) - $4 ))" \
    '{v: 1, task: $task, home_state: $home, resource: "strata", model: "strata-local/qwen-test",
      phase: "spawn", owner_pid: $pid, owner_start: $start, created: $created}' > "$RES/$1.test.json"
}

# policy <id> [phase] [home]: run the entry point as HK1/HK2 would. The owner is
# $OWNER (default: this test process).
policy() {
  local home=${3:-$HOME_DIR}
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" \
    FM_LP_PHASE="${2:-spawn}" FM_LP_TASK="$1" FM_LP_KIND=ship FM_LP_PROJECT="$CASE/project" \
    FM_LP_HARNESS=pi FM_LP_MODEL="${MODEL:-$MODEL_A}" FM_LP_EFFORT=default \
    FM_LP_HOME="$home" FM_LP_STATE="$home/state" FM_LP_DATA="$home/data" \
    FM_LP_CONFIG="$home/config" FM_LP_OWNER_PID="${OWNER-$$}" "$POLICY" 2>&1
}

reservations() { find "$RES" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# --- reservation lifecycle ----------------------------------------------------

test_admission_writes_reservation_atomically() {
  local out rc owner f
  new_case write
  owner=$(live_owner)
  out=$(OWNER=$owner policy t-one); rc=$?
  expect_code 0 "$rc" "a free resource must admit: $out"
  f=$(find "$RES" -name 't-one.*.json')
  [ -n "$f" ] || fail "an admitted launch must leave a reservation"
  assert_equals "$owner" "$(jq -r .owner_pid "$f")" "the reservation must name the launching process"
  assert_equals "$(start_of "$owner")" "$(jq -r .owner_start "$f")" "the reservation must record the owner's start time"
  assert_equals "$OWN_STATE" "$(jq -r .home_state "$f")" "the reservation must name the home"
  [ -z "$(find "$RES" -name '.*.tmp')" ] || fail "an atomic write must leave no temporary file"
  stop_owners
  pass "reservation: an admitted launch writes a complete reservation naming its owner by PID and start time"
}

test_live_owner_reservation_blocks() {
  local out rc owner
  new_case live-owner
  owner=$(live_owner)
  reservation t-first "$owner" "$(start_of "$owner")" 5
  out=$(policy t-second); rc=$?
  expect_code 1 "$rc" "a launch in progress must hold the place: $out"
  assert_contains "$out" "t-first(launch in progress)" "the refusal must name the launch in progress"
  stop_owners
  pass "reservation: a reservation whose launching process is alive holds the place"
}

test_gone_owner_within_grace_blocks() {
  local out rc owner
  new_case grace
  owner=$(gone_owner)
  reservation t-first "$owner" "Wed Jan  1 00:00:00 2025" 60
  out=$(policy t-second); rc=$?
  expect_code 1 "$rc" "a just-launched task still starting must hold the place: $out"
  assert_contains "$out" "t-first(starting, " "the refusal must name the task as still starting"
  assert_contains "$out" "s of 120s grace)" "the refusal must name the startup grace"
  [ "$(reservations)" = 1 ] || fail "a reservation inside its grace must not be deleted"
  pass "reservation: a gone owner's reservation holds for the 120s startup grace"
}

test_gone_owner_past_grace_expires_and_is_removed() {
  local out rc owner
  new_case expired
  owner=$(gone_owner)
  reservation t-first "$owner" "Wed Jan  1 00:00:00 2025" 121
  out=$(policy t-second); rc=$?
  expect_code 0 "$rc" "a confirmed-gone owner past grace must free the place: $out"
  [ ! -e "$RES/t-first.test.json" ] || fail "the expired reservation must be removed"
  pass "reservation: a confirmed-gone owner past grace frees the place and the reservation is removed"
}

test_pid_reuse_is_owner_gone() {
  local out rc reused
  new_case reuse
  reused=$(live_owner)
  reservation t-old "$reused" "Wed Jan  1 00:00:00 2025" 30
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "a reused PID inside grace must still hold through grace: $out"
  assert_contains "$out" "t-old(starting" "a reused PID must be read as the owner gone, not alive"
  reservation t-old "$reused" "Wed Jan  1 00:00:00 2025" 200
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "a reused PID past grace must not keep the place: $out"
  [ ! -e "$RES/t-old.test.json" ] || fail "a reservation whose PID was reused must be removed once past grace"
  stop_owners
  pass "reservation: a live PID with a different start time is the owner gone (PID reuse), never a live launch"
}

test_unconfirmable_owner_holds_even_when_stale() {
  local out rc
  new_case uncertain
  : > "$FAKE/ps-fail.99991"
  reservation t-first 99991 "Wed Jan  1 00:00:00 2025" 3600
  out=$(policy t-second); rc=$?
  expect_code 1 "$rc" "an owner that cannot be confirmed gone must keep the place, whatever its age: $out"
  assert_contains "$out" "t-first(launch owner unconfirmed)" "the refusal must say the owner is unconfirmed"
  assert_contains "$out" "STALE reservations need reconciliation" "a reservation past 30 minutes must be named as stale"
  [ "$(reservations)" = 1 ] || fail "an unconfirmed reservation must never be deleted by age"
  pass "reservation: an unconfirmable owner holds the place even past 30 minutes; age only flags it as stale"
}

test_age_never_overrides_liveness() {
  local out rc owner
  new_case liveness
  owner=$(gone_owner)
  reservation h1 "$owner" "Wed Jan  1 00:00:00 2025" 7200
  fork_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" alive
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "an expired reservation must not hide a live agent: $out"
  assert_contains "$out" "(1 of 1 live)" "the live record must still hold the place"
  fork_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" ambiguous
  out=$(policy t-new); rc=$?
  expect_code 1 "$rc" "an expired reservation must not hide an ambiguous agent: $out"
  fork_holder "$HOME_DIR" "$FAKE" h1 "$MODEL_A" dead
  printf '%s\n' "fm-h1" > "$FAKE/windows"
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "only a dead record with an expired reservation frees the place: $out"
  pass "reservation: an expired reservation never overrides a live or ambiguous agent"
}

test_own_reservation_is_replaced_not_counted() {
  local out rc owner other f
  new_case own
  other=$(live_owner)
  reservation t-self "$other" "$(start_of "$other")" 10
  owner=$(live_owner)
  out=$(OWNER=$owner policy t-self); rc=$?
  expect_code 0 "$rc" "a task's own reservation must not block its own launch: $out"
  f=$(find "$RES" -name 't-self.*.json' ! -name '*.test.json')
  assert_equals "$owner" "$(jq -r .owner_pid "$f")" "the new reservation must name the new owner"
  stop_owners
  pass "reservation: a task's own earlier reservation is not counted and the new one names the new owner"
}

test_refusal_leaves_no_reservation() {
  local out rc owner
  new_case refuse-cleanup
  printf '%s\n' '{"aaa":{"capacity":2,"match":{"model_prefix":"strata-local/"}},"zzz":{"capacity":1,"match":{"model_prefix":"strata-"}}}' > "$HOME_DIR/config/fork-resources.json"
  fork_holder "$HOME_DIR" "$FAKE" h-zzz "strata-other/model" alive
  owner=$(live_owner)
  out=$(OWNER=$owner policy t-new); rc=$?
  expect_code 1 "$rc" "the second matching resource is full and must refuse: $out"
  [ -z "$(find "$OWN_STATE/fork-reservations/aaa" -name '*.json' 2>/dev/null)" ] \
    || fail "a refused launch left the reservation it took on the first resource"
  stop_owners
  pass "reservation: a refused launch removes every reservation it wrote in that run"
}

test_relaunch_preflight_reserves_nothing() {
  local out rc
  new_case preflight
  out=$(OWNER='' policy t-relaunch relaunch-preflight); rc=$?
  expect_code 0 "$rc" "a preflight on a free resource must allow: $out"
  [ "$(reservations)" = 0 ] || fail "the relaunch preflight must not write a reservation"
  pass "relaunch: the preflight before the agent stops checks capacity without reserving"
}

test_relaunch_reserves_and_skips_its_own_record() {
  local out rc owner
  new_case relaunch
  fork_holder "$HOME_DIR" "$FAKE" t-relaunch "$MODEL_A" alive
  owner=$(live_owner)
  out=$(OWNER=$owner policy t-relaunch relaunch); rc=$?
  expect_code 0 "$rc" "a relaunch must not count its own task: $out"
  [ -n "$(find "$RES" -name 't-relaunch.*.json')" ] || fail "the relaunch must reserve its replacement launch"
  stop_owners
  pass "relaunch: the replacement launch reserves its place and does not count its own record"
}

# --- fail closed --------------------------------------------------------------

test_malformed_or_unreadable_reservations_fail_closed() {
  local out rc
  new_case malformed
  mkdir -p "$RES"
  printf 'not json\n' > "$RES/bad.json"
  out=$(policy t-new); rc=$?
  expect_code 2 "$rc" "a malformed reservation must refuse: $out"
  printf '%s\n' '{"v":2,"task":"x"}' > "$RES/bad.json"
  out=$(policy t-new); rc=$?
  expect_code 2 "$rc" "an unknown reservation version must refuse: $out"
  rm -f "$RES/bad.json"
  reservation t-locked 1 "x" 10
  chmod 000 "$RES/t-locked.test.json"
  out=$(policy t-new); rc=$?
  chmod 644 "$RES/t-locked.test.json"
  expect_code 2 "$rc" "an unreadable reservation must refuse: $out"
  pass "fail-closed: malformed, unknown-version, or unreadable reservations refuse"
}

test_unwritable_reservation_directory_fails_closed() {
  local out rc
  new_case unwritable
  mkdir -p "$RES"
  chmod 500 "$RES"
  out=$(policy t-new); rc=$?
  chmod 755 "$RES"
  expect_code 2 "$rc" "a reservation directory that cannot be written must refuse: $out"
  pass "fail-closed: an unwritable reservation directory refuses"
}

test_owner_identity_required() {
  local out rc
  new_case owner-required
  out=$(OWNER='' policy t-new); rc=$?
  expect_code 2 "$rc" "a launch without its owner process id must refuse: $out"
  out=$(OWNER="$(gone_owner)" policy t-new); rc=$?
  expect_code 2 "$rc" "an owner that is not running cannot be identified and must refuse: $out"
  pass "fail-closed: a missing or unidentifiable launching process refuses"
}

test_unresolved_root_home_fails_closed() {
  local out rc
  new_case badroot
  printf 'schema=fm-secondmate-parent.v1\nroute=nowhere\n' > "$HOME_DIR/.fm-secondmate-parent"
  out=$(policy t-new); rc=$?
  expect_code 2 "$rc" "an unresolvable root home must refuse: $out"
  assert_contains "$out" "cannot resolve the root Firstmate home" "the refusal must say why"
  pass "fail-closed: an unresolvable root home refuses"
}

# --- lock ---------------------------------------------------------------------

lock_holder() {  # <lockdir> <seconds>: hold the resource lock in a live process
  FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 9; : > "$2.held"; sleep "$3"' \
    _ "$ROOT" "$1" "$2" >/dev/null 2>&1 &
  OWNERS+=("$!")
  local i=0
  while [ ! -e "$1.held" ]; do i=$((i + 1)); [ "$i" -lt 200 ] || fail "lock holder never took the lock"; sleep 0.05; done
  printf '%s\n' "${OWNERS[-1]}"
}

test_lock_contention_times_out() {
  local out rc started elapsed
  new_case lock-timeout
  lock_holder "$OWN_STATE/.fork-resource-strata.lock" 30 >/dev/null
  started=$(date +%s)
  out=$(policy t-new); rc=$?
  elapsed=$(( $(date +%s) - started ))
  stop_owners
  expect_code 1 "$rc" "a held admission lock must refuse after the bounded wait: $out"
  assert_contains "$out" "is busy" "the refusal must say the resource is busy"
  [ "$elapsed" -ge 9 ] && [ "$elapsed" -le 25 ] || fail "the wait must be bounded near 10s, took ${elapsed}s"
  [ "$(reservations)" = 0 ] || fail "a timed-out launch must not reserve"
  pass "lock: contention beyond the bounded wait (~10s) refuses without reserving"
}

test_lock_left_by_dead_process_is_recovered() {
  local out rc holder
  new_case lock-recover
  holder=$(lock_holder "$OWN_STATE/.fork-resource-strata.lock" 600)
  kill -9 "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  out=$(policy t-new); rc=$?
  expect_code 0 "$rc" "a lock whose owner died must be reclaimed: $out"
  pass "lock: a lock left by a killed process is reclaimed by upstream's stale-owner recovery"
}

# --- cross-home ---------------------------------------------------------------

# add_secondmate <id>: a local secondmate home registered under this root.
add_secondmate() {
  local sm="$CASE/$1" root
  root=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$sm/state" "$sm/data" "$sm/config"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$sm/.fm-secondmate-parent"
  printf '%s\n' "- $1 - test domain (home: $(cd "$sm" && pwd -P); scope: tests; projects: alpha; added 2026-10-21)" >> "$HOME_DIR/data/secondmates.md"
  cp "$HOME_DIR/config/fork-policies" "$HOME_DIR/config/fork-resources.json" "$sm/config/"
  printf '%s\n' "$sm"
}

test_holders_in_secondmate_homes_count() {
  local out rc sm
  new_case cross-home
  sm=$(add_secondmate sm1)
  fork_holder "$sm" "$FAKE" sm-task "$MODEL_A" alive
  out=$(policy t-root); rc=$?
  expect_code 1 "$rc" "a live holder in a secondmate home must count from the root home: $out"
  pass "cross-home: a live holder in a local secondmate home counts against the machine resource"
}

test_secondmate_launch_sees_root_reservation() {
  local out rc sm owner
  new_case cross-reserve
  sm=$(add_secondmate sm1)
  owner=$(live_owner)
  out=$(OWNER=$owner policy t-root); rc=$?
  expect_code 0 "$rc" "the first launch must be admitted: $out"
  out=$(policy t-sm spawn "$sm"); rc=$?
  expect_code 1 "$rc" "a launch from a secondmate home must see the root-anchored reservation: $out"
  [ -z "$(find "$sm/state" -name '*.json' -path '*fork-reservations*' 2>/dev/null)" ] \
    || fail "reservations must be anchored in the root home, not the secondmate home"
  stop_owners
  pass "cross-home: launches from any local home share the root-anchored lock and reservations"
}

# --- concurrency --------------------------------------------------------------

# race <n>: launch n policy runs at once, each owned by its own live process;
# prints the exit codes, one per line.
race() {
  local n=$1 i owner pids=() codes="$CASE/codes"
  mkdir -p "$codes"
  for i in $(seq 1 "$n"); do
    owner=$(live_owner)
    ( OWNER=$owner policy "t-race-$i" > "$codes/$i.out"; printf '%s\n' "$?" > "$codes/$i.rc" ) &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i"; done
  cat "$codes"/*.rc
}

test_concurrent_launches_capacity_one() {
  local codes
  new_case race1 1
  codes=$(race 8)
  stop_owners
  assert_equals 1 "$(printf '%s\n' "$codes" | grep -cx 0)" "exactly one of 8 simultaneous launches may be admitted at capacity 1 (codes: $(printf '%s' "$codes" | tr '\n' ' '))"
  assert_equals 7 "$(printf '%s\n' "$codes" | grep -cx 1)" "the other 7 must be refused at capacity"
  assert_equals 1 "$(reservations)" "exactly one reservation must exist"
  pass "concurrency: 8 simultaneous launches at capacity 1 admit exactly one"
}

test_concurrent_launches_capacity_two() {
  local codes
  new_case race2 2
  codes=$(race 8)
  stop_owners
  assert_equals 2 "$(printf '%s\n' "$codes" | grep -cx 0)" "exactly two of 8 simultaneous launches may be admitted at capacity 2 (codes: $(printf '%s' "$codes" | tr '\n' ' '))"
  assert_equals 2 "$(reservations)" "exactly two reservations must exist"
  pass "concurrency: 8 simultaneous launches at capacity 2 admit exactly two"
}

test_concurrent_cleanup_of_expired_reservations() {
  local codes i owner
  new_case race-cleanup 1
  for i in 1 2 3 4 5; do
    owner=$(gone_owner)
    reservation "t-expired-$i" "$owner" "Wed Jan  1 00:00:00 2025" 600
  done
  codes=$(race 6)
  stop_owners
  assert_equals 0 "$(printf '%s\n' "$codes" | grep -cx 2)" "concurrent cleanup must never fail a launch as unusable (codes: $(printf '%s' "$codes" | tr '\n' ' '))"
  assert_equals 1 "$(printf '%s\n' "$codes" | grep -cx 0)" "exactly one launch may be admitted once the expired reservations are cleaned"
  [ -z "$(find "$RES" -name 't-expired-*')" ] || fail "every expired reservation must be removed"
  assert_equals 1 "$(reservations)" "only the admitted launch's reservation must remain"
  pass "concurrency: simultaneous launches clean up expired reservations safely and still admit exactly one"
}

fork_run_tests
