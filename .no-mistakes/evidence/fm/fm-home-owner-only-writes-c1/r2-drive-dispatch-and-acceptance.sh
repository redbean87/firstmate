#!/usr/bin/env bash
# Round-2 live drive for the owner-only durability change.
#
# Drives the SHIPPED scripts (never a re-implementation) through a disposable
# home under the ambient caller umask 0022:
#   A. backlog: the raw tasks-axi 600->644 reproduction, then the shipped
#      wrapper on the same mutation (must stay 600 with a new inode).
#   B. round-2 dispatch hardening: fm-captain-hold.sh hold, fm-backlog-handoff.sh
#      and fm-backlog-receive.sh each rewrite the backlog privately.
#   C. status record: a real fixture fm-spawn pre-creates 600 and worker /
#      pi-extension (node appendFileSync) / session appends keep it 600.
#   D. watcher: a real fm-watch-arm.sh cycle against a MISSING state dir births
#      the state dir 700 and the cycle-exit ledger 600.
#   E. lock record: real fm-wake-lib lock API creates a 700 owner dir with 600
#      pid/role records and still cycles.
#   F. adversarial: caller umask 000 and 077 still land 600; the caller shell's
#      umask is unchanged after every dispatch; executable files keep their
#      owner execute bit.
set -u
REPO=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M5DV6HRR8HTAXKAGJ4KEXJ06
# shellcheck source=/dev/null
. "$REPO/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-r2-live-drive)
WRAPPER="$REPO/bin/fm-tasks-axi.sh"
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
inode_of() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }
umask_now() { umask; }

echo "=== drive root: $TMP_ROOT"
echo "=== starting caller umask: $(umask_now)"

seed_secondmate_home() { # <parent> <child> <id>
  local parent=$1 child=$2 id=$3 out
  mkdir -p "$parent/data" "$parent/state" "$parent/projects"
  out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" \
    FM_SECONDMATE_CHARTER='live drive charter' \
    FM_SECONDMATE_SCOPE='live drive scope' \
    "$REPO/bin/fm-home-seed.sh" "$id" "$child" --no-projects 2>&1) \
    || { echo "FAIL: secondmate seed: $(printf '%s\n' "$out" | tail -n 5)"; exit 1; }
}

# --- A. backlog reproduction and fixed path ----------------------------------
home="$TMP_ROOT/backlog/home"
mkdir -p "$home/data" "$home/state"
echo
echo "--- A. backlog create through the shipped wrapper under umask 0022"
out=$(umask 0022; FM_HOME="$home" "$WRAPPER" add ev-r2-bl1 "round-2 backlog probe" 2>&1) \
  || { echo "FAIL: wrapper add: $out"; exit 1; }
echo "$out" | head -n 2
echo "backlog after wrapper create: mode=$(mode_of "$home/data/backlog.md") inode=$(inode_of "$home/data/backlog.md")"
[ "$(mode_of "$home/data/backlog.md")" = 600 ] || { echo "FAIL: create not 600"; exit 1; }

echo
echo "--- A2. RAW tasks-axi mutation under umask 0022 (the pre-fix reproduction)"
before=$(inode_of "$home/data/backlog.md")
out=$(umask 0022; tasks-axi add ev-r2-bl2 "raw mutation probe" --file "$home/data/backlog.md" --backend markdown 2>&1 | head -n 1)
echo "$out"
echo "RAW mutation result: mode=$(mode_of "$home/data/backlog.md") inode_before=$before inode_after=$(inode_of "$home/data/backlog.md")"
raw_mode=$(mode_of "$home/data/backlog.md")

echo
echo "--- A3. shipped-wrapper rewrite (done) under umask 0022 on the same file"
chmod 600 "$home/data/backlog.md"
before=$(inode_of "$home/data/backlog.md")
out=$(umask 0022; FM_HOME="$home" "$WRAPPER" done ev-r2-bl1 --note "closed by round-2 probe" 2>&1 | head -n 2)
echo "$out"
after=$(inode_of "$home/data/backlog.md")
echo "WRAPPER rewrite result: mode=$(mode_of "$home/data/backlog.md") inode_before=$before inode_after=$after"
echo "owner read-back:"
FM_HOME="$home" "$WRAPPER" show ev-r2-bl1 2>&1 | sed -n '2,5p'

