#!/usr/bin/env bash
set -eu
LAB="$1"; WT="$2"; EV="$3"; PORT="$4"
export FM_HOME="$LAB/home"
export FM_DATA_OVERRIDE="$LAB/home/data"
export FM_STATE_OVERRIDE="$LAB/home/state"
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$PORT/v1"
CONSULT="$WT/bin/fm-chatgpt-consult.sh"
LOOP="$WT/bin/fm-chatgpt-loop.sh"
mkdir -p "$FM_HOME/config" "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE"
MODE="$LAB/mode"
SLOG="$LAB/stub.log"
python3 "$LAB/stub.py" "$PORT" "$MODE" "$SLOG" >"$LAB/stub.out" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 50); do
  curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/v1" 2>/dev/null && break
  sleep 0.1
done
cleanup() { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }
trap cleanup EXIT

printf 'Review the login handler for auth gaps.\n' > "$LAB/prompt.txt"
printf 'The login handler must reject unsigned tokens.\n' > "$LAB/objective.txt"
printf -- '- gap: no signature check\n' > "$LAB/findings.md"
hr() { printf '\n===== %s =====\n' "$1"; }

# ---- Consult-level scenarios -------------------------------------------
for m in ok reject200 reject_nosize error_no_message http500 garbage; do
  printf '%s' "$m" > "$MODE"
  hr "consult --mode plan against bridge mode '$m'"
  out="$LAB/out.$m"; err="$LAB/err.$m"
  rc=0
  bash "$CONSULT" --prompt-file "$LAB/prompt.txt" --mode plan --thread t-$m >"$out" 2>"$err" || rc=$?
  echo "exit=$rc"
  echo "stdout=[$(cat "$out")]"
  echo "stderr=[$(cat "$err")]"
  case "$m" in
    ok) [ "$rc" -eq 0 ] ;;
    *)  [ "$rc" -ne 0 ] ;;
  esac
done
# precise consult-level assertions
grep -q 'bridge rejected the request (context_length_exceeded): This request exceeds the browser transport budget (102400 tokens).' "$LAB/err.reject200"
grep -q 'bridge refused this turn outright' "$LAB/err.reject_nosize"
! grep -qE '[0-9]' "$LAB/err.reject_nosize"
grep -q 'bridge returned no response text (HTTP 200)' "$LAB/err.error_no_message"
! grep -q 'rejected' "$LAB/err.error_no_message"
grep -q 'HTTP 500' "$LAB/err.http500"
echo "CONSULT-ASSERTS-OK"

# ---- Loop-level scenarios ----------------------------------------------
hr "loop: audit consult rejected (HTTP 200 structured rejection)"
t=auditrej
bash "$LOOP" init --task $t --objective-file "$LAB/objective.txt" >/dev/null 2>&1
printf 'reject200' > "$MODE"
rc=0; out=$(bash "$LOOP" consult --stage audit --task $t 2>&1) || rc=$?
echo "exit=$rc"; echo "output=[$out]"
st="$FM_DATA_OVERRIDE/$t/chatgpt-loop.json"
echo "phase=$(jq -r .phase "$st")"
echo "audit_prompt=[$(jq -r .audit_prompt "$st")]"
echo "audit_result=[$(jq -r .audit_result "$st")]"
echo "last_error=[$(jq -r .last_error "$st")]"
[ "$rc" -ne 0 ]
python3 - "$st" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["phase"]=="audit-consult", s["phase"]
assert s["audit_prompt"]=="" and s["audit_result"]==""
assert "context_length_exceeded" in s["last_error"]
assert "102400 tokens" in s["last_error"]
print("ASSERT_OK audit rejection: phase held, nothing stored, bridge diagnostic in last_error")
PY

