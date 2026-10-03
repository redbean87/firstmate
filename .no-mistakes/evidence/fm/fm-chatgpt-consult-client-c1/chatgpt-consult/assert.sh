#!/usr/bin/env bash
# Assertions over the requests the real fm-chatgpt-consult.sh actually POSTed
# to the disposable capture bridge. Reads only captured artifacts + transcripts.
set -u
EVID=/Users/cortezashley/.no-mistakes/evidence/01M42004ZXA7X6FB4G6MBNBH0H/chatgpt-consult
C="$EVID/captured"
OUT="$EVID/assertions.txt"
: > "$OUT"
fails=0
ok()  { printf 'PASS: %s\n' "$*" | tee -a "$OUT"; }
bad() { printf 'FAIL: %s\n' "$*" | tee -a "$OUT"; fails=$((fails+1)); }
chk() { if [ "$1" = 0 ]; then shift; ok "$@"; else shift; bad "$@"; fi; }

meta() { jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .'"$1" "$2"; }

# S1 audit
jq -e '.instructions | contains("code-review auditor") and contains("audit findings")' \
  "$C/audit_ok.request.json" >/dev/null; chk $? "audit request carries auditor/audit-findings instructions"
jq -e '.input[0].content | contains("login handler")' "$C/audit_ok.request.json" >/dev/null
chk $? "audit request carries the prompt file text"
[ "$(cat "$C/audit_ok.stdout")" = "STUB-CONSULTATION-ANSWER: 1. auth gaps found in login handler" ]
chk $? "audit stdout is exactly the bridge's response text"
[ ! -s "$C/audit_ok.stderr" ]; chk $? "audit success writes nothing to stderr"

# S2 plan
jq -e '.instructions | contains("execution plan") and contains("junior worker")' \
  "$C/plan_ok.request.json" >/dev/null; chk $? "plan request carries planner/execution-plan instructions"
jq -e '.input[0].content | contains("login handler")' "$C/plan_ok.request.json" >/dev/null
chk $? "plan request carries the prompt file text"

# S3 metadata stamping + model slug
jq -e '.model == "chatgpt-web/gpt-5.6-luna"' "$C/audit_ok.request.json" >/dev/null
chk $? "request rides the qualified Luna slug chatgpt-web/gpt-5.6-luna"
[ "$(meta thread_id "$C/audit_ok.request.json")" = "thread-evidence-1" ]
chk $? "turn metadata carries the supplied thread id"
echo "$(meta turn_id "$C/audit_ok.request.json")" | grep -Eq '^turn_[0-9a-f]{32}$'
chk $? "turn metadata carries a well-formed deterministic turn id"
echo "$(jq -r '.input[0].id' "$C/audit_ok.request.json")" | grep -Eq '^msg_[0-9a-f]{32}$'
chk $? "input message carries a well-formed stable item id"
[ "$(jq -r '.input[0].type' "$C/audit_ok.request.json")" = "message" ]
chk $? "role-only input item gains type=message"
[ "$(meta sandbox "$C/audit_ok.request.json")" = "dangerFullAccess" ]
chk $? "metadata carries sandbox dangerFullAccess"
cw=$(meta cwd "$C/audit_ok.request.json")
ws=$(jq -c '.client_metadata["x-codex-turn-metadata"] | fromjson | .workspace_roots' "$C/audit_ok.request.json")
[ -n "$cw" ] && [ "$ws" = "[\"$cw\"]" ]
chk $? "metadata workspace_roots is exactly [cwd] ($cw)"

# S4 turn-id determinism
ta=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .turn_id' "$C/det_a.request.json")
tb=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .turn_id' "$C/det_b.request.json")
tc=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .turn_id' "$C/det_c.request.json")
[ "$ta" = "$tb" ]; chk $? "identical prompt+mode stamps an identical turn id ($ta)"
[ "$ta" != "$tc" ]; chk $? "different prompt content stamps a different turn id"
tha=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .thread_id' "$C/det_a.request.json")
thb=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .thread_id' "$C/det_b.request.json")
[ "$tha" = "thread-det-a" ] && [ "$thb" = "thread-det-b" ]
chk $? "each call stamps its own thread id even for identical content"

# S5 same-thread turns are self-contained (documented continuity contract)
t1=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .thread_id' "$C/cont_1.request.json")
t2=$(jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | .thread_id' "$C/cont_2.request.json")
[ "$t1" = "thread-cont-9" ] && [ "$t2" = "thread-cont-9" ]
chk $? "both rounds propagate the same supplied thread id"
n=$(jq '[.. | objects | select(has("previous_response_id"))] | length' "$C/cont_2.request.json")
[ "$n" = 0 ]; chk $? "round 2 sends no previous_response_id anywhere in the request"
jq -e '(.input | length) == 1 and (.input[0].content | contains("rate limiting")) and
       ((.input[0].content | contains("auth gaps")) | not)' "$C/cont_2.request.json" >/dev/null
chk $? "round 2 input contains only its own prompt (no replayed round-1 history)"

# S6-S9 fail-closed surface
[ ! -s "$C/unreachable.stdout" ] && [ "$(cat "$C/unreachable.stderr" 2>/dev/null | grep -c bridge)" -ge 1 ]
chk $? "unreachable bridge: empty stdout, bridge prerequisite on stderr"
grep -q 'HTTP 500' "$C/http500.stderr" && [ ! -s "$C/http500.stdout" ]
chk $? "bridge HTTP 500: empty stdout, status reported on stderr"
grep -q 'no response text' "$C/empty_body.stderr" && [ ! -s "$C/empty_body.stdout" ]
chk $? "bridge 200-without-text: empty stdout, diagnostic on stderr"
grep -q 'refusing non-loopback' "$C/nonloopback.stderr" && [ ! -s "$C/nonloopback.stdout" ]
chk $? "non-loopback override refused before any request"
grep -q 'turn-identity id' "$C/missing_thread.stderr"
chk $? "missing --thread error says turn-identity id (fixed wording)"
grep -q 'audit or plan' "$C/bad_mode.stderr"
chk $? "invalid mode fails closed naming allowed modes"

printf '\n%s\n' "TOTAL FAILURES: $fails" | tee -a "$OUT"
exit "$fails"