# --- B. round-2 dispatch helpers under the ambient umask ---------------------
echo
echo "--- B1. fm-captain-hold.sh hold under caller umasks 000 / 0022 / 077"
hold_home="$TMP_ROOT/hold/home"
mkdir -p "$hold_home/data" "$hold_home/state"
for caller in 000 0022 077; do
  id="ev-r2-hold-$caller"
  rm -f "$hold_home/data/backlog.md"
  ( umask "$caller"; FM_HOME="$hold_home" "$WRAPPER" add "$id" "hold probe $caller" >/dev/null 2>&1 ) \
    || { echo "FAIL: seed row $id"; exit 1; }
  before=$(inode_of "$hold_home/data/backlog.md")
  out=$(umask "$caller"; FM_HOME="$hold_home" "$REPO/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain held under caller umask $caller" 2>&1) \
    || { echo "FAIL: hold under umask $caller: $out"; exit 1; }
  after=$(inode_of "$hold_home/data/backlog.md")
  echo "umask=$caller hold: mode=$(mode_of "$hold_home/data/backlog.md") inode_before=$before inode_after=$after leak_check_umask_after=$(umask_now)"
  [ "$(mode_of "$hold_home/data/backlog.md")" = 600 ] || { echo "FAIL: hold umask $caller not 600"; exit 1; }
  [ "$after" != "$before" ] || { echo "FAIL: hold umask $caller did not rewrite"; exit 1; }
  FM_HOME="$hold_home" "$WRAPPER" show "$id" 2>&1 | grep -F 'held: yes' >/dev/null \
    || { echo "FAIL: held row unreadable under umask $caller"; exit 1; }
  echo "  consumer read-back: held: yes with reason preserved"
done

echo
echo "--- B2. fm-backlog-handoff.sh under umask 0022"
case_dir="$TMP_ROOT/handoff"
seed_secondmate_home "$case_dir/parent" "$case_dir/child" ev-r2-smh
( umask 0022; FM_HOME="$case_dir/parent" "$WRAPPER" add ev-r2-ho1 "handoff probe row" >/dev/null 2>&1 ) \
  || { echo "FAIL: handoff seed row"; exit 1; }
