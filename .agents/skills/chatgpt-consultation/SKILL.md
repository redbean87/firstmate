---
name: chatgpt-consultation
description: >-
  Agent-only procedure for the ChatGPT consultation channel's availability and the intake report rule.
  Load before running or planning a ChatGPT audit or plan consultation through bin/fm-chatgpt-loop.sh or bin/fm-chatgpt-consult.sh, at task intake when the preferred flow for the task is this consultation channel, and when a CHATGPT_BRIDGE diagnostic line reports the channel's health.
user-invocable: false
metadata:
  internal: true
---

# chatgpt-consultation

[`docs/configuration.md`](../../../docs/configuration.md) "ChatGPT consultation channel" owns the user-facing contract; [`bin/fm-chatgpt-bridge-lib.sh`](../../../bin/fm-chatgpt-bridge-lib.sh) owns the mechanics, including the bounded health probe.
This skill owns the agent procedure: when to check the channel, what each probe verdict means for the work, and the rule that an unavailable channel is reported instead of routed around.

## Health check

The session-start diagnostics run the same probe in the deferred network phase, so the newest `CHATGPT_BRIDGE:` startup line (or its absence) is the current startup reading; rerun the probe directly whenever a consult is imminent and no fresh reading exists.

```sh
bash -c '. bin/fm-chatgpt-bridge-lib.sh && fm_chatgpt_bridge_health'
```

The probe is loopback-only, resolves the same URL every consultation uses, bounds itself with `FM_CHATGPT_HEALTH_PROBE_TIMEOUT` (default 30s), and exits 0 for the two quiet verdicts, 1 for the three actionable ones, and 2 when curl or jq is missing.
It only observes: installation, authentication, and repair of the bridge stay outside it.

- `healthy` - a bounded test turn completed; the channel can run.
- `unconfigured` - nothing is listening and this home has no consultation-channel configuration; quiet by contract, and a consult attempted anyway still fails closed with its prerequisite report.
- `unreachable` - nothing is listening although this home configures the channel (a `CHATGPT_WEB_BRIDGE_URL` override or consult-loop state under `data/`); the preferred flow cannot run.
- `unhealthy` - a bridge is listening but the bounded test turn failed, so the channel is present yet broken until the failure reason is disproven.
- `misconfigured` - the resolved URL was refused (a non-loopback `CHATGPT_WEB_BRIDGE_URL` override), so no consultation can reach the channel until the override is corrected.

## Intake report rule

When the preferred flow for a task is this consultation channel - the captain asked for the consultation loop, or the plan for the task runs audit or plan consults - read the channel's health at intake, before dispatching.
When the probe reports `unreachable`, `unhealthy`, or `misconfigured`, the preferred flow cannot run, so report that to the captain as an actionable item before continuing: what is wrong in plain words, and the ways forward - bring up the already-installed bridge (the loop's `bridge start` operates only an already-installed daemon; installation and authentication stay external) or proceed without consultations and say so.
Never continue as if nothing was missing: quietly substituting ordinary dispatch for the unavailable preferred flow is the trust break this rule exists to prevent.

## Startup diagnostic

A `CHATGPT_BRIDGE: unreachable ...`, `CHATGPT_BRIDGE: unhealthy ...`, or `CHATGPT_BRIDGE: misconfigured ...` line in the session-start digest or startup network report is this channel's health failing; `bootstrap-diagnostics` owns loading on that prefix, and the channel-specific response - the captain-facing report and options in this skill - is what it hands off to.
A startup report without that line means the bridge answered a bounded test turn or this home never configured the channel; both stay silent by contract, and a missing line is never a claim that a configured channel is healthy.
