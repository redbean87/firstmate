# Docs-only change: user-level extension isolation rule

## Final tracked prose added (docs/configuration.md, under '## Worker account pin')

### User-level extension isolation

Fleet behaviour must never depend on auto-discovery from the runtime's user-level extension directory (`~/.pi/agent/extensions/`), which remains a personal-customisation surface.
That directory loads for every worker whether or not the pin exists: the runtime's agent directory defaults to `~/.pi/agent` when `PI_CODING_AGENT_DIR` is unset (in the installed runtime's `dist/config.js`), and this home's `config/pi-account` pin resolves to that same directory and is exported to the launch as `PI_CODING_AGENT_DIR` ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh), [`bin/fm-worker-account-lib.sh`](../bin/fm-worker-account-lib.sh)); either fact alone is sufficient, and only an explicit exclusion or a different agent directory changes what loads.
No extension required by a worker may be supplied by that user-level directory; supply it from an explicit launch path instead, as with the tracked model-failover router and busy-state extension.
This rule is enforced by review, not by a runtime guard: the runtime's extension loader collects a bad extension's error and keeps running instead of failing the session, so no code refuses a violation.


## AGENTS.md pointer added

+++ b/AGENTS.md
+Before editing the worker account pin or worker launch behaviour, follow the user-level extension isolation rule in the worker-account-pin section of `docs/configuration.md`.

## Existing documentation-contract consumer (not live; local-link validation)

$ bash tests/fm-documentation-audiences.test.sh
ok - documentation inventory classifies every maintained prose surface exactly once
ok - classification, setup routing, and maintained-prose scope fail safely
ok - required documentation owner pointers cannot silently disappear
ok - local links resolve while dates, versions, commands, and incident prose remain semantically reviewed
