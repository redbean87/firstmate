#!/usr/bin/env bash
# Drive portable serial shards 5 and 6 exactly as CI does, one after another
# (CI gives each its own runner; locally they must not share the machine).
set -u
EV=/Users/cortezashley/.no-mistakes/evidence/01M44FJG8W65Y6ESGBP92DGCE9
cd /Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M44FJG8W65Y6ESGBP92DGCE9 || exit 1
status=0
for shard in 5 6; do
  {
    echo "=== shard $shard start $(date -u +%FT%TZ) ==="
    env -u NO_MISTAKES_GATE \
      FM_SERIAL_LANE="portable-serial-${shard}of9" \
      FM_SERIAL_SHARD="$shard" \
      bin/fm-test-run.sh --lane "portable-serial-${shard}of9" \
        --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' \
        --json "$EV/fm-test-timing-portable-serial-${shard}.json"
    rc=$?
    echo "=== shard $shard end $(date -u +%FT%TZ) exit=$rc ==="
    [ "$rc" -eq 0 ] || status=1
  } >>"$EV/serial-shard-run.log" 2>&1
done
echo "ALL_DONE status=$status" >>"$EV/serial-shard-run.log"
