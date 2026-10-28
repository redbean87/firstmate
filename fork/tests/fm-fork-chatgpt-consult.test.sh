#!/usr/bin/env bash
# Behavior tests for the ChatGPT consultation client (fork/chatgpt/fm-chatgpt-consult.sh
# and fork/chatgpt/fm-chatgpt-bridge-lib.sh).
#
# A stubbed loopback endpoint stands in for the codex-chatgpt-web bridge, so
# normal CI spends no live ChatGPT dependency. Every case drives the scripts'
# executable interface and asserts the recorded request shape, never source
# bytes. Fork CI owns the lint gate; shellcheck-cleanliness is proven
# there, not here.
set -u

# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSULT="$ROOT/fork/chatgpt/fm-chatgpt-consult.sh"
# shellcheck source=fork/chatgpt/fm-chatgpt-bridge-lib.sh
. "$ROOT/fork/chatgpt/fm-chatgpt-bridge-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chatgpt-consult)
STUB_PORT=17899
export CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:$STUB_PORT/v1"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME"

# start_stub <case-dir> [status] [kind] [routes-dir]: serves one canned
# Responses payload and records the request body at <case-dir>/request.json
# and the request headers at <case-dir>/headers.json. kind is `ok` (a
# successful turn), `error200` (HTTP 200 carrying an error payload),
# `reject200` (HTTP 200 carrying the incident-shaped transport-budget
# rejection), `garbage` (HTTP 200 carrying unparseable text),
# `fallback-route` (a successful turn whose bridge routing fell back,
# writing a fresh fallback outcome into routes-dir like the real bridge does
# mid-turn), `fallback-route-stale` (the same with a routing outcome older
# than any consult), or `project-route` (a successful turn routed into the
# project); a non-200 status serves its error payload at that status. Prints
# the server pid.
start_stub() {
  local dir=$1 status=${2:-200} kind=${3:-ok} routes=${4:-}
  cat > "$dir/stub.py" <<PY
import http.server, json, sys, time
d = "$dir"
status = $status
kind = "$kind"
routes = "$routes"
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open(d + "/request.json", "wb").write(self.rfile.read(n))
        open(d + "/headers.json", "w").write(json.dumps(
            {k.lower(): v for k, v in self.headers.items()}))
        if kind in ("fallback-route", "fallback-route-stale", "project-route"):
            name = self.headers.get("x-fm-chatgpt-project") or "stub-repo"
            at = int(time.time() * 1000)
            if kind == "fallback-route-stale":
                at -= 10 * 60 * 1000
            outcome = {"project": name, "decision": "fallback", "reason": "unmapped", "at": at}
            if kind == "project-route":
                outcome = {"project": name, "decision": "project", "at": at}
            open(routes + "/12hex0000000.outcome.json", "w").write(json.dumps(outcome))
        if kind == "garbage":
            body = b"not json"
            self.send_response(200)
        elif kind == "error200":
            body = json.dumps({"error": {"message": "stub failure"}}).encode()
            self.send_response(200)
        elif kind == "reject200":
            body = json.dumps({"error": {"code": "context_length_exceeded",
                "message": "This request exceeds the browser transport budget (102400 tokens)."}}).encode()
            self.send_response(200)
        elif kind == "empty":
            body = json.dumps({}).encode()
            self.send_response(200)
        elif status != 200:
            body = json.dumps({"error": {"message": "stub failure"}}).encode()
            self.send_response(status)
        else:
            body = json.dumps({"output": [{"type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": "stubbed consultation answer"}]}]}).encode()
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
  printf '%s' "$!"
  for _ in $(seq 1 50); do
    curl -s -m 1 -X POST "http://127.0.0.1:$STUB_PORT/v1" -d '{}' >/dev/null 2>&1 && break
    sleep 0.1
  done
}

stop_stub() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

new_prompt() {
  printf 'Review the login handler for auth gaps.\n' > "$TMP_ROOT/prompt.txt"
}

