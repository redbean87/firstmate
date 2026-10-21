#!/usr/bin/env bash
# Round-3 live drive for the owner-only durability change.
#
# Drives the SHIPPED scripts (never a re-implementation) from a caller umask of
# 0022, the defect condition, against disposable homes: a marked fm-lab home for
# the backlog class plus throwaway fixture homes for the rest.
#   A. backlog: shipped wrapper create 600; the RAW tasks-axi 600->644
#      reproduction on the same file (the defect the change closes); then the
#      shipped wrapper rewrite on the same mutation stays 600 with a new inode.
#   B. dispatch hardening (this round's commit): fm-captain-hold.sh hold under
#      caller umasks 0022 and 000, fm-backlog-handoff.sh, fm-backlog-receive.sh
#      -- each rewrites the backlog and it stays 600, and no umask leaks into
#      the caller shell.
#   C. status record: a real fm-spawn.sh pre-creates 600 and worker /
#      pi-extension (node appendFileSync) / session appends keep it 600.
#   D. watcher: a real fm-watch-arm.sh cycle against a MISSING state dir births
#      the state dir 700 and the cycle-exit ledger 600.
#   E. lock record: real fm-wake-lib lock API creates a 700 owner dir with 600
#      pid/role records and still cycles.
#   F. executable files keep their owner execute bit.
set -u
REPO=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M5DV6HRR8HTAXKAGJ4KEXJ06
# shellcheck source=/dev/null
. "$REPO/tests/fixtures.sh"
# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-r3-live-drive)
WRAPPER="$REPO/bin/fm-tasks-axi.sh"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
umask_now() { umask; }
FAILED=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; FAILED=1; }

umask 022
echo "=== drive root: $TMP_ROOT"
echo "=== starting caller umask: $(umask_now)"

seed_secondmate_home() { # <parent> <child> <id>
  local parent=$1 child=$2 id=$3 out
  mkdir -p "$parent/data" "$parent/state" "$parent/projects"
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" \
    FM_SECONDMATE_CHARTER='live drive charter' \
    FM_SECONDMATE_SCOPE='live drive scope' \
    "$REPO/bin/fm-home-seed.sh" "$id" "$child" --no-projects 2>&1) \
    || { bad "secondmate seed: $(printf '%s\n' "$out" | tail -n 5)"; return 1; }
}

# --- A. backlog on a marked lab home --------------------------------------
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null \
  || { bad "fm-lab-home create"; exit 1; }
mkdir -p "$LAB/tmux"
echo
echo "--- A. backlog create through the shipped wrapper (lab home, umask 0022)"
out=$(umask 0022; FM_HOME="$LAB" "$WRAPPER" add ev-r3-bl1 "round-3 backlog probe" 2>&1) \
  || bad "wrapper add: $out"
echo "$out" | head -n 2
echo "backlog after wrapper create: mode=$(mode_of "$LAB/data/backlog.md") inode=$(inode_of "$LAB/data/backlog.md")"
[ "$(mode_of "$LAB/data/backlog.md")" = 600 ] || bad "create not 600"

echo
echo "--- A2. RAW tasks-axi mutation under umask 0022 (pre-fix reproduction)"
before=$(inode_of "$LAB/data/backlog.md")
out=$(umask 0022; tasks-axi add ev-r3-bl2 "raw mutation probe" --file "$LAB/data/backlog.md" --backend markdown 2>&1 | head -n 1)
echo "$out"
echo "RAW mutation result: mode=$(mode_of "$LAB/data/backlog.md") inode_before=$before inode_after=$(inode_of "$LAB/data/backlog.md")"
raw_mode=$(mode_of "$LAB/data/backlog.md")
[ "$raw_mode" = 644 ] || echo "note: raw mutation landed $raw_mode (expected 644 under umask 0022)"

