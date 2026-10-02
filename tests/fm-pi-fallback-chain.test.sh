#!/usr/bin/env bash
# Tests for the Stage 2 Pi fallback chain (opencode-go/fm-fallback-chain).
#
# The tracked router extension (.pi/extensions/fm-opencode-go-chain-router.ts)
# registers one virtual model whose route() walks muse-spark-1.3-contributor
# then mimo-v2.6-flash then deepseek-v4.1-flash at thinking low, advancing only
# on the retry path with a retryable provider failure and ending after the
# third model with a surfaced error.
#
# These tests drive the real launch-construction path in bin/fm-spawn.sh with
# a fake tmux pane and a real isolated git worktree, so the -e wiring is
# proven, and they drive the router's real route() through node with a stubbed
# Pi model registry, so the chain behavior is proven. No live model or quota
# is touched anywhere in this file.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ROUTER="$ROOT/.pi/extensions/fm-opencode-go-chain-router.ts"
TMP_ROOT=$(fm_test_tmproot fm-pi-fallback-chain)

make_chain_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_chain_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_chain_pi_probe "$fakebin" pi
  make_chain_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_chain_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_chain_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_chain_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_chain_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR="" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_chain_ship_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  run_chain_spawn "$home" "$wt" "$fakebin" "$launchlog" "$@" --mode no-mistakes --yolo off
}

make_chain_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-kind"
  git -C "$home" init -q -b main
}

test_pi_crewmate_launch_loads_chain_router_alongside_turnend_extension() {
  local rec id out status launch
  id=chain-pi-wiring-z1
  rec=$(make_chain_case chain-pi-wiring pi "$id")
  read_chain_record "$rec"

  out=$(run_chain_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model opencode-go/fm-fallback-chain --effort low)
  status=$?
  expect_code 0 "$status" "pi spawn carrying the chain router should succeed"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report the pi harness"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$ROOT/.pi/extensions/fm-opencode-go-chain-router.ts' -e '$HOME_DIR/state/$id.pi-ext.ts'" \
    "pi launch did not load the tracked chain router next to the per-task extension"
  assert_contains "$launch" "--model 'opencode-go/fm-fallback-chain' --thinking 'low'" \
    "pi launch did not thread the virtual chain model with thinking low"
  pass "a pi crewmate launches with the tracked chain router as a second extension"
}

