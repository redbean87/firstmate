#!/usr/bin/env bash
# Moot-wake settlement (fork/wake-guard/fm-pi-moot-wake.ts): the fork
# extension listens on the upstream watch extension's dispatch-offer event and
# accepts an offer only when the wake is provably moot - a row-backed wake
# kind (check: rearm-resurface, signal:, stale:, heartbeat) while the wake
# queue is readable and holds zero bytes. Every doubt declines, so upstream
# delivers the wake exactly as it does today.
#
# These cases drive the REAL fork extension on a fake Pi event bus with
# hand-built offers and read the offer back, exactly as the upstream
# extension does after emit returns. The real upstream extension and the
# whole delivery path are pinned in fm-fork-moot-wake-e2e.test.sh. No test
# touches a live fleet or the running session's own home.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=fork/tests/moot-wake-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/moot-wake-lib.sh"
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

MTMP=$(fm_test_tmproot fm-fork-moot-wake)
DRIVER="$MTMP/driver.mjs"
cat > "$DRIVER" <<'JS'
// Emits one hand-built offer per OFFERS entry and prints
// "<accepted|declined> <settlement-tag> <message>" for each, or the number of
// malformed emissions survived when OFFERS is the string "malformed".
import { pathToFileURL } from "node:url";
const { createFakePi } = await import(pathToFileURL(process.env.MOOT_FAKE_PI).href);
const fake = createFakePi();
const mod = await import(pathToFileURL(process.env.MOOT_EXT).href);
mod.default(fake.pi);
const EVENT = mod.DISPATCH_EVENT;
if (process.env.OFFERS === "malformed") {
  let survived = 0;
  for (const bad of [null, undefined, {}, { accept: 1 }, "text", 7, { accept() {}, message: 7 }]) {
    fake.pi.events.emit(EVENT, bad);
    survived += 1;
  }
  console.log(`survived ${survived}`);
  process.exit(0);
}
for (const entry of JSON.parse(process.env.OFFERS)) {
  const offer = {
    message: entry.message,
    accepted: false,
    settlement: Promise.resolve("default"),
    accept(settlement = Promise.resolve("default")) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  if (entry.pre === "accepted") offer.accept(Promise.resolve("branch"));
  fake.pi.events.emit(EVENT, offer);
  console.log(`${offer.accepted ? "accepted" : "declined"} ${await offer.settlement} ${entry.message}`);
}
process.exit(0);
JS

# run_driver <state-dir> <offers-json|malformed>: prints the driver's lines.
run_driver() {
  FM_STATE_OVERRIDE=$1 OFFERS=$2 MOOT_FAKE_PI="$MOOT_FAKE_PI" MOOT_EXT="$MOOT_FORK_EXT" \
    node "$DRIVER" 2>&1
}

new_state() {  # <name> -> a fresh state dir with the given name
  mkdir -p "$MTMP/$1/state"
  printf '%s' "$MTMP/$1/state"
}

ROW_BACKED_JSON='[
 {"message":"check: rearm-resurface"},
 {"message":"signal: /s/a.status /s/b.turn-ended"},
 {"message":"stale: default:wGQ:p2"},
 {"message":"heartbeat"},
 {"message":"heartbeat: 3 quiet cycles"}]'

test_row_backed_wakes_settle_when_the_queue_is_provably_empty() {
  local state out
  state=$(new_state empty)
  : > "$state/.wake-queue"
  out=$(run_driver "$state" "$ROW_BACKED_JSON")
  [ "$(printf '%s\n' "$out" | grep -c '^accepted default ')" = 5 ] \
    || fail "every row-backed wake kind must settle against a zero-byte queue: $out"
  [ "$(grep -c "settled	" "$state/.moot-wake.log")" = 5 ] \
    || fail "each settled wake leaves one log line: $(cat "$state/.moot-wake.log")"
  assert_contains "$(cat "$state/.moot-wake.log")" "settled	check: rearm-resurface" "the log names the wake"
  pass "a row-backed wake settles when the queue is readable and holds zero bytes"
}

test_any_queued_content_declines() {
  local state out kind
  for kind in valid blank invalid; do
    state=$(new_state "queued-$kind")
    case "$kind" in
      valid) moot_queue_row "$state" ;;
      blank) printf '\n' > "$state/.wake-queue" ;;
      invalid) printf 'not a queue row\n' > "$state/.wake-queue" ;;
    esac
    out=$(run_driver "$state" "$ROW_BACKED_JSON")
    [ "$(printf '%s\n' "$out" | grep -c '^declined default ')" = 5 ] \
      || fail "a queue holding a $kind row must decline every wake kind: $out"
    [ ! -e "$state/.moot-wake.log" ] || fail "a declined wake must leave no settle record ($kind)"
  done
  pass "a queue holding any content, even a blank or malformed line, declines so upstream delivers"
}