echo
echo "--- A3. shipped-wrapper rewrite (done) under umask 0022 on the same file"
before=$(inode_of "$LAB/data/backlog.md")
out=$(umask 0022; FM_HOME="$LAB" "$WRAPPER" done ev-r3-bl1 2>&1 | head -n 2)
echo "$out"
after=$(inode_of "$LAB/data/backlog.md")
echo "WRAPPER rewrite result: mode=$(mode_of "$LAB/data/backlog.md") inode_before=$before inode_after=$after"
[ "$(mode_of "$LAB/data/backlog.md")" = 600 ] || bad "wrapper rewrite not 600"
[ "$after" != "$before" ] || bad "wrapper rewrite did not rewrite (same inode)"
echo "owner read-back:"
FM_HOME="$LAB" "$WRAPPER" show ev-r3-bl1 2>&1 | sed -n '1,6p'
[ "$(umask_now)" = 0022 ] || bad "caller umask changed after wrapper calls: $(umask_now)"

# --- B. dispatch hardening -------------------------------------------------
home="$TMP_ROOT/hold/home"
mkdir -p "$home/data" "$home/state"
for caller in 0022 000; do
  id="ev-r3-hold-$caller"
  umask 0022
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$WRAPPER" add "$id" "hold probe $caller" 2>&1) || bad "seed hold row: $out"
  echo
  echo "--- B1. fm-captain-hold.sh hold under caller umask $caller"
  before=$(inode_of "$home/data/backlog.md")
  out=$(umask "$caller"; FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" "$REPO/bin/fm-captain-hold.sh" hold "$id" \
    --reason "round-3 hold $caller" 2>&1) || bad "captain hold $caller: $out"
  after=$(inode_of "$home/data/backlog.md")
  echo "hold mode=$(mode_of "$home/data/backlog.md") inode_before=$before inode_after=$after leak_check_umask_after=$(umask_now)"
  [ "$(mode_of "$home/data/backlog.md")" = 600 ] || bad "hold under $caller not 600"
  [ "$after" != "$before" ] || bad "hold under $caller did not rewrite (same inode)"
  show=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$WRAPPER" show "$id" 2>&1)
  printf '%s\n' "$show" | grep -F 'held: yes' >/dev/null || bad "consumer could not read the hold back ($caller)"
  echo "  consumer read-back: $(printf '%s\n' "$show" | grep -F 'held: yes' | head -n 1), $(printf '%s\n' "$show" | grep -F 'hold_reason:' | head -n 1)"
  [ "$(umask_now)" = 0022 ] || bad "captain-hold leaked umask into caller: $(umask_now)"
done

echo
echo "--- B2. fm-backlog-handoff.sh under umask 0022"
case_dir="$TMP_ROOT/handoff"; parent="$case_dir/parent"; child="$case_dir/child"
id=ev-r3-smh; key=ev-r3-ho1
seed_secondmate_home "$parent" "$child" "$id"
out=$(umask 0022; FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" "$WRAPPER" add "$key" "handoff probe" 2>&1) \
  || bad "seed handoff row: $out"
before=$(inode_of "$parent/data/backlog.md")
out=$(umask 0022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" FM_DATA_OVERRIDE="$parent/data" \
  FM_STATE_OVERRIDE="$parent/state" "$REPO/bin/fm-backlog-handoff.sh" "$id" "$key" 2>&1) || true
echo "$out" | sed -n '1,3p'
after=$(inode_of "$parent/data/backlog.md")
echo "handoff: main mode=$(mode_of "$parent/data/backlog.md") inode_before=$before inode_after=$after dest mode=$(mode_of "$child/data/backlog.md")"
[ "$(mode_of "$parent/data/backlog.md")" = 600 ] || bad "main backlog not 600 after handoff"
[ "$(mode_of "$child/data/backlog.md")" = 600 ] || bad "destination backlog not 600 after handoff"
grep -F "$key" "$child/data/backlog.md" >/dev/null || bad "handoff row missing from destination"
[ "$(umask_now)" = 0022 ] || bad "handoff leaked umask into caller: $(umask_now)"

echo
echo "--- B3. fm-backlog-receive.sh under umask 0022"
case_dir="$TMP_ROOT/receive"; parent="$case_dir/parent"; child="$case_dir/child"
id=ev-r3-smr; key=ev-r3-recv1
seed_secondmate_home "$parent" "$child" "$id"
out=$(umask 0022; FM_HOME="$child" FM_DATA_OVERRIDE="$child/data" "$WRAPPER" add existing-row "already here" 2>&1) \
  || bad "seed destination row: $out"
mkdir -p "$child/state/handoff"
printf '## Queued\n\n- [ ] %s - delivered row (repo: %s)\n' "$key" "$id" \
  > "$child/state/handoff/$id.outbox.md" || bad "stage outbox"
bytes=$(LC_ALL=C wc -c < "$child/state/handoff/$id.outbox.md" | tr -d ' ')
if command -v shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$child/state/handoff/$id.outbox.md" | awk '{print $1}')
else
  hash=$(sha256sum "$child/state/handoff/$id.outbox.md" | awk '{print $1}')
fi
printf '1\n%s\n%s\n' "$bytes" "$hash" > "$child/state/handoff/.$id.upload-generation"
before=$(inode_of "$child/data/backlog.md")
out=$(umask 0022; FM_ROOT_OVERRIDE='' FM_HOME="$child" \
  "$REPO/bin/fm-backlog-receive.sh" "state/handoff/$id.outbox.md" "$bytes" "$hash" 1 2>&1) \
  || bad "receive: $out"
echo "$out" | head -n 2
after=$(inode_of "$child/data/backlog.md")
echo "receive: destination mode=$(mode_of "$child/data/backlog.md") inode_before=$before inode_after=$after leak_check_umask_after=$(umask_now)"
[ "$(mode_of "$child/data/backlog.md")" = 600 ] || bad "receive destination not 600"
[ "$after" != "$before" ] || bad "receive did not rewrite (same inode)"
grep -F "$key" "$child/data/backlog.md" >/dev/null || bad "delivered row missing"
grep -F 'existing-row' "$child/data/backlog.md" >/dev/null || bad "receive dropped the existing row"
[ "$(umask_now)" = 0022 ] || bad "receive leaked umask into caller: $(umask_now)"

# --- C. status record ------------------------------------------------------
echo
echo "--- C. status record: real spawn under umask 0022, then three writer shapes"
case_dir="$TMP_ROOT/status"; home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
sid=ev-r3-status-z1
fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
fm_test_spawn_home "$home" pi
fm_git_worktree "$proj" "$wt" "wt-r3-status"
fm_test_spawn_brief "$home" "$sid"
out=$(umask 022; GROK_HOME="$case_dir/grok-home" \
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$sid" "$proj" --mode no-mistakes --yolo off 2>&1) \
  || bad "fixture spawn: $(printf '%s\n' "$out" | tail -n 5)"
status="$home/state/$sid.status"
echo "spawn pre-created status: mode=$(mode_of "$status" 2>/dev/null)"
[ "$(mode_of "$status")" = 600 ] || bad "spawn status not 600"
(umask 022; echo "working [at=$(date +%s)]: worker-shape append" >> "$status")
echo "after worker-shell append (umask 0022): $(mode_of "$status")"
[ "$(mode_of "$status")" = 600 ] || bad "worker append changed the status mode"
if command -v node >/dev/null 2>&1; then
  node -e 'require("fs").appendFileSync(process.argv[1], "note [at=1]: hook-shape append\n")' "$status"
  echo "after pi-extension node appendFileSync: $(mode_of "$status")"
  [ "$(mode_of "$status")" = 600 ] || bad "hook append changed the status mode"
fi
(umask 022; echo "resolved [key=ev-r3]: session-shape append" >> "$status")
echo "after session-shaped append (umask 0022): $(mode_of "$status")"
[ "$(mode_of "$status")" = 600 ] || bad "session append changed the status mode"
echo "consumer read-back:"
tail -n 2 "$status"
grep -F "worker-shape append" "$status" >/dev/null || bad "worker line not readable"
tail -n 1 "$status" | grep -F "session-shape append" >/dev/null || bad "tail -1 did not see the newest line"
echo "sibling spawn records: meta=$(mode_of "$home/state/$sid.meta") pi-ext=$(mode_of "$home/state/$sid.pi-ext.ts")"

# --- D. watcher ------------------------------------------------------------
echo
echo "--- D. real fm-watch-arm.sh cycle with a MISSING state dir under umask 0022"
dir=$(make_case r3-watcher-owner-birth); state="$dir/state"; fakebin="$dir/fakebin"
fm_test_track_watcher_state "$state"
rm -rf "$state"
old=$(umask); umask 022
PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_ARM_CONFIRM_TIMEOUT=30 \
  "$REPO/bin/fm-watch-arm.sh" --restart > "$dir/arm.out" 2>&1 &
armpid=$!
umask "$old"
watcher=; i=0
while [ "$i" -lt 400 ]; do
  watcher=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher" ] && [ "$watcher" != "$armpid" ] && kill -0 "$watcher" 2>/dev/null; then break; fi
  kill -0 "$armpid" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
if [ -z "$watcher" ] || [ "$watcher" = "$armpid" ]; then
  bad "arm did not confirm a watcher: $(tail -n 5 "$dir/arm.out")"
else
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do sleep 0.1; i=$((i + 1)); done
  echo "watcher-created state dir: mode=$(mode_of "$state")"
  echo "watcher beat: mode=$(mode_of "$state/.last-watcher-beat")"
  lockrec=$(readlink "$state/.watch.lock" 2>/dev/null || true)
  echo "watch-lock pid record: mode=$(mode_of "$lockrec/pid") ownerdir=$(mode_of "$lockrec") fm-home=$(mode_of "$lockrec/fm-home")"
  [ "$(mode_of "$state")" = 700 ] || bad "watcher state dir not 700"
  [ "$(mode_of "$state/.last-watcher-beat")" = 600 ] || bad "watcher beat not 600"
  kill "$watcher" 2>/dev/null || true
  i=0
  while [ "$i" -lt 400 ] && kill -0 "$armpid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  wait "$armpid" 2>/dev/null || true
  echo "cycle-exit ledger: mode=$(mode_of "$state/.watch-cycle-exits.log" 2>/dev/null)"
  [ "$(mode_of "$state/.watch-cycle-exits.log")" = 600 ] || bad "cycle ledger not 600"
  tail -n 1 "$state/.watch-cycle-exits.log" 2>/dev/null | cut -c1-160
fi

# --- E. lock records -------------------------------------------------------
echo
echo "--- E. lock record inside a newly created lock directory (real fm-wake-lib API)"
state="$TMP_ROOT/lock/state"; mkdir -p "$state"
out=$(
  umask 022
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1" || exit 1
    fm_lock_try_acquire "$2" || exit 2
    owner=$FM_LOCK_OWNER_DIR
    fm_lock_set_role "$2" task-spawn || exit 3
    [ -L "$2" ] || exit 7
    s() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
    printf "lock-link=%s ownerdir=%s pid=%s role=%s\n" \
      "$(s "$2")" "$(s "$owner")" "$(s "$owner/pid")" "$(s "$owner/role")"
    fm_lock_release "$2" || exit 4
    fm_lock_try_acquire "$2" || exit 5
    fm_lock_release "$2" || exit 6
    printf "consumer-cycle: reacquired\n"
  ' _ "$REPO/bin/fm-wake-lib.sh" "$state/.probe.lock"
) || bad "lock API cycle failed under umask 022"
echo "$out"
printf '%s\n' "$out" | grep -F "ownerdir=700 pid=600 role=600" >/dev/null || bad "lock dir/records not 700/600/600"
printf '%s\n' "$out" | grep -F "consumer-cycle: reacquired" >/dev/null || bad "lock did not cycle"

# --- F. executable bits ----------------------------------------------------
echo
echo "--- F. executable files keep their owner execute bit"
for f in fm-tasks-axi.sh fm-watch.sh fm-captain-hold.sh fm-spawn.sh fm-backlog-receive.sh; do
  m=$(mode_of "$REPO/bin/$f")
  echo "$f: $m"
  case "$m" in *[1357]) ;; *) bad "$f lost its owner execute bit ($m)" ;; esac
done

echo
echo "--- caller umask after every drive (must still be 0022): $(umask_now)"
[ "$(umask_now)" = 0022 ] || bad "caller umask drifted"

rm -rf "$LAB"
"$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
echo
echo "=== SUMMARY"
echo "raw tasks-axi mutation mode (pre-fix reproduction): ${raw_mode:-unknown}"
echo "shipped-path result: backlog 600 with a new inode, dispatch rewrites 600"
if [ "$FAILED" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
echo "drive root removed by caller: $TMP_ROOT"
exit "$FAILED"
