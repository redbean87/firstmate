#!/usr/bin/env bash
# Live driver for the ChatGPT consultation client (bin/fm-chatgpt-consult.sh).
# Stands up a disposable loopback capture server that speaks the openai-responses
# contract, drives the REAL client end-to-end for each scenario, and records
# stdout/stderr/exit plus the exact request bytes the bridge would receive.
set -u

ROOT=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M42004ZXA7X6FB4G6MBNBH0H
EVID=/Users/cortezashley/.no-mistakes/evidence/01M42004ZXA7X6FB4G6MBNBH0H/chatgpt-consult
CONSULT="$ROOT/bin/fm-chatgpt-consult.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-chatgpt-evidence.XXXXXX")
mkdir -p "$EVID/captured"
TRANScript="$EVID/transcript.txt"
: > "$TRANScript"

say() { printf '%s\n' "$*" | tee -a "$TRANScript"; }

# free port
PORT=$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)
CAPDIR="$WORK/capture"
mkdir -p "$CAPDIR"
printf 'ok' > "$CAPDIR/behavior"
cat > "$CAPDIR/server.py" <<'PY'
import http.server, json, sys, os, threading
d, port = sys.argv[1], int(sys.argv[2])
lock = threading.Lock()
count = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        with lock:
            i = count["n"]; count["n"] += 1
            open(f"{d}/req_{i:03d}.json", "wb").write(body)
        behavior = open(f"{d}/behavior").read().strip()
        if behavior == "http500":
            payload = json.dumps({"error": {"message": "bridge exploded"}}).encode()
            status = 500
        elif behavior == "empty":
            payload = json.dumps({"output": []}).encode()
            status = 200
        else:
            payload = json.dumps({
                "id": "resp_stub_001",
                "output": [
                    {"type": "reasoning", "summary": []},
                    {"type": "message", "role": "assistant", "status": "completed",
                     "content": [{"type": "output_text",
                                  "text": "STUB-CONSULTATION-ANSWER: 1. auth gaps found in login handler"}]}
                ],
                "usage": {"input_tokens": 10, "output_tokens": 10}
            }).encode()
            status = 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 "$CAPDIR/server.py" "$CAPDIR" "$PORT" >"$CAPDIR/server.log" 2>&1 &
SRV=$!
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$PORT/v1"
for _ in $(seq 1 50); do
  curl -s -m 1 -X POST "$CHATGPT_WEB_BRIDGE_URL/responses" -d '{}' >/dev/null 2>&1 && break
  sleep 0.1
done
# drop the warmup probe request so counts start clean
rm -f "$CAPDIR"/req_*.json