test_pi_signed_launch_loads_chain_router() {
  local rec id out status launch
  id=chain-pi-signed-wiring-z2
  rec=$(make_chain_case chain-pi-signed-wiring pi-signed "$id")
  read_chain_record "$rec"

  out=$(run_chain_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi-signed spawn carrying the chain router should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$ROOT/.pi/extensions/fm-opencode-go-chain-router.ts' -e '$HOME_DIR/state/$id.pi-ext.ts'" \
    "pi-signed launch did not load the tracked chain router next to the per-task extension"
  pass "a pi-signed crewmate launches with the tracked chain router as a second extension"
}

test_pi_secondmate_launch_loads_chain_router() {
  local rec id sm out status launch
  id=chain-pi-secondmate-wiring-z3
  rec=$(make_chain_case chain-pi-secondmate-wiring pi "$id")
  read_chain_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_chain_secondmate_home "$sm" "$id"

  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi secondmate spawn carrying the chain router should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$ROOT/.pi/extensions/fm-opencode-go-chain-router.ts' -e " \
    "pi secondmate launch did not load the tracked chain router"
  pass "a pi secondmate launches with the tracked chain router"
}

test_non_pi_launches_omit_chain_router() {
  local rec id out status launch
  id=chain-nonpi-omits-z4
  rec=$(make_chain_case chain-nonpi-omits codex "$id")
  read_chain_record "$rec"

  out=$(run_chain_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "fm-opencode-go-chain-router" \
    "a non-Pi launch picked up the Pi chain router"

  id=chain-nonpi-opencode-omits-z5
  rec=$(make_chain_case chain-nonpi-opencode-omits opencode "$id")
  read_chain_record "$rec"

  out=$(run_chain_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness opencode)
  status=$?
  expect_code 0 "$status" "opencode spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "fm-opencode-go-chain-router" \
    "an opencode launch picked up the Pi chain router"
  assert_not_contains "$launch" "--thinking" \
    "an opencode launch gained a Pi thinking flag"
  pass "non-Pi harness launches stay byte-identical with no chain router"
}

# Node driver for the router's real route(): imports the tracked extension
# with a stubbed ExtensionAPI that captures the virtual-model definition and
# a stubbed three-model opencode-go registry, then runs one behavior case
# named by $FM_CHAIN_CASE. A failing case throws, which fails the test.
write_chain_driver() {
  cat > "$TMP_ROOT/chain-driver.mjs" <<'JS'
import { pathToFileURL } from "node:url";

const routerPath = process.env.FM_CHAIN_ROUTER;
const mod = await import(pathToFileURL(routerPath).href);

let def;
const pi = { registerVirtualModel(d) { def = d; } };
mod.default(pi);
if (!def) throw new Error("the extension registered no virtual model");
if (def.provider !== "opencode-go" || def.id !== "fm-fallback-chain") {
  throw new Error(`unexpected virtual identity: ${def.provider}/${def.id}`);
}

const registry = [
  { provider: "opencode-go", id: "muse-spark-1.3-contributor" },
  { provider: "opencode-go", id: "mimo-v2.6-flash" },
  { provider: "opencode-go", id: "deepseek-v4.1-flash" },
];
const findCalls = [];
const ctx = {
  modelRegistry: {
    find: (provider, id) => {
      findCalls.push(`${provider}/${id}`);
      return registry.find((m) => m.provider === provider && m.id === id);
    },
  },
};

function failedOf(id, stopReason, errorMessage) {
  const model = registry.find((m) => m.id === id);
  return { model, thinkingLevel: "low", message: { stopReason, errorMessage } };
}

async function route(reason, state, failed, previous) {
  return def.route({ reason, thinkingLevel: "low", state, failed, previous, messages: [], signal: undefined }, ctx);
}

function expect(cond, message) {
  if (!cond) throw new Error(message);
}

const which = process.env.FM_CHAIN_CASE;

// (1) A first-model retryable failure advances to the second model.
if (which === "advance-first") {
  const first = await route("user", undefined, undefined, undefined);
  expect(first.model.id === "muse-spark-1.3-contributor", `first route went to ${first.model.id}`);
  expect(first.thinkingLevel === "low", "first route lost thinking low");
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "429 rate limit exceeded, slow down"), undefined);
  expect(second.model.id === "mimo-v2.6-flash", `retry did not advance to the second model: ${second.model.id}`);
  expect(second.thinkingLevel === "low", "second route lost thinking low");
  expect(second.state.attempt === 1, `attempt did not move to 1: ${JSON.stringify(second.state)}`);
}

// (2) A retryable failure advances appropriately at each step.
if (which === "advance-each-step") {
  const first = await route("user", undefined, undefined, undefined);
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "quota exhausted for the project"), undefined);
  expect(second.model.id === "mimo-v2.6-flash", `step one advanced to ${second.model.id}`);
  const third = await route("retry", second.state, failedOf("mimo-v2.6-flash", "error", "503 Service Unavailable"), undefined);
  expect(third.model.id === "deepseek-v4.1-flash", `step two advanced to ${third.model.id}`);
  expect(third.thinkingLevel === "low", "third route lost thinking low");
  expect(third.state.attempt === 2, `attempt did not move to 2: ${JSON.stringify(third.state)}`);
}

