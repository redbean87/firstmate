#!/usr/bin/env bash
# Focused regression + target transcript for the watcher-churn change.
# Runs each new regression against (a) the target commit and (b) the commit
# before its fix, so a reviewer can see the test fails before the fix and
# passes after. Every checkout is reverted at the end.
set -u
WT=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M532VV7BBDZ45H7H4RA9M0AX
BASE=138ec6095f5b8ce57563e2ab6fd0ee9f50a4acaa
MID=35d11735931ac1141987278b8b9a80bf20a4b294
cd "$WT" || exit 1
restore() { git checkout HEAD -- bin/fm-watch.sh .pi/extensions/fm-primary-pi-watch.ts tests/fm-pi-watch-extension.test.sh tests/fm-watch-triage.test.sh; }
trap restore EXIT

echo "### TARGET: new watcher declared-wait throttle regression"
FM_TEST_ONLY=test_declared_wait_throttle_survives_a_busy_reading bash tests/fm-watch-triage.test.sh
echo "target-exit=$?"

echo
echo "### TARGET: reused-successor ledger link"
FM_TEST_ONLY=test_pi_reused_live_successor_links_the_cycle_ledger bash tests/fm-pi-watch-extension.test.sh
echo "target-exit=$?"

echo
echo "### TARGET: concurrent reuse contention"
FM_TEST_ONLY=test_concurrent_reuse_records_produce_one_ledger_row bash tests/fm-pi-watch-extension.test.sh
echo "target-exit=$?"

echo
echo "### BEFORE FIX (watcher @ ${BASE:0:8}): same throttle regression must fail"
git checkout "$BASE" -- bin/fm-watch.sh
FM_TEST_ONLY=test_declared_wait_throttle_survives_a_busy_reading bash tests/fm-watch-triage.test.sh
echo "base-exit=$?"
git checkout HEAD -- bin/fm-watch.sh

echo
echo "### BEFORE FIX (extension @ ${BASE:0:8}): reuse-link regression must fail"
git checkout "$BASE" -- .pi/extensions/fm-primary-pi-watch.ts
FM_TEST_ONLY=test_pi_reused_live_successor_links_the_cycle_ledger bash tests/fm-pi-watch-extension.test.sh
echo "base-exit=$?"
git checkout HEAD -- .pi/extensions/fm-primary-pi-watch.ts

echo
echo "### PRE-REVIEW-FIX (extension @ ${MID:0:8}): reuse-link must name the stale first watcher, not 777001"
git checkout "$MID" -- .pi/extensions/fm-primary-pi-watch.ts
FM_TEST_ONLY=test_pi_reused_live_successor_links_the_cycle_ledger bash tests/fm-pi-watch-extension.test.sh
echo "mid-exit=$?"
git checkout HEAD -- .pi/extensions/fm-primary-pi-watch.ts

echo
echo "### ANTI-VACUITY: disable the in-lock duplicate check, contention must produce two rows"
perl -0pi -e 's/target=\\"arm_pid=\$FM_CYCLE_REUSE_PREDECESSOR\\"/target=\\"arm_pid=NEVERMATCH\\"/' .pi/extensions/fm-primary-pi-watch.ts
FM_TEST_ONLY=test_concurrent_reuse_records_produce_one_ledger_row bash tests/fm-pi-watch-extension.test.sh
echo "no-dedupe-exit=$?"
git checkout HEAD -- .pi/extensions/fm-primary-pi-watch.ts
echo
echo "restored-clean-check:"
git status --short