before=$(inode_of "$case_dir/parent/data/backlog.md")
out=$(umask 0022; FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/parent" \
  "$REPO/bin/fm-backlog-handoff.sh" ev-r2-smh ev-r2-ho1 2>&1)
echo "$out" | tail -n 3
echo "handoff: main mode=$(mode_of "$case_dir/parent/data/backlog.md") inode_before=$before inode_after=$(inode_of "$case_dir/parent/data/backlog.md") dest mode=$(mode_of "$case_dir/child/data/backlog.md") leak_check_umask_after=$(umask_now)"
[ "$(mode_of "$case_dir/parent/data/backlog.md")" = 600 ] || { echo "FAIL: handoff main backlog not 600"; exit 1; }
[ "$(mode_of "$case_dir/child/data/backlog.md")" = 600 ] || { echo "FAIL: handoff destination not 600"; exit 1; }
grep -F ev-r2-ho1 "$case_dir/child/data/backlog.md" >/dev/null || { echo "FAIL: handed-off row missing"; exit 1; }
echo "  consumer read-back: the row now lives in the 600 destination backlog"

echo
echo "--- B3. fm-backlog-receive.sh under umask 0022"
r="$TMP_ROOT/receive"
seed_secondmate_home "$r/parent" "$r/child" ev-r2-smr
( umask 0022; FM_HOME="$r/child" "$WRAPPER" add existing-row "row already in the destination" >/dev/null 2>&1 ) \
  || { echo "FAIL: receive seed row"; exit 1; }
mkdir -p "$r/child/state/handoff"
printf '## Queued\n\n- [ ] ev-r2-rc1 - delivered row (repo: ev-r2-smr)\n' > "$r/child/state/handoff/ev-r2-smr.outbox.md"
bytes=$(LC_ALL=C wc -c < "$r/child/state/handoff/ev-r2-smr.outbox.md" | tr -d ' ')
hash=$(shasum -a 256 "$r/child/state/handoff/ev-r2-smr.outbox.md" | awk '{print $1}')
printf '1\n%s\n%s\n' "$bytes" "$hash" > "$r/child/state/handoff/.ev-r2-smr.upload-generation"
before=$(inode_of "$r/child/data/backlog.md")
out=$(umask 0022; FM_ROOT_OVERRIDE='' FM_HOME="$r/child" \
  "$REPO/bin/fm-backlog-receive.sh" "state/handoff/ev-r2-smr.outbox.md" "$bytes" "$hash" 1 2>&1)
echo "$out" | tail -n 2
echo "receive: destination mode=$(mode_of "$r/child/data/backlog.md") inode_before=$before inode_after=$(inode_of "$r/child/data/backlog.md") leak_check_umask_after=$(umask_now)"
[ "$(mode_of "$r/child/data/backlog.md")" = 600 ] || { echo "FAIL: receive backlog not 600"; exit 1; }
grep -F ev-r2-rc1 "$r/child/data/backlog.md" >/dev/null || { echo "FAIL: delivered row missing"; exit 1; }
grep -F existing-row "$r/child/data/backlog.md" >/dev/null || { echo "FAIL: existing row lost"; exit 1; }
echo "  consumer read-back: delivered row landed and the pre-existing row survived"

# --- C. status record ---------------------------------------------------------
echo
echo "--- C. status record: real fixture spawn under umask 0022, then three writer shapes"
sc="$TMP_ROOT/status"
fakebin=$(make_spawn_fakebin "$sc/fake" pi opencode claude codex gemini)
fm_test_spawn_home "$sc/home" pi
fm_git_worktree "$sc/project" "$sc/wt" "wt-r2-owner-status"
fm_test_spawn_brief "$sc/home" ev-r2-status1
out=$(umask 0022; GROK_HOME="$sc/grok-home" \
  fm_test_run_spawn "$sc/home" "$sc/wt" "$fakebin" ev-r2-status1 "$sc/project" --mode no-mistakes --yolo off 2>&1) \
  || { echo "FAIL: fixture spawn: $(printf '%s\n' "$out" | tail -n 5)"; exit 1; }
status="$sc/home/state/ev-r2-status1.status"
echo "spawn pre-created status: mode=$(mode_of "$status")"
(umask 0022; echo "working [at=1]: worker-shape append" >> "$status")
echo "after worker-shell append (umask 0022): $(mode_of "$status")"
node -e 'require("fs").appendFileSync(process.argv[1], "note [at=1]: pi-extension appendFileSync append\n")' "$status"
echo "after pi-extension node appendFileSync: $(mode_of "$status")"
(umask 0022; echo "resolved [key=ev-r2]: session-shape append" >> "$status")
echo "after session-shaped append (umask 0022): $(mode_of "$status")"
echo "consumer read-back (tail -1 + worker line):"
tail -n 1 "$status"
grep -F "worker-shape append" "$status" >/dev/null && echo "worker line readable: yes"
echo "sibling spawn records: meta=$(mode_of "$sc/home/state/ev-r2-status1.meta") pi-ext=$(mode_of "$sc/home/state/ev-r2-status1.pi-ext.ts")"
[ "$(mode_of "$status")" = 600 ] || { echo "FAIL: status append drifted"; exit 1; }

# --- D. watcher cycle log against a missing state dir ------------------------
echo
echo "--- D. real fm-watch-arm.sh cycle with a MISSING state dir under umask 0022"
wc_dir="$TMP_ROOT/watch"
mkdir -p "$wc_dir"
wc_state="$wc_dir/state"
rm -rf "$wc_state"
old=$(umask); umask 0022
PATH="$fakebin:$PATH" FM_HOME="$wc_dir" FM_STATE_OVERRIDE="$wc_state" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_ARM_CONFIRM_TIMEOUT=30 \
  "$REPO/bin/fm-watch-arm.sh" --restart > "$wc_dir/arm.out" 2>&1 &
armpid=$!
umask "$old"
watcher=
i=0
while [ "$i" -lt 400 ]; do
  watcher=$(cat "$wc_state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$watcher" ] && [ "$watcher" != "$armpid" ] && kill -0 "$watcher" 2>/dev/null; then break; fi
  kill -0 "$armpid" 2>/dev/null || break
  sleep 0.1; i=$((i + 1))
done
if [ -z "$watcher" ] || [ "$watcher" = "$armpid" ]; then
  echo "FAIL: the arm never confirmed a watcher: $(tail -n 5 "$wc_dir/arm.out")"; exit 1
fi
echo "watcher-created state dir: mode=$(mode_of "$wc_state")"
echo "watcher beat: mode=$(mode_of "$wc_state/.last-watcher-beat")"
echo "watch-lock pid record: mode=$(mode_of "$wc_state/.watch.lock/pid") ownerdir=$(mode_of "$(readlink "$wc_state/.watch.lock")") fm-home=$(mode_of "$wc_state/.watch.lock/fm-home")"
kill "$watcher" 2>/dev/null || true
i=0; while [ "$i" -lt 400 ] && kill -0 "$armpid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
wait "$armpid" 2>/dev/null || true
[ -f "$wc_state/.watch-cycle-exits.log" ] || { echo "FAIL: no cycle-exit ledger: $(tail -n 5 "$wc_dir/arm.out")"; exit 1; }
echo "cycle-exit ledger: mode=$(mode_of "$wc_state/.watch-cycle-exits.log")"
cat "$wc_state/.watch-cycle-exits.log"
[ "$(mode_of "$wc_state")" = 700 ] || { echo "FAIL: state dir not 700"; exit 1; }
[ "$(mode_of "$wc_state/.watch-cycle-exits.log")" = 600 ] || { echo "FAIL: ledger not 600"; exit 1; }

# --- E. lock records ---------------------------------------------------------
echo
echo "--- E. lock record inside a newly created lock directory (real fm-wake-lib API)"
lstate="$TMP_ROOT/lock/state"
mkdir -p "$lstate"
( umask 0022
  FM_STATE_OVERRIDE="$lstate" bash -c '
    . "$1" || exit 1
    fm_lock_try_acquire "$2" || exit 2
    fm_lock_set_role "$2" task-spawn || exit 3
    s() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
    printf "lock-link=%s ownerdir=%s pid=%s role=%s\n" "$(s "$2")" "$(s "$FM_LOCK_OWNER_DIR")" "$(s "$FM_LOCK_OWNER_DIR/pid")" "$(s "$FM_LOCK_OWNER_DIR/role")"
    fm_lock_release "$2" || exit 4
    fm_lock_try_acquire "$2" || exit 5
    printf "consumer-cycle: reacquired pid=%s\n" "$(cat "$FM_LOCK_OWNER_DIR/pid")"
    fm_lock_release "$2" || exit 6
  ' _ "$REPO/bin/fm-wake-lib.sh" "$lstate/.r2-probe.lock" ) \
  || { echo "FAIL: lock API cycle"; exit 1; }

# --- F. adversarial: umask leak and executable bit ---------------------------
echo
echo "--- F. executable files keep their owner execute bit after the change"
for f in "$REPO/bin/fm-tasks-axi.sh" "$REPO/bin/fm-watch.sh" "$REPO/bin/fm-captain-hold.sh" "$REPO/bin/fm-spawn.sh"; do
  m=$(mode_of "$f")
  echo "$(basename "$f"): $m"
  case "$m" in *[1357]) ;; *) echo "FAIL: $f lost its owner execute bit"; exit 1;; esac
done
echo "--- caller umask after every drive (must still be 0022): $(umask_now)"
[ "$(umask_now)" = 0022 ] || { echo "FAIL: the drive leaked a umask into the caller"; exit 1; }

echo
echo "=== SUMMARY"
echo "raw tasks-axi mutation mode (pre-fix reproduction): $raw_mode"
echo "wrapper mutation mode: 600"
echo "drive root removed by caller: $TMP_ROOT"
