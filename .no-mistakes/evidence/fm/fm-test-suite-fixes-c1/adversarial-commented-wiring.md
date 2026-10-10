# Adversarial: commented-out CI wiring must fail the strengthened contract test

The review fix requires that a commented-out flag/program cannot satisfy the serial-shard contract.
For each mutation below, the base-commit (old) test accepted it; the target-commit (new) test rejects it.

## A: --per-script-timeout-secs commented out

### target-commit test (rc=1) - expected FAIL
```
ok - fast tier jobs share one 5 minute tripwire
ok - Herdr keeps a 20 minute step tripwire under a 75 minute job backstop
-:32:in `<main>': serial shard step has no --per-script-timeout-secs (RuntimeError)
not ok - serial shard bound/tripwire contract
```
### base-commit test (rc=0) - old false negative
```
ok - heavy lanes gate on the change-scope signals and fail closed
```

## B: real tee pipe removed, only a # tee comment remains

### target-commit test (rc=1) - expected FAIL
```
ok - fast tier jobs share one 5 minute tripwire
ok - Herdr keeps a 20 minute step tripwire under a 75 minute job backstop
-:41:in `<main>': serial shard step must pipe its log into tee for the tripwire (RuntimeError)
not ok - serial shard bound/tripwire contract
```
### base-commit test (rc=0) - old false negative
```
ok - heavy lanes gate on the change-scope signals and fail closed
```

## C: tripwire program only appears in a comment

### target-commit test (rc=1) - expected FAIL
```
ok - fast tier jobs share one 5 minute tripwire
ok - Herdr keeps a 20 minute step tripwire under a 75 minute job backstop
-:47:in `<main>': tripwire must call bin/fm-test-shard-tripwire.sh (RuntimeError)
not ok - serial shard bound/tripwire contract
```
### base-commit test (rc=0) - old false negative
```
ok - heavy lanes gate on the change-scope signals and fail closed
```