// (3) A non-retryable failure never advances and surfaces the error.
if (which === "terminal-never-advances") {
  const terminalFailures = [
    ["muse-spark-1.3-contributor", "error", "This model's maximum context length is 200000 tokens, too many tokens"],
    ["muse-spark-1.3-contributor", "error", "content filtered by the safety system, request refused"],
    ["muse-spark-1.3-contributor", "cancelled", "request cancelled by the user"],
    ["muse-spark-1.3-contributor", "aborted", "AbortError: the operation was aborted"],
    ["muse-spark-1.3-contributor", "error", "tool failed: file not found in the worktree"],
    ["mimo-v2.6-flash", "error", "unexpected application error in the worker task"],
    ["deepseek-v4.1-flash", "error", "something completely unrecognized happened"],
  ];
  const first = await route("user", undefined, undefined, undefined);
  let state = first.state;
  if (state.attempt !== 0) throw new Error("fresh session did not start at attempt 0");
  for (const [id, stop, message] of terminalFailures) {
    let threw = null;
    try {
      await route("retry", state, failedOf(id, stop, message), undefined);
    } catch (err) {
      threw = err;
    }
    expect(threw, `terminal failure did not surface an error: [${stop}] ${message}`);
  }
  // None of the terminal retries may have advanced the registry past the models
  // the fresh user route already resolved.
  expect(findCalls.length === 1, `terminal retries touched the registry: ${JSON.stringify(findCalls)}`);
  // The surfaced error carries the original failure text.
  let surfaced = null;
  try {
    await route("retry", state, failedOf("muse-spark-1.3-contributor", "error", "content filtered by the safety system"), undefined);
  } catch (err) {
    surfaced = err;
  }
  expect(surfaced && /content filtered/.test(surfaced.message), `surfaced error lost the original text: ${surfaced && surfaced.message}`);
}

// (4) The chain terminates after the third model with no fourth attempt.
if (which === "terminates-after-third") {
  const first = await route("user", undefined, undefined, undefined);
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "429 too many requests"), undefined);
  const third = await route("retry", second.state, failedOf("mimo-v2.6-flash", "error", "upstream overloaded, try again"), undefined);
  expect(third.model.id === "deepseek-v4.1-flash", `chain did not reach the third model: ${third.model.id}`);
  let threw = null;
  try {
    await route("retry", third.state, failedOf("deepseek-v4.1-flash", "error", "429 too many requests"), undefined);
  } catch (err) {
    threw = err;
  }
  expect(threw, "a retryable failure on the third model did not end the chain");
  expect(/exhausted/.test(threw.message), `exhaustion error did not say so: ${threw.message}`);
  expect(/429 too many requests/.test(threw.message), `exhaustion error lost the last failure: ${threw.message}`);
  expect(findCalls.length === 3, `the chain made a fourth lookup: ${JSON.stringify(findCalls)}`);
  expect(!findCalls.some((c) => !c.startsWith("opencode-go/")), `the chain left its provider: ${JSON.stringify(findCalls)}`);
}

// (5) Thinking low stays attached to every routed model on every hop.
if (which === "thinking-low-everywhere") {
  const seen = [];
  const first = await route("user", undefined, undefined, undefined);
  seen.push(first);
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "quota exhausted"), undefined);
  seen.push(second);
  const third = await route("retry", second.state, failedOf("mimo-v2.6-flash", "error", "rate limited"), undefined);
  seen.push(third);
  const followup = await route("continuation", third.state, undefined, { model: third.model, thinkingLevel: "low" });
  seen.push(followup);
  for (const r of seen) {
    expect(r.thinkingLevel === "low", `a hop lost thinking low on ${r.model.id}: ${r.thinkingLevel}`);
    expect(r.model.provider === "opencode-go", `a hop left opencode-go: ${r.model.provider}/${r.model.id}`);
  }
  expect(def.thinkingLevels.length === 1 && def.thinkingLevels[0] === "low", `virtual selection is not low-only: ${JSON.stringify(def.thinkingLevels)}`);
}

// Sticky follow-ups and no backward skips: continuation stays on the handling
// model, a new turn keeps the chain position, and state never moves backward.
if (which === "sticky-no-backward") {
  const first = await route("user", undefined, undefined, undefined);
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "rate limited"), undefined);
  const followup = await route("continuation", second.state, undefined, { model: second.model, thinkingLevel: "low" });
  expect(followup.model.id === "mimo-v2.6-flash", `continuation left the handling model: ${followup.model.id}`);
  expect(JSON.stringify(followup.state) === JSON.stringify(second.state), "continuation rewrote the router state");
  const nextTurn = await route("user", second.state, undefined, undefined);
  expect(nextTurn.model.id === "mimo-v2.6-flash", `a new turn skipped backward: ${nextTurn.model.id}`);
  expect(nextTurn.state.attempt === 1, `a new turn moved the attempt: ${JSON.stringify(nextTurn.state)}`);
}

