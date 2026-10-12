# Dispatch-time consultation gate verification

Audience: maintainer verification.

The gate's contract is owned by [`bin/fm-consult-gate-lib.sh`](../../bin/fm-consult-gate-lib.sh)'s header, stated for operators in [`../configuration.md`](../configuration.md) ("ChatGPT consultation channel"), and carried by the [`chatgpt-consultation`](../../.agents/skills/chatgpt-consultation/SKILL.md) skill for the agent-side procedure.
This record carries the commands and observed output that re-establish the gate on a current checkout; the captain's ask and the task chronology stay in the private task report.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-10-12 |
| Platform | macOS arm64; shellcheck 0.11.0; tasks-axi 0.2.6; jq, curl, and python3 present |
| Channel | stubbed loopback bridge (`fm_test_start_bridge_stub` in `tests/fixtures.sh`); the suite spends no live ChatGPT turn |

## Guarantee

A ship or scout launch whose `data/<task-id>/chatgpt-loop.json` holds no non-empty prompt for the stage in play refuses before any endpoint, local copy, or record exists, naming the artifact path, the `bin/fm-chatgpt-loop.sh init` and `consult --stage audit|plan` commands that create it, and `--consult-waived <reason>` as the recorded exception.
An empty, whitespace-only, or multi-line waiver reason is refused, and a reason that is accepted lands in `state/<id>.meta` as `consult_waived=` and in the task's backlog note before the launch proceeds.
A channel the probe reports unavailable carries the launch under a waiver derived from the probe verdict instead of blocking it, so a down channel is never silent either.
`bin/fm-control.sh relaunch` applies the same refusal before it stops the agent it replaces, and the consultation loop's own dispatch passes through the record it already holds.

## Commands

```sh
bin/fm-test-run.sh tests/fm-consult-gate.test.sh
bin/fm-test-run.sh tests/fm-control-relaunch.test.sh tests/fm-chatgpt-loop.test.sh
bin/fm-lint.sh bin/fm-consult-gate-lib.sh bin/fm-spawn.sh bin/fm-control.sh bin/fm-chatgpt-loop.sh bin/fm-live-lab.sh tests/consult-gate-fixture.sh tests/lib.sh tests/fixtures.sh tests/fm-consult-gate.test.sh
bin/fm-doc-audience-check.sh
```

## Observed output (2026-10-12)

```console
$ bash tests/fm-consult-gate.test.sh
ok - fm-spawn: a healthy channel refuses a ship launch with no stored prompt
ok - fm-spawn: a stored prompt leaves the launch unchanged and never probes the channel
ok - fm-spawn: a waiver with an empty or whitespace-only reason is refused
ok - fm-spawn: a waiver reason is recorded in the task record and the backlog note
ok - fm-spawn: a scout launch is gated exactly like a ship
ok - fm-spawn: a verified-unavailable channel proceeds under a recorded waiver
ok - fm-spawn: a listening-but-broken channel proceeds under a recorded waiver
ok - fm-spawn: the consultation loop's own dispatch satisfies the gate
ok - fm-spawn: the loop marker alone never satisfies the gate
ok - fm-spawn: the stage in play decides which stored prompt the gate requires
# all fm-consult-gate tests passed
```

The relaunch half of the same gate, from `tests/fm-control-relaunch.test.sh`:

```console
ok - fm-control relaunch: the consultation gate refuses before the running agent is stopped
ok - fm-control relaunch: a task with a stored prompt relaunches normally
ok - fm-control relaunch: an unavailable channel proceeds with its waiver recorded
```

The refusal the healthy-channel case asserts, as it actually prints:

```console
error: task gate-healthy-c1 cannot launch without its stored ChatGPT-generated prompt
  <home>/data/gate-healthy-c1/chatgpt-loop.json
  no consultation record exists there
  consultation channel: healthy a bounded test turn completed at http://127.0.0.1:17913/v1
Create the prompt before launching:
  bin/fm-chatgpt-loop.sh init --task gate-healthy-c1 --objective-file <objective-file>
  bin/fm-chatgpt-loop.sh consult --stage audit|plan --task gate-healthy-c1
To launch anyway, pass an explicit waiver whose reason is recorded in the task record and the backlog note: --consult-waived <reason>
```

```console
$ bin/fm-lint.sh bin/fm-consult-gate-lib.sh bin/fm-spawn.sh bin/fm-control.sh bin/fm-chatgpt-loop.sh bin/fm-live-lab.sh tests/consult-gate-fixture.sh tests/lib.sh tests/fixtures.sh tests/fm-consult-gate.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=123 local_links=756
```

## Limits

Every probe verdict above is exercised through the stub, never a live bridge; [`bin/fm-chatgpt-bridge-lib.sh`](../../bin/fm-chatgpt-bridge-lib.sh) owns the live-probe evidence.
Fixture launch worlds seed a stored prompt through [`tests/consult-gate-fixture.sh`](../../tests/consult-gate-fixture.sh), so the rest of the suite is indifferent to whether a bridge answers on the machine running it.
