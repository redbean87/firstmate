#!/usr/bin/env bash
# Behavior tests for response-text extraction (fm_chatgpt_response_text in
# fork/chatgpt/fm-chatgpt-bridge-lib.sh) against responses shaped like the
# codex-chatgpt-web bridge's real output, where the bridge's own
# "Local tools unavailable" notice arrives as a separate message item with
# phase "commentary" ahead of the final answer.
#
# The function is driven through its own interface and through the consult
# client against a stub bridge on a private loopback port; no live bridge,
# ChatGPT, or network is used.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=fork/chatgpt/fm-chatgpt-bridge-lib.sh
. "$ROOT/fork/chatgpt/fm-chatgpt-bridge-lib.sh"

CONSULT="$ROOT/fork/chatgpt/fm-chatgpt-consult.sh"
VALIDATE="$ROOT/fork/chatgpt/fm-chatgpt-plan-validate.sh"
TMP_ROOT=$(fm_test_tmproot fm-chatgpt-response)
STUB_PORT=17923
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$STUB_PORT/v1"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"

# shellcheck disable=SC2016 # literal markdown backticks, not expansions
BANNER='> **Local tools unavailable**
>
> `ChatGPT Web Luna` cannot access the local Codex computer in this turn.
>
> **Action:** Open `MCP` in `Codex Web GPT` and connect the `Full` harness to give the selected ChatGPT Web model access to local tools.'

# A final answer that is a valid version-1 plan citing A1.
# shellcheck disable=SC2016 # literal markdown fences, not expansions
ANSWER=$(printf '```json\n%s\n```' '{"v":1,"summary":"s","assumptions":[],"out_of_scope":[],"tasks":[{"id":"T1","title":"t","basis":["A1"],"depends_on":[],"steps":["s"],"acceptance_criteria":["a"],"verification":[{"command":"bash tests/x.test.sh","expect":"exit 0"}]}],"stop_conditions":["x"]}')

# bridge_response <file>: the two-item output the bridge emits - the banner
# as a commentary message, then the answer as a final_answer message.
bridge_response() {
  jq -n --arg banner "$BANNER" --arg answer "$ANSWER" '{output: [
    {type: "message", id: "msg_1", status: "completed", role: "assistant", phase: "commentary",
     content: [{type: "output_text", text: $banner, annotations: []}]},
    {type: "message", id: "msg_2", status: "completed", role: "assistant", phase: "final_answer",
     content: [{type: "output_text", text: $answer, annotations: []}]}
  ]}' > "$1"
}

test_commentary_item_is_excluded_and_final_answer_kept() {
  local f="$TMP_ROOT/two-item.json" out
  bridge_response "$f"
  out=$(fm_chatgpt_response_text "$f")
  [ "$out" = "$ANSWER" ] || fail "the extracted text must be exactly the final answer, got: $out"
  assert_not_contains "$out" "Local tools unavailable" "the bridge's commentary banner must be excluded"
  pass "a bridge-shaped commentary item is excluded and the final-answer item is kept byte for byte"
}

test_other_message_items_keep_existing_behavior() {
  local f="$TMP_ROOT/mixed.json" out
  jq -n '{output: [
    {type: "message", role: "assistant", content: [{type: "output_text", text: "no phase"}]},
    {type: "message", role: "assistant", phase: "commentary", content: [{type: "output_text", text: "notice"}]},
    {type: "reasoning", summary: [{type: "summary_text", text: "thinking"}]},
    {type: "message", role: "assistant", phase: "final_answer", content: [{type: "text", text: "final"}, {type: "refusal", refusal: "r"}]}
  ]}' > "$f"
  out=$(fm_chatgpt_response_text "$f")
  [ "$out" = "$(printf 'no phase\nfinal')" ] || fail "items without a phase and final-answer items must be kept in order, and only text parts read, got: $out"
  jq -n '{output: [{type: "message", phase: "commentary", content: [{type: "output_text", text: "only a notice"}]}]}' > "$f"
  out=$(fm_chatgpt_response_text "$f")
  [ -z "$out" ] || fail "a response carrying only commentary must yield no answer text, got: $out"
  jq -n '{}' > "$f"
  out=$(fm_chatgpt_response_text "$f")
  [ -z "$out" ] || fail "a response with no output must yield no answer text"
  pass "unphased and final-answer items are kept in order, only text parts are read, and commentary alone is no answer"
}

test_consult_client_returns_only_the_final_answer() {
  local dir="$TMP_ROOT/consult" pid out rc
  mkdir -p "$dir"
  bridge_response "$dir/response.json"
  cat > "$dir/stub.py" <<PY
import http.server
body = open("$dir/response.json", "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $STUB_PORT), H).serve_forever()
PY
  python3 "$dir/stub.py" >"$dir/stub.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    curl -s -m 1 -X POST "$CHATGPT_WEB_BRIDGE_URL" -d '{}' >/dev/null 2>&1 && break
    sleep 0.1
  done
  printf 'Plan the fix.\n' > "$dir/prompt.txt"
  out=$(bash "$CONSULT" --prompt-file "$dir/prompt.txt" --mode plan --thread t-response 2>"$dir/stderr.txt"); rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "a plan consult against the two-item stub must succeed ($(cat "$dir/stderr.txt"))"
  [ "$out" = "$ANSWER" ] || fail "the consult client must print only the final answer, got: $out"
  printf '%s\n' "$out" > "$dir/reply.txt"
  printf 'A1. a finding\n' > "$dir/findings.txt"
  bash "$VALIDATE" --reply-file "$dir/reply.txt" --findings-file "$dir/findings.txt" >/dev/null 2>&1 \
    || fail "the commentary-free reply must pass the unchanged plan validator"
  pass "the consult client returns only the final answer from a bridge-shaped reply, which the unchanged validator accepts"
}

fork_run_tests