// Classification table: the exact retryable and terminal classes the brief
// requires, including the live-verified unavailable-model server-error shape.
if (which === "classification-table") {
  const cases = [
    ["error", "quota exhausted for this billing period", "retryable"],
    ["error", "429: too many requests, rate limit exceeded", "retryable"],
    ["error", "RateLimitError: request was rate limited", "retryable"],
    ["error", "503 Service Unavailable", "retryable"],
    ["error", "502 Bad Gateway from the provider", "retryable"],
    ["error", "provider overloaded, try again later", "retryable"],
    ["error", "request timed out after 30000ms", "retryable"],
    ["error", "socket hang up (ECONNRESET)", "retryable"],
    ["error", "400: {\"type\":\"server_error\",\"message\":\"Upstream request failed: Model is unavailable.\"}", "retryable"],
    ["error", "insufficient credits to complete the request", "retryable"],
    ["error", "This model's maximum context length is 200000 tokens", "terminal"],
    ["error", "prompt is too long: context overflow", "terminal"],
    ["error", "context_length_exceeded: reduce the input", "terminal"],
    ["error", "content filtered by the safety system", "terminal"],
    ["error", "request blocked by content filter", "terminal"],
    ["error", "response refused under the usage policy", "terminal"],
    ["cancelled", "request cancelled by the user", "terminal"],
    ["aborted", "AbortError: the operation was aborted", "terminal"],
    ["error", "the operation was aborted before completion", "terminal"],
    ["error", "tool failed: file not found in the worktree", "terminal"],
    ["error", "SyntaxError: unexpected token in the worker reply", "terminal"],
    ["error", "something completely unrecognized happened", "terminal"],
    ["error", "rate limited but also context overflow in the same text: context length exceeded", "terminal"],
  ];
  for (const [stop, message, want] of cases) {
    const got = mod.classifyRouterFailure(stop, message);
    expect(got === want, `classify [${stop}] ${message.slice(0, 60)}: want ${want}, got ${got}`);
  }
}

// Transport-level failures retry: the exact live-observed shapes, including the
// verbatim `Connection error.` text from the forced-failure run against a closed
// port. Each must advance the chain rather than terminate it.
if (which === "transport-retryable") {
  const transportFailures = [
    ["muse-spark-1.3-contributor", "error", "Connection error."],
    ["muse-spark-1.3-contributor", "error", "connect ECONNREFUSED 127.0.0.1:1"],
    ["muse-spark-1.3-contributor", "error", "Connection reset by peer"],
    ["mimo-v2.6-flash", "error", "getaddrinfo ENOTFOUND api.example.com"],
    ["mimo-v2.6-flash", "error", "network unreachable: no route to host"],
    ["mimo-v2.6-flash", "error", "transport closed before the response completed"],
    ["muse-spark-1.3-contributor", "error", "Connection error."],
  ];
  const first = await route("user", undefined, undefined, undefined);
  let state = first.state;
  for (const [id, stop, message] of transportFailures) {
    const verdict = mod.classifyRouterFailure(stop, message);
    expect(verdict === "retryable", `transport failure not retryable: [${stop}] ${message} (got ${verdict})`);
    const next = await route("retry", state, failedOf(id, stop, message), undefined);
    expect(next.state.attempt === Math.min(state.attempt + 1, 2), `transport failure did not advance: [${stop}] ${message}`);
    state = next.state;
    if (state.attempt >= 2) state = first.state;
  }
  // A bare policy refusal still terminates even though it shares wording with a
  // refused connection: terminal patterns win over the transport families.
  const policyVerdict = mod.classifyRouterFailure("error", "response refused under the usage policy");
  expect(policyVerdict === "terminal", `policy refusal lost terminal verdict: ${policyVerdict}`);
}