hr "loop: plan consult rejected (HTTP 200 structured rejection)"
t=planrej
bash "$LOOP" init --task $t --objective-file "$LAB/objective.txt" >/dev/null 2>&1
printf 'reject200' > "$MODE"
cp "$LAB/findings.md" "$FM_DATA_OVERRIDE/$t/findings.md"
rc=0; out=$(bash "$LOOP" consult --stage plan --task $t --findings-file "$FM_DATA_OVERRIDE/$t/findings.md" 2>&1) || rc=$?
echo "exit=$rc"; echo "output=[$out]"
st="$FM_DATA_OVERRIDE/$t/chatgpt-loop.json"
echo "phase=$(jq -r .phase "$st")"
echo "plan=[$(jq -r .plan "$st")]"
echo "last_error=[$(jq -r .last_error "$st")]"
[ "$rc" -ne 0 ]
python3 - "$st" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["phase"]=="audit-consult", s["phase"]
assert s["plan"]==""
assert "context_length_exceeded" in s["last_error"]
assert "102400 tokens" in s["last_error"]
print("ASSERT_OK plan rejection: phase held, no plan stored, bridge diagnostic in last_error")
PY

hr "loop: rejection without a reported size invents no number"
t=nosize
bash "$LOOP" init --task $t --objective-file "$LAB/objective.txt" >/dev/null 2>&1
printf 'reject_nosize' > "$MODE"
rc=0; out=$(bash "$LOOP" consult --stage audit --task $t 2>&1) || rc=$?
echo "exit=$rc"; echo "output=[$out]"
st="$FM_DATA_OVERRIDE/$t/chatgpt-loop.json"
le=$(jq -r .last_error "$st")
echo "last_error=[$le]"
[ "$rc" -ne 0 ]
python3 - "$le" <<'PY'
import sys,re
le=sys.argv[1]
assert "bridge refused this turn outright" in le, le
assert not re.search(r"[0-9]", le), ("invented a number: "+le)
print("ASSERT_OK no-size rejection: message relayed verbatim, no number invented")
PY

hr "loop: successful audit consult is unaffected (no false rejection)"
t=oka
bash "$LOOP" init --task $t --objective-file "$LAB/objective.txt" >/dev/null 2>&1
printf 'ok' > "$MODE"
rc=0; out=$(bash "$LOOP" consult --stage audit --task $t 2>&1) || rc=$?
st="$FM_DATA_OVERRIDE/$t/chatgpt-loop.json"
echo "exit=$rc phase=$(jq -r .phase "$st")"
echo "audit_prompt=[$(jq -r .audit_prompt "$st")]"
[ "$rc" -eq 0 ]
python3 - "$st" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["phase"]=="audit-dispatch", s["phase"]
assert s["audit_prompt"]=="STUB ANSWER: proceed with the plan", s["audit_prompt"]
assert s["last_error"]==""
print("ASSERT_OK successful audit: answer stored, phase advanced, no rejection")
PY

hr "loop: successful plan consult is unaffected (no false rejection)"
t=okp
bash "$LOOP" init --task $t --objective-file "$LAB/objective.txt" >/dev/null 2>&1
cp "$LAB/findings.md" "$FM_DATA_OVERRIDE/$t/findings.md"
printf 'ok' > "$MODE"
rc=0; out=$(bash "$LOOP" consult --stage plan --task $t --findings-file "$FM_DATA_OVERRIDE/$t/findings.md" 2>&1) || rc=$?
st="$FM_DATA_OVERRIDE/$t/chatgpt-loop.json"
echo "exit=$rc phase=$(jq -r .phase "$st")"
echo "plan=[$(jq -r .plan "$st")]"
[ "$rc" -eq 0 ]
python3 - "$st" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s["phase"]=="plan-dispatch", s["phase"]
assert s["plan"]=="STUB ANSWER: proceed with the plan", s["plan"]
assert s["last_error"]==""
print("ASSERT_OK successful plan: answer stored, phase advanced, no rejection")
PY

echo ""
echo "ALL LIVE SCENARIO ASSERTIONS PASSED"
