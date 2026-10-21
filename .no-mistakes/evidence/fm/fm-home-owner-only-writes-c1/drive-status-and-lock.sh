#!/usr/bin/env bash
# Live drive for two acceptance classes of the owner-only durability change:
#   * a status record created by a real bin/fm-spawn.sh under the ambient umask
#     0022, then appended by the worker shell, the pi extension's Node
#     appendFileSync (vendor hook shape) and a session-shaped shell append.
#   * a lock record inside a newly created lock directory, through the real
#     bin/fm-wake-lib.sh lock API (acquire -> role -> release -> re-acquire).
# Everything is disposable under the test tmp root; the drive only reads the
# production scripts under $ROOT/bin.
set -u
REPO=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M5DV6HRR8HTAXKAGJ4KEXJ06
# shellcheck source=/dev/null
. "$REPO/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-owner-only-drive)
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "=== drive root: $TMP_ROOT  caller umask: $(umask)"

# --- status record through a real fm-spawn ------------------------------------
case_dir="$TMP_ROOT/status"
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
id=ev-live-status1
fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini)
fm_test_spawn_home "$home" pi
fm_git_worktree "$proj" "$wt" "wt-live-owner-status"
fm_test_spawn_brief "$home" "$id"
out=$(umask 0022; GROK_HOME="$case_dir/grok-home" \
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off 2>&1) \
  || { echo "FAIL: fixture spawn: $(printf '%s\n' "$out" | tail -n 5)"; exit 1; }
status="$home/state/$id.status"
echo "--- spawn-created status record: $(mode_of "$status")  $status"
echo "--- sibling spawn records: meta=$(mode_of "$home/state/$id.meta") pi-ext=$(mode_of "$home/state/$id.pi-ext.ts")"

(umask 0022; echo "working [at=$(date +%s)]: worker-shell append" >> "$status")
echo "--- after worker-shell append under umask 0022: $(mode_of "$status")"
node -e 'require("fs").appendFileSync(process.argv[1], "note [at=1]: pi-extension appendFileSync append\n")' "$status"
echo "--- after pi-extension (node appendFileSync) append: $(mode_of "$status")"
(umask 0022; echo "resolved [key=ev-live]: session-shell append" >> "$status")
echo "--- after session-shaped append under umask 0022: $(mode_of "$status")"
echo "--- owner consumer read (tail -1 and matching worker line):"
tail -n 1 "$status"
grep -F "worker-shell append" "$status" >/dev/null && echo "worker line readable: yes"
echo "--- wake rows after a fresh spawn (must be none from spawn-time creation):"
if [ -f "$home/state/.wake-queue" ]; then cat "$home/state/.wake-queue"; else echo "(no wake queue: fresh spawn published no wake row)"; fi

# --- lock record through the real wake-library lock API -----------------------
state="$TMP_ROOT/lock/state"
mkdir -p "$state"
( umask 0022
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1" || exit 1
    fm_lock_try_acquire "$2" || exit 2
    fm_lock_set_role "$2" task-spawn || exit 3
    s() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
    printf "lockdir=%s ownerdir=%s pid=%s role=%s\n" "$(s "$2")" "$(s "$FM_LOCK_OWNER_DIR")" "$(s "$FM_LOCK_OWNER_DIR/pid")" "$(s "$FM_LOCK_OWNER_DIR/role")"
    fm_lock_release "$2" || exit 4
    fm_lock_try_acquire "$2" || exit 5
    printf "consumer-cycle-reacquired=ok pid=%s\n" "$(cat "$FM_LOCK_OWNER_DIR/pid")"
    fm_lock_release "$2" || exit 6
  ' _ "$REPO/bin/fm-wake-lib.sh" "$state/.live-probe.lock" )
echo "--- caller umask after the drive: $(umask)"