// A retry with no failure detail holds the current model: Pi sends failed
// absent when routing itself failed, so there is nothing to classify and no
// evidence to advance on. The route returns the current attempt's model without
// throwing and without touching the registry past the current model.
if (which === "retry-no-failure-detail") {
  const first = await route("user", undefined, undefined, undefined);
  const held = await route("retry", first.state, undefined, undefined);
  expect(held.model.id === "muse-spark-1.3-contributor", `detail-less retry left the current model: ${held.model.id}`);
  expect(held.thinkingLevel === "low", "detail-less retry lost thinking low");
  expect(held.state.attempt === 0, `detail-less retry moved the attempt: ${JSON.stringify(held.state)}`);
  expect(findCalls.length === 2 && findCalls[1] === "opencode-go/muse-spark-1.3-contributor", `detail-less retry looked past the current model: ${JSON.stringify(findCalls)}`);
  // Mid-chain holds too, and the held position still advances on the next real
  // provider failure, so one routing-level retry can never spin the chain.
  const second = await route("retry", first.state, failedOf("muse-spark-1.3-contributor", "error", "Connection error."), undefined);
  const heldMid = await route("retry", second.state, undefined, undefined);
  expect(heldMid.model.id === "mimo-v2.6-flash", `mid-chain detail-less retry left the model: ${heldMid.model.id}`);
  expect(heldMid.state.attempt === 1, `mid-chain detail-less retry moved the attempt: ${JSON.stringify(heldMid.state)}`);
  const third = await route("retry", heldMid.state, failedOf("mimo-v2.6-flash", "error", "Connection error."), undefined);
  expect(third.model.id === "deepseek-v4.1-flash", `held position did not advance on the next real failure: ${third.model.id}`);
}

console.log(`chain driver case ${which}: ok`);
JS
}

run_chain_driver() {
  FM_CHAIN_ROUTER="$ROUTER" FM_CHAIN_CASE="$1" node "$TMP_ROOT/chain-driver.mjs"
}

require_chain_node() {
  command -v node >/dev/null 2>&1 || {
    printf '# skip - node not found for the chain router driver\n'
    return 1
  }
  write_chain_driver
}

test_chain_first_failure_advances_to_second() {
  require_chain_node || return 0
  run_chain_driver advance-first || fail "a retryable first-model failure did not advance to the second model"
  pass "a first-model retryable failure advances to the second model"
}

test_chain_retryable_advances_at_each_step() {
  require_chain_node || return 0
  run_chain_driver advance-each-step || fail "a retryable failure did not advance at each chain step"
  pass "a retryable failure advances appropriately at each step"
}

test_chain_non_retryable_never_advances() {
  require_chain_node || return 0
  run_chain_driver terminal-never-advances || fail "a non-retryable failure advanced the chain or hid the error"
  pass "a non-retryable failure does not advance and surfaces the error"
}

test_chain_terminates_after_third() {
  require_chain_node || return 0
  run_chain_driver terminates-after-third || fail "the chain did not terminate after the third model"
  pass "the chain terminates after the third model with no fourth attempt"
}

test_chain_thinking_low_on_every_hop() {
  require_chain_node || return 0
  run_chain_driver thinking-low-everywhere || fail "thinking low did not stay attached to every routed model"
  pass "thinking low stays attached to every routed model"
}

test_chain_sticky_followups_and_no_backward_skip() {
  require_chain_node || return 0
  run_chain_driver sticky-no-backward || fail "continuation left the handling model or state moved backward"
  pass "follow-ups stay on the handling model and the chain never skips backward"
}

test_chain_classification_table() {
  require_chain_node || return 0
  run_chain_driver classification-table || fail "the failure classification table misclassified a case"
  pass "quota, rate-limit, and transient failures retry while overflow, filter, abort, and task errors end the chain"
}

test_chain_transport_failures_retry() {
  require_chain_node || return 0
  run_chain_driver transport-retryable || fail "a transport-level failure did not advance the chain"
  pass "transport failures including the live-observed Connection error. advance the chain"
}

test_chain_retry_without_failure_detail_holds() {
  require_chain_node || return 0
  run_chain_driver retry-no-failure-detail || fail "a retry with no failure detail threw or moved the chain"
  pass "a retry with no failure detail holds the current model without error"
}

test_pi_crewmate_launch_loads_chain_router_alongside_turnend_extension
test_pi_signed_launch_loads_chain_router
test_pi_secondmate_launch_loads_chain_router
test_non_pi_launches_omit_chain_router
test_chain_first_failure_advances_to_second
test_chain_retryable_advances_at_each_step
test_chain_non_retryable_never_advances
test_chain_terminates_after_third
test_chain_thinking_low_on_every_hop
test_chain_sticky_followups_and_no_backward_skip
test_chain_classification_table
test_chain_transport_failures_retry
test_chain_retry_without_failure_detail_holds

echo "# all fm-pi-fallback-chain tests passed"
