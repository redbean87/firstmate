#!/usr/bin/env bash
# Evidence-only live capture driver for the reused-successor ledger link.
# Run from the run worktree:  bash <this-file>
# It uses the test file's own FM_TEST_ONLY focused-run seam to execute the real
# Pi watch extension (real module, real bash ledger writer, real ledger lock),
# then prints the cycle-ledger file the extension wrote before the suite's EXIT
# cleanup removes it.
set -u
capture_reuse_ledger() {
  test_pi_reused_live_successor_links_the_cycle_ledger
  local cycle="$TMP_ROOT/pi-reuse-link-home/state/.watch-cycle-exits.log"
  echo "=== RAW CYCLE LEDGER ($cycle) ==="
  cat "$cycle"
  echo "=== END RAW CYCLE LEDGER ==="
}
FM_TEST_ONLY=capture_reuse_ledger
. tests/fm-pi-watch-extension.test.sh