test_an_unprovable_queue_declines() {
  local state out
  state=$(new_state missing)
  out=$(run_driver "$state" '[{"message":"check: rearm-resurface"},{"message":"heartbeat"}]')
  [ "$(printf '%s\n' "$out" | grep -c '^declined default ')" = 2 ] \
    || fail "a missing queue is not proof of an empty one: $out"
  state=$(new_state unreadable)
  mkdir "$state/.wake-queue"
  out=$(run_driver "$state" '[{"message":"check: rearm-resurface"},{"message":"stale: default:w:p"}]')
  [ "$(printf '%s\n' "$out" | grep -c '^declined default ')" = 2 ] \
    || fail "an unreadable queue is not proof of an empty one: $out"
  pass "a missing or unreadable queue declines, so a doubt delivers the wake"
}

test_rows_less_wakes_and_alarms_are_never_settled() {
  local state out
  state=$(new_state rowsless)
  : > "$state/.wake-queue"
  out=$(run_driver "$state" '[
   {"message":"check: inactive-outcome"},
   {"message":"check: contributions: 2 new signals"},
   {"message":"check: process-event result captured: procevent:pr-green:38"},
   {"message":"check: rearm-resurface extra"},
   {"message":"watcher: FAILED - Pi extension could not verify a ready successor watcher"},
   {"message":"signals everywhere"},
   {"message":"heartbeats"},
   {"message":""}]')
  [ "$(printf '%s\n' "$out" | grep -c '^declined default ')" = 8 ] \
    || fail "wakes without a queue row and watcher-failure text must never settle: $out"
  [ ! -e "$state/.moot-wake.log" ] || fail "nothing settled, so nothing is logged"
  pass "rows-less wakes, near-miss prefixes, and watcher-failure alarms are never settled"
}

test_an_offer_another_listener_accepted_is_left_alone() {
  local state out
  state=$(new_state preaccepted)
  : > "$state/.wake-queue"
  out=$(run_driver "$state" '[{"message":"check: rearm-resurface","pre":"accepted"}]')
  assert_contains "$out" "accepted branch check: rearm-resurface" \
    "the branch's settlement must survive untouched"
  [ ! -e "$state/.moot-wake.log" ] || fail "an offer the branch took is not a settled wake"
  pass "an offer another listener already accepted keeps that listener's settlement"
}

test_malformed_offers_never_throw_into_the_upstream_offer() {
  local state out
  state=$(new_state malformed)
  : > "$state/.wake-queue"
  out=$(run_driver "$state" malformed)
  assert_equals "survived 7" "$out" "every malformed emission is survived"
  # A log that cannot be written must not change the outcome either.
  state=$(new_state logfail)
  : > "$state/.wake-queue"
  mkdir "$state/.moot-wake.log"
  out=$(run_driver "$state" '[{"message":"heartbeat"}]')
  assert_contains "$out" "accepted default heartbeat" "a failing log cannot veto a settlement"
  pass "malformed offers and an unwritable log never throw into the upstream offer"
}

test_the_settle_log_is_bounded() {
  local state i lines
  state=$(new_state bounded)
  : > "$state/.wake-queue"
  for i in $(seq 1 400); do
    printf '2026-11-03T00:00:00.000Z\tsettled\tstale: default:old%03d:p2 padding-padding-padding-padding\n' "$i"
  done > "$state/.moot-wake.log"
  [ "$(wc -c < "$state/.moot-wake.log")" -gt 32768 ] || fail "fixture log must start over the byte bound"
  run_driver "$state" '[{"message":"heartbeat"}]' >/dev/null
  lines=$(wc -l < "$state/.moot-wake.log" | tr -d ' ')
  [ "$lines" -le 200 ] || fail "the log must be trimmed to its bound, got $lines lines"
  assert_equals "heartbeat" "$(tail -1 "$state/.moot-wake.log" | cut -f3)" "the newest settle survives trimming"
  pass "the settle log trims to its bound and keeps the newest line"
}

test_the_listened_event_is_the_one_upstream_emits() {
  local out script="$MTMP/event-name.mjs"
  cat > "$script" <<'JS'
import { pathToFileURL } from "node:url";
const fork = await import(pathToFileURL(process.env.MOOT_EXT).href);
const upstream = await import(pathToFileURL(process.env.UPSTREAM_LIB).href);
console.log(fork.DISPATCH_EVENT === upstream.FM_BRANCH_DISPATCH_EVENT
  ? "same"
  : `drift ${fork.DISPATCH_EVENT} vs ${upstream.FM_BRANCH_DISPATCH_EVENT}`);
JS
  out=$(MOOT_EXT="$MOOT_FORK_EXT" UPSTREAM_LIB="$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" node "$script" 2>&1)
  assert_equals "same" "$out" "an upstream rename of the dispatch event must fail this suite"
  pass "the fork listens on exactly the event the upstream watch extension emits"
}

fork_run_tests
