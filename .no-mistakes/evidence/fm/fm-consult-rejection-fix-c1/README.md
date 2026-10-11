# Live validation evidence: fm-consult-rejection-fix-c1

Change: `bin/fm-chatgpt-consult.sh` now reads the bridge's structured
`.error` payload and relays its `code` and `message` (including any token
count the bridge reports) verbatim on stderr with empty stdout, exiting
nonzero. No local sizing/prediction is added. Docs updated in
`docs/configuration.md`; regression tests added in
`tests/fm-chatgpt-consult.test.sh` and `tests/fm-chatgpt-loop.test.sh`.

## How it was driven

The real product (`bin/fm-chatgpt-consult.sh` and the real
`bin/fm-chatgpt-loop.sh` state machine) was pointed at a disposable
loopback stub bridge (`stub-bridge.py`) through the product's own
`CHATGPT_WEB_BRIDGE_URL` override, with an isolated `FM_HOME`,
`FM_DATA_OVERRIDE`, and `FM_STATE_OVERRIDE` under a throwaway temp lab.
The stub plays the bridge's documented openai-responses shapes:
a normal answer, the incident-shaped HTTP-200 transport-budget rejection,
a rejection with no reported size, an `.error` object without a message,
an HTTP 500 error, and unparseable JSON.

## Files

- `live-drive-transcript.txt` - full transcript of the live CLI drives
  (consult-level modes and loop-level reject/success scenarios with
  state-file assertions).
- `live-drive-harness.sh` / `stub-bridge.py` - the disposable driver.
- `base-regression.txt` - the new tests run against BASE commit e45fdd6
  code; they fail there ("not ok - ... bridge rejection"), proving the fix
  is what makes them pass.
- `targeted-suites.txt` - the new tests passing on the fixed worktree.

## Result

Every live scenario passed. No local size estimate was produced or
invented anywhere; the bridge's own message and count are relayed
unchanged, and a rejection without a reported size relays no number.
