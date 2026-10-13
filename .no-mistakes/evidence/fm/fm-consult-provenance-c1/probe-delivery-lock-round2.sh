#!/usr/bin/env bash
# Round-2 disposable live probe: does the real bin/fm-chatgpt-loop.sh delivery
# write wait on the same per-task meta lock (state/.meta-<id>.lock) that
# fm-spawn, fm-control, fm-teardown and fm-promote take? The probe holds that
# exact lock for 3s in a background process, starts the real loop's dispatch
# concurrently, samples the worker record while the lock is still held, then
# confirms the delivery landed once the lock was released.
set -u
ROOT=${ROOT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M4SQCZ40RY5T5FST3V4MXFFD}
LOOP="$ROOT/bin/fm-chatgpt-loop.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lockprobe2.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB/home"
export FM_DATA_OVERRIDE="$FM_HOME/data"
export FM_STATE_OVERRIDE="$FM_HOME/state"
mkdir -p "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE"
printf 'objective\n' > "$LAB/objective.txt"
cat > "$LAB/spawn.sh" <<'SH'
#!/usr/bin/env bash
meta="${FM_STATE_OVERRIDE:?}/$1.meta"
printf 'window=stub:fm-%s\nkind=ship\n' "$1" > "$meta"
exit 0
SH
chmod +x "$LAB/spawn.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/send.sh"; chmod +x "$LAB/send.sh"
export FM_CHATGPT_LOOP_SPAWN="$LAB/spawn.sh"
export FM_CHATGPT_LOOP_SEND="$LAB/send.sh"

bash "$LOOP" init --task lockprobe --objective-file "$LAB/objective.txt" >/dev/null
f="$FM_DATA_OVERRIDE/lockprobe/chatgpt-loop.json"
jq '.phase="audit-dispatch" | .audit_prompt="AUDIT"' "$f" > "$f.t" && mv "$f.t" "$f"

cat > "$LAB/hold.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-wake-lib.sh"
lock=$(fm_meta_lock_path "$1")
fm_lock_acquire_wait "$lock" || exit 1
printf 'HOLDER_ACQUIRED %s\n' "$lock" > "$2"
sleep 3
fm_lock_release "$lock"
printf 'HOLDER_RELEASED\n' >> "$2"
SH
chmod +x "$LAB/hold.sh"
printf 'window=stub:fm-w9\nkind=ship\n' > "$FM_STATE_OVERRIDE/w9.meta"

ROOT="$ROOT" "$LAB/hold.sh" "$FM_STATE_OVERRIDE/w9.meta" "$LAB/holder.state" &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$LAB/holder.state" ] && break; sleep 0.05; done
echo "-- lock holder --"; cat "$LAB/holder.state"
echo "-- w9.meta while the lock is held (consult_delivered must be absent) --"
sed -n 'p' "$FM_STATE_OVERRIDE/w9.meta"
if grep -q '^consult_delivered=' "$FM_STATE_OVERRIDE/w9.meta"; then
  echo "RESULT: FAIL - delivery was written while the per-task meta lock was held"
else
  echo "RESULT: write is waiting on the lock (field absent)"
fi

start=$(date +%s.%N)
STUB_SPAWN_PRESERVE=1 bash "$LOOP" dispatch --stage audit --task lockprobe -- w9 myproj --mode local-only --yolo off >/dev/null
rc=$?
end=$(date +%s.%N)
wait "$HOLDER"
echo "dispatch rc=$rc elapsed=$(awk "BEGIN{printf \"%.1f\", $end-$start}")s (holder held 3s)"
echo "-- w9.meta after dispatch --"; sed -n 'p' "$FM_STATE_OVERRIDE/w9.meta"
echo "-- holder final --"; cat "$LAB/holder.state"
if grep -q '^consult_delivered=audit$' "$FM_STATE_OVERRIDE/w9.meta"; then
  echo "RESULT: PASS - delivery landed after the lock was released"
else
  echo "RESULT: FAIL - delivery did not land"
fi
