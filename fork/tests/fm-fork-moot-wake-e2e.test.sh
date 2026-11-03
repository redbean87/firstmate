#!/usr/bin/env bash
# Moot-wake settlement, end to end: the REAL upstream Pi watch extension
# (.pi/extensions/fm-primary-pi-watch.ts) and the REAL fork extension
# (fork/wake-guard/fm-pi-moot-wake.ts) on one fake Pi event bus, with a stub
# bin/fm-watch-arm.sh as the only fake. The seam under test is the upstream
# extension's dispatch offer: the fork extension may settle a wake there, and
# nowhere else.
#
# Pinned both ways:
#   - a wake whose queue row is gone (drained before its first delivery, or
#     drained while Pi held it unconsumed and the session was then replaced) is
#     settled with nothing sent, while the successor watcher is still restored
#     and the --handling-delivered handshake still runs;
#   - a wake whose row is present is delivered exactly as upstream does today,
#     as is every rows-less wake and every watcher-failure alarm.
# The unguarded baseline (fork extension not loaded) is kept as the
# reproduction: it must re-deliver, which proves the guarded cases are not
# vacuous. If an upstream sync ever fixes that defect itself, the baseline
# cases fail and the fork guard can be retired.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=fork/tests/moot-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/moot-wake-lib.sh"
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

ETMP=$(fm_test_tmproot fm-fork-moot-wake-e2e)
SCENARIO="$ETMP/scenario.mjs"
cat > "$SCENARIO" <<'JS'
// STEPS is a ";"-separated list run in order against one extension instance:
//   start                       lock the home, load the extension(s), session_start
//   await-prompts:<n>           wait until n wake prompts were sent to main
//   await-handshakes:<n>        wait until the stub saw n --handling-delivered calls
//   await-handoff-gone          wait until no replacement handoff file remains
//   drain                       empty the wake queue (a drain retired the rows)
//   replace                     session_shutdown(new) then session_start(new)
//   idle:<ms>                   wait, so a late delivery would be seen
// Prints PROMPTS=<n> (prompts containing REASON), OFFERS=<n> (dispatch offers
// emitted), and exits 3 naming the step if an await times out.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { createFakePi, waitFor, settle } = await import(pathToFileURL(process.env.MOOT_FAKE_PI).href);
const state = process.env.FM_STATE_OVERRIDE;
const handoff = `${state}/extensions/pi-primary-watch/session-replacement-actionable.json`;
const fake = createFakePi();
const wakes = () => fake.prompts.filter((p) => p.includes(process.env.REASON));
const handshakes = () => (existsSync(process.env.STUB_CALLS)
  ? readFileSync(process.env.STUB_CALLS, "utf8").split("\n").filter((l) => l.startsWith("handling-delivered")).length
  : 0);
for (const step of process.env.STEPS.split(";")) {
  const [name, arg] = step.split(":");
  try {
    if (name === "start") {
      writeFileSync(`${state}/.lock`, `${process.pid}\n`);
      if (process.env.FORK_EXT) (await import(pathToFileURL(process.env.FORK_EXT).href)).default(fake.pi);
      (await import(pathToFileURL(process.env.PLUGIN).href)).default(fake.pi);
      await fake.fire("session_start", { type: "session_start", reason: "startup" });
    } else if (name === "await-prompts") {
      await waitFor(() => wakes().length >= Number(arg), 15000, step);
    } else if (name === "await-handshakes") {
      await waitFor(() => handshakes() >= Number(arg), 15000, step);
    } else if (name === "await-handoff-gone") {
      await waitFor(() => !existsSync(handoff), 15000, step);
    } else if (name === "drain") {
      writeFileSync(`${state}/.wake-queue`, "");
    } else if (name === "replace") {
      await fake.fire("session_shutdown", { type: "session_shutdown", reason: "new" });
      await fake.fire("session_start", { type: "session_start", reason: "new" });
    } else if (name === "idle") {
      await settle(Number(arg));
    } else {
      throw new Error(`unknown step ${step}`);
    }
  } catch (error) {
    console.log(`TIMEOUT ${step}: ${error.message}`);
    process.exit(3);
  }
}
console.log(`PROMPTS=${wakes().length}`);
console.log(`OFFERS=${fake.emitted.filter((e) => e.name === "fm-branch-supervision:dispatch").length}`);
process.exit(0);
JS

# run_world <name> <reason> <drain-before-first-wake:keep|drain> <later-arm:ok|fail> <load-fork:yes|no> <steps>
# Builds a fresh home with one queued row, runs the steps, and leaves the
# world in $ETMP/<name> for assertions. Prints the scenario's output.
run_world() {
  local name=$1 reason=$2 drain=$3 later=$4 fork=$5 steps=$6 root repo home out
  root="$ETMP/$name"
  repo="$root/root"
  home="$root/home"
  mkdir -p "$home/state" "$home/config"
  moot_install_fixture "$repo"
  moot_write_arm "$repo" "$root/stub" "$reason" "$drain" "$later"
  moot_queue_row "$home/state"
  out=$(
    PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
      FORK_EXT="$([ "$fork" = yes ] && printf '%s' "$repo/fork/wake-guard/fm-pi-moot-wake.ts")" \
      MOOT_FAKE_PI="$MOOT_FAKE_PI" REASON="$reason" STEPS="$steps" STUB_CALLS="$root/stub/calls" \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
      FM_WATCH_REARM_RETRY_BASE_MS=20 FM_WATCH_REARM_RETRY_LIMIT=1 \
      node "$SCENARIO" 2>&1
  )
  rm -f "$root/stub/count"   # lets every idle stub arm exit
  printf '%s' "$out"
}