cleanup() { kill "$SRV" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

run() { # run <label> <expected-behavior> -- args...
  local label=$1 behavior=$2; shift 2
  printf 'ok' > "$CAPDIR/behavior"
  [ "$behavior" = default ] || printf '%s' "$behavior" > "$CAPDIR/behavior"
  local out="$WORK/$label.out" err="$WORK/$label.err"
  bash "$CONSULT" "$@" >"$out" 2>"$err"; local rc=$?
  local n; n=$(ls "$CAPDIR"/req_*.json 2>/dev/null | wc -l | tr -d ' ')
  local last; last=$(ls -t "$CAPDIR"/req_*.json 2>/dev/null | head -1)
  [ -n "$last" ] && cp "$last" "$EVID/captured/$label.request.json"
  cp "$out" "$EVID/captured/$label.stdout"; cp "$err" "$EVID/captured/$label.stderr"
  say "== $label: rc=$rc requests_seen=$n"
  say "-- stdout: $(cat "$out" | head -3)"
  say "-- stderr: $(cat "$err" | head -3)"
}

printf 'Review the login handler for auth gaps.\n' > "$WORK/prompt.txt"
printf 'Add rate limiting to the login endpoint.\n' > "$WORK/prompt2.txt"

say "=== S1 audit consultation (disposable bridge on 127.0.0.1:$PORT) ==="
run audit_ok default --prompt-file "$WORK/prompt.txt" --mode audit --thread thread-evidence-1

say "=== S2 plan consultation ==="
run plan_ok default --prompt-file "$WORK/prompt.txt" --mode plan --thread thread-evidence-2

say "=== S4/S5 turn-id determinism: same content twice, then different content ==="
run det_a default --prompt-file "$WORK/prompt.txt" --mode audit --thread thread-det-a
run det_b default --prompt-file "$WORK/prompt.txt" --mode audit --thread thread-det-b
run det_c default --prompt-file "$WORK/prompt2.txt" --mode audit --thread thread-det-c

say "=== S5 continuity: two self-contained turns on the SAME thread ==="
run cont_1 default --prompt-file "$WORK/prompt.txt" --mode audit --thread thread-cont-9
run cont_2 default --prompt-file "$WORK/prompt2.txt" --mode plan --thread thread-cont-9

say "=== S6 bridge unreachable ==="
CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" bash "$CONSULT" \
  --prompt-file "$WORK/prompt.txt" --mode audit --thread t-down >"$WORK/down.out" 2>"$WORK/down.err"; rc=$?
cp "$WORK/down.out" "$EVID/captured/unreachable.stdout"; cp "$WORK/down.err" "$EVID/captured/unreachable.stderr"
say "== unreachable: rc=$rc stdout_bytes=$(wc -c <"$WORK/down.out" | tr -d ' ') stderr=$(head -2 "$WORK/down.err")"

say "=== S7 bridge HTTP 500 ==="
run http500 http500 --prompt-file "$WORK/prompt.txt" --mode audit --thread t-500

say "=== S8 bridge 200 but no response text ==="
run empty_body empty --prompt-file "$WORK/prompt.txt" --mode audit --thread t-empty

say "=== S9 non-loopback bridge override refused ==="
CHATGPT_WEB_BRIDGE_URL="http://10.255.255.1:9/v1" bash "$CONSULT" \
  --prompt-file "$WORK/prompt.txt" --mode audit --thread t-nonlb >"$WORK/nonlb.out" 2>"$WORK/nonlb.err" &
pid=$!
sleep 8
if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; rc=124; else wait "$pid"; rc=$?; fi
cp "$WORK/nonlb.out" "$EVID/captured/nonloopback.stdout"; cp "$WORK/nonlb.err" "$EVID/captured/nonloopback.stderr"
say "== nonloopback: rc=$rc stdout_bytes=$(wc -c <"$WORK/nonlb.out" | tr -d ' ') stderr=$(head -2 "$WORK/nonlb.err")"

say "=== S10 argument validation ==="
bash "$CONSULT" --prompt-file "$WORK/prompt.txt" --mode audit >"$WORK/nothread.out" 2>"$WORK/nothread.err"; rc=$?
say "== missing --thread: rc=$rc stderr=$(head -1 "$WORK/nothread.err")"
cp "$WORK/nothread.err" "$EVID/captured/missing_thread.stderr"
bash "$CONSULT" --mode audit --thread t1 >"$WORK/nofile.out" 2>"$WORK/nofile.err"; rc=$?
say "== missing --prompt-file: rc=$rc stderr=$(head -1 "$WORK/nofile.err")"
cp "$WORK/nofile.err" "$EVID/captured/missing_prompt_file.stderr"
bash "$CONSULT" --prompt-file "$WORK/does-not-exist.txt" --mode audit --thread t1 >"$WORK/badfile.out" 2>"$WORK/badfile.err"; rc=$?
say "== nonexistent prompt file: rc=$rc stderr=$(head -1 "$WORK/badfile.err")"
bash "$CONSULT" --prompt-file "$WORK/prompt.txt" --mode explain --thread t1 >"$WORK/badmode.out" 2>"$WORK/badmode.err"; rc=$?
say "== bad mode: rc=$rc stderr=$(head -1 "$WORK/badmode.err")"
bash "$CONSULT" --prompt-file "$WORK/prompt.txt" --mode audit --thread t1 --bogus >"$WORK/unk.out" 2>"$WORK/unk.err"; rc=$?
say "== unknown arg: rc=$rc stderr=$(head -1 "$WORK/unk.err")"
cp "$WORK/badmode.err" "$EVID/captured/bad_mode.stderr"

say "=== S12 assertions over captured requests ==="
jq -c '{model, instr:(.instructions|tostring|.[0:60]), input0:.input[0], meta:(.client_metadata["x-codex-turn-metadata"]|fromjson)}' \
  "$EVID/captured/audit_ok.request.json" | tee -a "$TRANScript"
jq -c '.instructions' "$EVID/captured/plan_ok.request.json" >> "$TRANScript"

say "DONE"
