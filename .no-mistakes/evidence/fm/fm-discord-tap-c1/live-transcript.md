# Live validation transcript: fm/fm-discord-tap-c1 (outbound Discord tap)
Product driven directly: `bin/fm-discord-notify.sh` + `bin/fm-discord-send.sh`
against a disposable FM_HOME with a fake `curl` standing in for the Discord
HTTPS API (records channel POST payloads, returns controlled status codes).
`tests/fm-discord.test.sh` (section 12) passes: `ok - outbound tap ...`.
Adversarial routine lines stayed silent (0 posts): "emergency restart",
"heartbeat done polling", "failover check passed", "retrying poll loop".
Positive wake lines each sent: "task failed checks" (blocker),
"review ready for PR" (completion), "needs-decision: pick shape" (decision).
Recorded payload: `{"content":"<@u9> Work update","allowed_mentions":{"users":["u9"]}}`
=> owner mention parses, phone pings (review-1 fix verified).
Repeat event key: silent rc=0, no resend (dedup). 403 send: non-zero exit,
marker released, retry delivered. 300-char key: rc=1 with diagnostic
(review-3 fix verified, not silent 0). Loaded-secret + token-shape redaction
verified in payload. No-token / no-channel: silent rc=0. stdin --wake works.