field() {  # <KEY> <output> -> the KEY=value value
  printf '%s\n' "$2" | sed -n "s/^$1=//p" | tail -1
}

calls_of() {  # <name> <prefix> -> how many stub calls start with the prefix
  grep -c "^$2" "$ETMP/$1/stub/calls" 2>/dev/null || true
}

REARM='check: rearm-resurface'

test_baseline_without_the_fork_extension_redelivers_a_wake_whose_row_is_gone() {
  local out
  out=$(run_world baseline "$REARM" keep ok no \
    'start;await-prompts:1;drain;replace;await-prompts:2;idle:800')
  assert_equals 2 "$(field PROMPTS "$out")" \
    "the reproduction: upstream alone delivers the wake again after its row is drained: $out"
  pass "baseline: upstream alone re-delivers an unconsumed wake after its row is drained and the session is replaced"
}

test_a_gone_row_wake_is_settled_on_replay_with_the_restore_and_handshake_intact() {
  local out log
  out=$(run_world replay "$REARM" keep ok yes \
    'start;await-prompts:1;drain;replace;await-handshakes:2;await-handoff-gone;idle:800')
  assert_equals 1 "$(field PROMPTS "$out")" \
    "a wake delivered once while its row was queued must not be delivered again once the row is gone: $out"
  assert_equals 2 "$(field OFFERS "$out")" "the settlement goes through the upstream dispatch offer, once per delivery attempt: $out"
  log=$(cat "$ETMP/replay/home/state/.moot-wake.log")
  assert_equals 1 "$(printf '%s\n' "$log" | grep -c "settled	$REARM")" "exactly one wake was settled: $log"
  [ "$(calls_of replay 'arm ')" -ge 3 ] || fail "the successor watcher must still be restored for the replacement: $(cat "$ETMP/replay/stub/calls")"
  assert_equals 2 "$(calls_of replay handling-delivered)" "the --handling-delivered handshake must still run before settlement"
  assert_absent "$ETMP/replay/home/state/extensions/pi-primary-watch/session-replacement-actionable.json" \
    "the settled record is finished, so no replacement handoff remains"
  pass "a wake whose row is gone is settled on replay: nothing sent, successor restored, handshake run, record finished"
}

test_a_wake_drained_before_its_first_delivery_is_settled_not_sent() {
  local out unguarded
  unguarded=$(run_world drained-baseline "$REARM" drain ok no 'start;await-prompts:1;idle:300')
  assert_equals 1 "$(field PROMPTS "$unguarded")" "baseline: without the fork extension the drained wake is still sent: $unguarded"
  out=$(run_world drained "$REARM" drain ok yes 'start;await-handshakes:1;idle:1200')
  assert_equals 0 "$(field PROMPTS "$out")" "a wake whose row a drain already retired must not reach main: $out"
  assert_equals 1 "$(field OFFERS "$out")" "the wake was offered once and settled there: $out"
  assert_contains "$(cat "$ETMP/drained/home/state/.moot-wake.log")" "settled	$REARM" "the settlement is recorded"
  [ "$(calls_of drained 'arm ')" -ge 2 ] || fail "the successor watcher must still be restored: $(cat "$ETMP/drained/stub/calls")"
  assert_equals 1 "$(calls_of drained handling-delivered)" "the handshake runs before the settlement"
  pass "a wake drained before its first delivery is settled with nothing sent, successor and handshake intact"
}

test_a_wake_whose_row_is_present_is_delivered_exactly_once_and_replayed_as_today() {
  local out
  out=$(run_world present "$REARM" keep ok yes 'start;await-prompts:1;await-handshakes:1;idle:1200')
  assert_equals 1 "$(field PROMPTS "$out")" "a queued row keeps its single delivery: $out"
  assert_equals 1 "$(field OFFERS "$out")" "the offer was made once: $out"
  assert_absent "$ETMP/present/home/state/.moot-wake.log" "nothing was settled while the row was queued"
  out=$(run_world present-replay "$REARM" keep ok yes \
    'start;await-prompts:1;replace;await-handshakes:2;await-prompts:2;idle:800')
  assert_equals 2 "$(field PROMPTS "$out")" \
    "with the row still queued the unconsumed wake is replayed exactly as upstream does: $out"
  assert_absent "$ETMP/present-replay/home/state/.moot-wake.log" "a present row is never settled, even on replay"
  pass "a wake whose row is present is delivered exactly once, and replayed unchanged"
}

test_a_rows_less_wake_is_delivered_even_when_the_queue_is_empty() {
  local out
  out=$(run_world rowsless 'check: inactive-outcome' drain ok yes 'start;await-prompts:1;idle:800')
  assert_equals 1 "$(field PROMPTS "$out")" "a wake with no queue row of its own is never settled: $out"
  assert_equals 1 "$(field OFFERS "$out")" "it was still offered: $out"
  assert_absent "$ETMP/rowsless/home/state/.moot-wake.log" "nothing was settled"
  pass "a rows-less wake keeps its delivery against an empty queue"
}

test_a_failed_restoration_is_always_delivered_even_when_the_wake_is_moot() {
  local out
  out=$(run_world failure "$REARM" drain fail yes 'start;await-prompts:1;idle:800')
  assert_equals 1 "$(field PROMPTS "$out")" "the failure alarm and its wake must reach main: $out"
  assert_equals 0 "$(field OFFERS "$out")" "a failed restoration makes no offer at all, so nothing can settle it: $out"
  assert_absent "$ETMP/failure/home/state/.moot-wake.log" "nothing was settled"
  pass "a failed successor restoration reaches main even against an empty queue"
}

fork_run_tests
