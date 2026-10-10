# LIVE per-script bound evidence (2026-10-10T17:15:09Z)

Command: bin/fm-test-run.sh --per-script-timeout-secs 2 tests/fm-wedge-fixture.test.sh (wedge = sleep 600)

Exit: 1; elapsed: 2s

```
FM_TEST_BEGIN 2026-10-10T17:15:07Z tests/fm-wedge-fixture.test.sh family=unclassified expected_gate_skip=none weight_ms=45000
ok - wedge fixture started, about to hang
not ok - tests/fm-wedge-fixture.test.sh exceeded the per-script bound of 2s and was terminated
FM_TEST_END 2026-10-10T17:15:09Z tests/fm-wedge-fixture.test.sh exit=124 duration_ms=2420 gate_skip=false
FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=2504
FM_TEST_SUMMARY_FAMILY family=unclassified count=1 duration_ms=2420 failed=1
FM_TEST_SLOWEST rank=1 script=tests/fm-wedge-fixture.test.sh duration_ms=2420
fm-test-run: wrote timing artifact: /var/folders/lq/gtznj14x70d1bgnvckqy6c6m0000gn/T//fm-live.GrXcPW/timing.json
```
