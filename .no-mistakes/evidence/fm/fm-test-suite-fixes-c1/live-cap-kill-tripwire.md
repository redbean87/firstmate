# LIVE cap-kill tripwire evidence (2026-10-10T17:14:58Z)

## Real runner cut-off shard log (job-cap kill simulated)
```
FM_TEST_BEGIN 2026-10-10T17:14:50Z tests/fm-wedge-fixture.test.sh family=unclassified expected_gate_skip=none weight_ms=45000
ok - wedge fixture started, about to hang
Exception ignored while flushing sys.stdout:
BrokenPipeError: [Errno 32] Broken pipe
```

## Real tripwire output (exit 0)
```
### Shard cut off before its summary

This shard log ended without `FM_TEST_SUMMARY`: it was cut off mid-run, so no test verdict was recorded for it. A cancelled check here is this tripwire firing, not a flaky test.

- Running script: `tests/fm-wedge-fixture.test.sh` (family=unclassified)
- Last `FM_TEST_BEGIN`: `FM_TEST_BEGIN 2026-10-10T17:14:50Z tests/fm-wedge-fixture.test.sh family=unclassified expected_gate_skip=none weight_ms=45000`
- Modeled runtime: 45000 ms; actual runtime at cutoff: 8 s
::warning::shard cut off mid-script: tests/fm-wedge-fixture.test.sh was running (modeled 45000 ms, actual 8 s at cutoff)
```

## GITHUB_STEP_SUMMARY
```markdown
### Shard cut off before its summary

This shard log ended without `FM_TEST_SUMMARY`: it was cut off mid-run, so no test verdict was recorded for it. A cancelled check here is this tripwire firing, not a flaky test.

- Running script: `tests/fm-wedge-fixture.test.sh` (family=unclassified)
- Last `FM_TEST_BEGIN`: `FM_TEST_BEGIN 2026-10-10T17:14:50Z tests/fm-wedge-fixture.test.sh family=unclassified expected_gate_skip=none weight_ms=45000`
- Modeled runtime: 45000 ms; actual runtime at cutoff: 8 s
```