request_meta() {
  jq -r '.client_metadata["x-codex-turn-metadata"] | fromjson | "\(.thread_id) \(.turn_id)"' "$TMP_ROOT/$1/request.json"
}

# The bounded health probe (fm_chatgpt_bridge_health) is what startup
# diagnostics run to keep a configured-but-broken consultation channel from
# going silent; these cases pin its verdicts through the lib's own interface.
test_bridge_health_probe_verdicts() {
  local dir pid out rc
  dir="$TMP_ROOT/health-healthy"; mkdir -p "$dir"
  pid=$(start_stub "$dir")
  out=$(fm_chatgpt_bridge_health); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a bridge that completes a test turn must exit 0"
  assert_contains "$out" "healthy" "the probe must print the healthy verdict"
  assert_contains "$out" "http://127.0.0.1:$STUB_PORT/v1" "the healthy verdict must name the resolved URL"

  dir="$TMP_ROOT/health-http"; mkdir -p "$dir"
  pid=$(start_stub "$dir" 500)
  out=$(fm_chatgpt_bridge_health); rc=$?
  stop_stub "$pid"
  expect_code 1 "$rc" "a listening bridge whose test turn fails must exit 1"
  assert_contains "$out" "unhealthy" "a listening-but-broken bridge must print the unhealthy verdict"
  assert_contains "$out" "HTTP 500" "the unhealthy verdict must carry the failing status"

  dir="$TMP_ROOT/health-error"; mkdir -p "$dir"
  pid=$(start_stub "$dir" 200 error200)
  out=$(fm_chatgpt_bridge_health); rc=$?
  stop_stub "$pid"
  expect_code 1 "$rc" "an error payload at HTTP 200 must exit 1"
  assert_contains "$out" "unhealthy" "a bridge answering with an error must print the unhealthy verdict"
  assert_contains "$out" "stub failure" "the unhealthy verdict must carry the bridge's error message"

  dir="$TMP_ROOT/health-garbage"; mkdir -p "$dir"
  pid=$(start_stub "$dir" 200 garbage)
  out=$(fm_chatgpt_bridge_health); rc=$?
  stop_stub "$pid"
  expect_code 1 "$rc" "an unparseable test-turn response must exit 1"
  assert_contains "$out" "unhealthy" "an unparseable response must print the unhealthy verdict"
  assert_contains "$out" "unparseable" "the unhealthy verdict must say the response could not be parsed"

  dir="$TMP_ROOT/health-empty"; mkdir -p "$dir"
  pid=$(start_stub "$dir" 200 empty)
  out=$(fm_chatgpt_bridge_health); rc=$?
  stop_stub "$pid"
  expect_code 1 "$rc" "a 2xx response carrying no output text must exit 1"
  assert_contains "$out" "unhealthy" "a bridge that answers without response text must print the unhealthy verdict"
  assert_contains "$out" "no output text" "the unhealthy verdict must say the response carried no output text"

  out=$(CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" fm_chatgpt_bridge_health); rc=$?
  expect_code 1 "$rc" "a configured-but-unreachable bridge must exit 1"
  assert_contains "$out" "unreachable" "nothing listening at a configured channel must print the unreachable verdict"
  assert_contains "$out" "though this home configures" "the unreachable verdict must say the channel is configured"

  out=$(CHATGPT_WEB_BRIDGE_URL="http://example.com/v1" fm_chatgpt_bridge_health); rc=$?
  expect_code 1 "$rc" "a non-loopback bridge URL must be refused"
  assert_contains "$out" "misconfigured" "a refused non-loopback override must print the misconfigured verdict"
  assert_contains "$out" "loopback-only" "the misconfigured verdict must carry the refusal reason"
  pass "the health probe distinguishes healthy, unhealthy, unreachable, and misconfigured bridges"
}

test_bridge_health_unconfigured_stays_quiet() {
  local out rc home
  # Nothing listening AND no configuration evidence is the quiet verdict. The
  # reachability probe goes to the default port, so a dev machine with a live
  # bridge occupying it cannot observe this case; CI has no bridge.
  if curl -s -m 1 -o /dev/null "http://127.0.0.1:17841/v1" 2>/dev/null; then
    pass "the unconfigured verdict (skipped here: a live bridge occupies the default port)"
    return 0
  fi
  home="$TMP_ROOT/health-unconfigured-home"
  mkdir -p "$home"
  out=$(unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_health); rc=$?
  expect_code 0 "$rc" "a never-configured channel must exit 0"
  assert_contains "$out" "unconfigured" "the probe must print the unconfigured verdict"
  assert_not_contains "$out" "unreachable" "an unconfigured channel must not read as unreachable"
  pass "a channel that was never configured reads as unconfigured, not unreachable"
}

test_bridge_health_configuration_evidence() {
  local home rc
  home="$TMP_ROOT/health-evidence-home"
  mkdir -p "$home"
  ( unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_configured ); rc=$?
  expect_code 1 "$rc" "no override and no consult-loop state must read as never configured"
  mkdir -p "$home/data/task-1"
  printf '{}\n' > "$home/data/task-1/chatgpt-loop.json"
  ( unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_configured ); rc=$?
  expect_code 0 "$rc" "existing consult-loop state must count as channel configuration"
  rm -rf "$home/data"
  mkdir -p "$home/config"
  : > "$home/config/chatgpt-consultation"
  ( unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_configured ); rc=$?
  expect_code 0 "$rc" "recorded channel evidence must count as channel configuration"
  fm_chatgpt_bridge_configured; rc=$?
  expect_code 0 "$rc" "the exported bridge URL override must count as channel configuration"
  pass "configuration evidence is a bridge URL override, consult-loop state, or recorded channel use"
}

test_consult_records_channel_evidence() {
  local dir pid home rc
  dir="$TMP_ROOT/evidence-consult"; mkdir -p "$dir"
  home="$TMP_ROOT/evidence-home"; mkdir -p "$home"
  new_prompt
  pid=$(start_stub "$dir")
  FM_HOME="$home" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-evidence >/dev/null 2>&1; rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "an audit consult against the stub should succeed"
  ( unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_configured ); rc=$?
  expect_code 0 "$rc" "a home that ran a consult must read as configured without an override or loop state"

  home="$TMP_ROOT/evidence-down-home"; mkdir -p "$home"
  CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" FM_HOME="$home" bash "$CONSULT" \
    --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-down-evidence >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable bridge must fail the consult"
  ( unset CHATGPT_WEB_BRIDGE_URL; FM_HOME="$home"; fm_chatgpt_bridge_configured ); rc=$?
  expect_code 0 "$rc" "a failed consult must still record channel evidence"
  pass "a consult records durable channel evidence so a later dead bridge is reported"
}

test_project_header_contract() {
  local dir pid out rc routes
  # No --project: the request carries no routing header, byte-for-byte the
  # upstream shape.
  dir="$TMP_ROOT/proj-none"; mkdir -p "$dir"
  routes="$TMP_ROOT/proj-none-routes"; mkdir -p "$routes"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(FM_CHATGPT_ROUTES_DIR="$routes" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-none 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a consult without --project must succeed"
  [ "$out" = "stubbed consultation answer" ] || fail "a headerless consult must print the answer, got: $out"
  [ -z "$(jq -r '.["x-fm-chatgpt-project"] // empty' "$dir/headers.json")" ] \
    || fail "a consult without --project must send no x-fm-chatgpt-project header"
  [ ! -s "$dir/stderr.txt" ] || fail "a headerless consult must stay quiet on stderr, got: $(cat "$dir/stderr.txt")"
  # With --project: the exact repository name rides the header and no
  # outcome means no fallback notice.
  dir="$TMP_ROOT/proj-set"; mkdir -p "$dir"
  routes="$TMP_ROOT/proj-set-routes"; mkdir -p "$routes"
  pid=$(start_stub "$dir")
  out=$(FM_CHATGPT_ROUTES_DIR="$routes" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-set --project expo-bowling-journal 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a consult with --project must succeed"
  [ "$out" = "stubbed consultation answer" ] || fail "a routed consult must print the answer, got: $out"
  [ "$(jq -r '.["x-fm-chatgpt-project"]' "$dir/headers.json")" = "expo-bowling-journal" ] \
    || fail "the header must carry the exact repository name, got: $(jq -r '.["x-fm-chatgpt-project"]' "$dir/headers.json")"
  [ "$(jq -r '.model' "$dir/request.json")" = "chatgpt-web/gpt-5.6-luna" ] \
    || fail "routing must not change the request model"
  [ ! -s "$dir/stderr.txt" ] || fail "a routed consult with no fallback outcome must stay quiet, got: $(cat "$dir/stderr.txt")"
  # An invalid name is refused before any bridge contact.
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-bad --project '../etc/passwd' 2>&1); rc=$?
  expect_code 2 "$rc" "an invalid --project name must refuse with exit 2"
  assert_contains "$out" "refusing invalid --project" "the refusal must name the rejected value"
  assert_contains "$out" "../etc/passwd" "the refusal must echo the invalid name"
  pass "no --project sends no header, --project sends the exact name, invalid names refuse"
}

test_project_fallback_notice_is_advisory() {
  local dir pid out rc stderr routes
  # The bridge recorded this turn's routing as a fallback: exactly one stderr
  # notice, exit 0, stdout unchanged.
  dir="$TMP_ROOT/proj-fallback"; mkdir -p "$dir"
  routes="$TMP_ROOT/proj-fallback-routes"; mkdir -p "$routes"
  new_prompt
  pid=$(start_stub "$dir" 200 fallback-route "$routes")
  out=$(FM_CHATGPT_ROUTES_DIR="$routes" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-fb --project firstmate 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a routing fallback must not fail the consultation"
  [ "$out" = "stubbed consultation answer" ] || fail "a fallback must leave stdout unchanged, got: $out"
  stderr=$(cat "$dir/stderr.txt")
  [ "$stderr" = "fm-chatgpt: project routing: fallback (unmapped)" ] \
    || fail "expected exactly one fallback notice, got: $stderr"
  # A successful project route stays silent even with a project requested.
  dir="$TMP_ROOT/proj-routed"; mkdir -p "$dir"
  routes="$TMP_ROOT/proj-routed-routes"; mkdir -p "$routes"
  pid=$(start_stub "$dir" 200 project-route "$routes")
  out=$(FM_CHATGPT_ROUTES_DIR="$routes" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-ok --project firstmate 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a successful project route must succeed"
  [ ! -s "$dir/stderr.txt" ] || fail "a successful project route must stay quiet, got: $(cat "$dir/stderr.txt")"
  # A routing outcome older than this consult is never mistaken for its
  # fallback, so repeated consults after one fallback do not keep reporting.
  dir="$TMP_ROOT/proj-stale"; mkdir -p "$dir"
  routes="$TMP_ROOT/proj-stale-routes"; mkdir -p "$routes"
  pid=$(start_stub "$dir" 200 fallback-route-stale "$routes")
  out=$(FM_CHATGPT_ROUTES_DIR="$routes" bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" \
    --mode audit --thread t-proj-stale --project firstmate 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a consult with only a stale fallback outcome must succeed"
  [ "$out" = "stubbed consultation answer" ] || fail "a stale outcome must leave stdout unchanged, got: $out"
  [ ! -s "$dir/stderr.txt" ] || fail "a stale outcome must not be reported as this turn's fallback, got: $(cat "$dir/stderr.txt")"
  pass "a routing fallback prints one advisory stderr notice with exit 0 and unchanged stdout"
}

test_audit_template_missing_fails_closed() {
  local dir out rc
  dir="$TMP_ROOT/notemplate"
  mkdir -p "$dir/chatgpt"
  cp "$ROOT/fork/chatgpt/fm-chatgpt-consult.sh" "$ROOT/fork/chatgpt/fm-chatgpt-bridge-lib.sh" "$dir/chatgpt/"
  new_prompt
  out=$(bash "$dir/chatgpt/fm-chatgpt-consult.sh" \
    --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t-notemplate 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an audit consult without the audit-brief template must refuse"
  assert_contains "$out" "audit-brief template missing" "the refusal must name the missing template"
  assert_contains "$out" "fork/chatgpt/audit-brief-template" "the refusal must name the required file"
  pass "an audit consult refuses before contacting the bridge when the audit-brief template is missing"
}

test_audit_request_shape() {
  local dir=$TMP_ROOT/audit pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-audit-1 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "an audit consult against the stub should succeed"
  [ "$out" = "stubbed consultation answer" ] || fail "stdout must carry only the response text, got: $out"
  [ "$(jq -r '.model' "$dir/request.json")" = "chatgpt-web/gpt-5.6-luna" ] || fail "an audit request must carry the Responses API model"
  local instr
  instr=$(jq -r '.instructions' "$dir/request.json")
  assert_contains "$instr" "audit prompt" "an audit request must ask for a worker audit prompt"
  assert_contains "$instr" "prompt generation" "an audit request must frame the answer as prompt generation, not the audit itself"
  assert_contains "$instr" "questions the worker must answer" "the generated audit prompt must carry the worker's questions"
  assert_contains "$instr" "evidence and scope" "the generated audit prompt must carry required evidence and scope"
  assert_contains "$instr" "report shape" "the generated audit prompt must carry the report shape"
  assert_contains "$instr" "stop rules" "the generated audit prompt must carry explicit stop rules"
  assert_contains "$instr" "no local tools" "an audit request must state that local tools are unavailable and unneeded"
  assert_contains "$instr" "Audit-brief template" "an audit request must inject the shared audit-brief template"
  assert_contains "$instr" "never a whitelist" "the generated audit prompt must state the initial file list is never a whitelist"
  assert_contains "$instr" "Bounded initial reconnaissance" "the generated audit prompt must carry the bounded reconnaissance phase"
  assert_contains "$instr" "Reading budget - effort guidance, never a hard limit" "the generated audit prompt must carry reading budgets as effort guidance"
  assert_contains "$instr" "Expansion triggers" "the generated audit prompt must carry the expansion triggers"
  assert_contains "$instr" "Carry-forward discipline" "the generated audit prompt must carry the carry-forward rule"
  assert_contains "$instr" "scope sufficient" "the generated audit prompt must require an evidence-backed scope-sufficiency statement"
  assert_contains "$(jq -r '.input[0].content' "$dir/request.json")" "login handler" "the request must carry the prompt file text"
  pass "an audit consult asks for a generated worker audit prompt with the prompt text and prints only the answer"
}

test_plan_request_shape() {
  local dir=$TMP_ROOT/plan pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread thread-plan-1 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  expect_code 0 "$rc" "a plan consult against the stub should succeed"
  local instr
  instr=$(jq -r '.instructions' "$dir/request.json")
  assert_contains "$instr" "execution plan" "a plan request must frame the planner role"
  assert_contains "$instr" "Implementation plan contract the returned plan must follow:" "a plan request must inject the plan contract"
  assert_contains "$instr" "# Implementation plan contract, version 1" "the injected contract must be the version-1 template"
  assert_contains "$instr" "P11: \`basis\` cites the audit findings" "the injected contract must carry the finding-basis rule"
  assert_contains "$instr" "What validation does not prove" "the injected contract must state what validation does not prove"
  assert_contains "$instr" "your entire reply is exactly one fenced code block and nothing else - no preamble, no banner" \
    "a plan request must forbid any preamble or banner outside the block"
  # shellcheck disable=SC2016 # literal markdown fences, not expansions
  assert_contains "$instr" 'The opening fence is a line of exactly ```json' "a plan request must require the json-labelled opening fence"
  # shellcheck disable=SC2016 # literal markdown fences, not expansions
  assert_contains "$instr" 'an opening fence of ``` with no json label is refused' "a plan request must say an unlabelled fence is refused"
  # shellcheck disable=SC2016 # literal markdown fences, not expansions
  assert_contains "$instr" '```json
{"v": 1, "summary": "...", ' "a plan request must carry the minimal format example"
  assert_contains "$instr" "no local tools" "a plan request must state that local tools are unavailable and unneeded"
  [ "$out" = "stubbed consultation answer" ] || fail "the consult client must return the plan reply as text for the loop to validate, got: $out"
  pass "a plan consult injects the version-1 plan contract and returns the reply text unvalidated for the loop"
}

test_plan_contract_missing_fails_closed() {
  local dir out rc pid
  dir="$TMP_ROOT/nocontract"
  mkdir -p "$dir/chatgpt"
  cp "$ROOT/fork/chatgpt/fm-chatgpt-consult.sh" "$ROOT/fork/chatgpt/fm-chatgpt-bridge-lib.sh" "$ROOT/fork/chatgpt/audit-brief-template" "$dir/chatgpt/"
  new_prompt
  pid=$(start_stub "$dir")
  rm -f "$dir/request.json"  # left by start_stub's readiness probe
  out=$(bash "$dir/chatgpt/fm-chatgpt-consult.sh" \
    --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread t-nocontract 2>&1); rc=$?
  stop_stub "$pid"
  [ "$rc" -ne 0 ] || fail "a plan consult without the plan contract must refuse"
  assert_contains "$out" "plan contract missing" "the refusal must name the missing contract"
  assert_contains "$out" "fork/chatgpt/plan-contract.template" "the refusal must name the required file"
  [ ! -f "$dir/request.json" ] || fail "a plan consult without the contract must never contact the bridge"
  pass "a plan consult refuses before contacting the bridge when the plan contract is missing"
}

test_audit_instructions_require_finding_ids() {
  local dir=$TMP_ROOT/auditids pid instr
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-ids >/dev/null 2>&1
  stop_stub "$pid"
  instr=$(jq -r '.instructions' "$dir/request.json")
  assert_contains "$instr" "stable finding ids" "the audit instructions must ask for the template's stable finding ids"
  assert_contains "$instr" "Every finding opens with a stable id - \`A1\`, \`A2\`" "the injected audit template must define the finding-id rule"
  pass "audit prompts are generated against a template that numbers every finding A1, A2, ..."
}

test_metadata_stamping() {
  local dir=$TMP_ROOT/stamp pid
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread thread-stamp-9 >/dev/null 2>&1
  stop_stub "$pid"
  [ "$(request_meta stamp | cut -d' ' -f1)" = "thread-stamp-9" ] || fail "the stamp must carry the supplied thread id"
  grep -Eq "^turn_[0-9a-f]{32}$" <(request_meta stamp | cut -d' ' -f2) || fail "the stamp must carry a stable turn id"
  grep -Eq "^msg_[0-9a-f]{32}$" <(jq -r '.input[0].id' "$dir/request.json") || fail "input messages must carry stable item ids"
  [ "$(jq -r '.input[0].type' "$dir/request.json")" = "message" ] || fail "role-only items must gain the message type"
  pass "consultation turns carry the Codex turn stamp and stable item ids"
}

test_model_slug() {
  local dir=$TMP_ROOT/slug pid
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t1 >/dev/null 2>&1
  stop_stub "$pid"
  [ "$(jq -r '.model' "$dir/request.json")" = "chatgpt-web/gpt-5.6-luna" ] || fail "the request must ride the default qualified Luna slug"
  local slug rc
  slug=$(fm_chatgpt_model_slug "gpt-5.6-luna"); rc=$?
  expect_code 0 "$rc" "the lib should accept a bare model id"
  [ "$slug" = "chatgpt-web/gpt-5.6-luna" ] || fail "the lib must qualify the bare id, got: $slug"
  fm_chatgpt_model_slug "chatgpt-web/chatgpt-web/gpt-5.6-luna" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "the lib must refuse the doubled selector"
  pass "bare model ids ride the bridge slug and doubled selectors refuse"
}

test_thread_propagation() {
  local dir=$TMP_ROOT/thread pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir")
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread thread-keep-7 2>"$dir/stderr.txt")
  stop_stub "$pid"
  [ "$(request_meta thread | cut -d' ' -f1)" = "thread-keep-7" ] || fail "the request must propagate the supplied thread id"
  [ ! -s "$dir/stderr.txt" ] || fail "a supplied thread must not be re-reported, got: $(cat "$dir/stderr.txt")"
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan 2>&1); rc=$?
  expect_code 2 "$rc" "a missing --thread must fail closed"
  assert_contains "$out" "--thread" "the failure must name the missing option"
  pass "supplied thread ids propagate and a missing thread fails closed"
}

test_bridge_unavailable_fails_closed() {
  local out rc
  new_prompt
  out=$(CHATGPT_WEB_BRIDGE_URL="http://127.0.0.1:1/v1" bash "$CONSULT" \
    --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t-down 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable bridge must fail closed"
  assert_contains "$out" "bridge" "the failure must name the bridge prerequisite"
  pass "an unreachable bridge fails closed with a prerequisite report"
}

test_bridge_failure_fails_closed() {
  local dir=$TMP_ROOT/fail pid out rc
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir" 500)
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode audit --thread t-fail 2>&1); rc=$?
  stop_stub "$pid"
  [ "$rc" -ne 0 ] || fail "a failing bridge must fail closed"
  assert_contains "$out" "HTTP 500" "the failure must report the bridge status"
  pass "a failing bridge fails closed with its status"
}

test_structured_rejection_surfaces_bridge_diagnostic() {
  local dir=$TMP_ROOT/reject pid out rc stderr
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir" 200 reject200)
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread t-reject 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  [ "$rc" -ne 0 ] || fail "an HTTP-200 structured rejection must exit nonzero"
  [ -z "$out" ] || fail "a rejected consult must produce empty stdout, got: $out"
  stderr=$(cat "$dir/stderr.txt")
  assert_contains "$stderr" "bridge rejected" "the failure must identify a bridge rejection"
  assert_contains "$stderr" "context_length_exceeded" "the failure must carry the bridge's error code"
  assert_contains "$stderr" "This request exceeds the browser transport budget (102400 tokens)." \
    "the failure must preserve the bridge's message verbatim including its reported token count"
  pass "an HTTP-200 structured rejection exits nonzero with the bridge's own diagnostic and empty stdout"
}

test_rejection_without_reported_size_invents_nothing() {
  local dir=$TMP_ROOT/reject-nosize pid out rc stderr
  mkdir -p "$dir"
  new_prompt
  pid=$(start_stub "$dir" 200 error200)
  out=$(bash "$CONSULT" --prompt-file "$TMP_ROOT/prompt.txt" --mode plan --thread t-nosize 2>"$dir/stderr.txt"); rc=$?
  stop_stub "$pid"
  [ "$rc" -ne 0 ] || fail "a rejection with no reported size must exit nonzero"
  [ -z "$out" ] || fail "a rejected consult must produce empty stdout, got: $out"
  stderr=$(cat "$dir/stderr.txt")
  assert_contains "$stderr" "stub failure" "the failure must preserve the bridge's message"
  if printf '%s' "$stderr" | grep -q '[0-9]'; then
    fail "stderr must not invent or substitute any size, got: $stderr"
  fi
  pass "a rejection without a reported size relays the bridge message and invents no number"
}

test_audit_template_missing_fails_closed
test_project_header_contract
test_project_fallback_notice_is_advisory
test_audit_request_shape
test_plan_request_shape
test_plan_contract_missing_fails_closed
test_audit_instructions_require_finding_ids
test_metadata_stamping
test_model_slug
test_thread_propagation
test_bridge_unavailable_fails_closed
test_bridge_failure_fails_closed
test_structured_rejection_surfaces_bridge_diagnostic
test_rejection_without_reported_size_invents_nothing
test_bridge_health_probe_verdicts
test_bridge_health_unconfigured_stays_quiet
test_bridge_health_configuration_evidence
test_consult_records_channel_evidence
