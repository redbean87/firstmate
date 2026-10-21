#!/usr/bin/env bash
# Live drive of the durable owner-only creation change against the real product
# CLIs, from a deliberately OPEN caller umask (022, the defect condition) and a
# maximally open umask (000) for the drift check. Every assertion is on observed
# file modes plus the product's own read-back output.
set -u

ROOT=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M5F5DNEARND6JCZWPTKYNMGH
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-live.XXXXXX")
FAILED=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
inode() { stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"; }
pass() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
expect_mode() { # <path> <mode> <label>
  local got
  got=$(mode "$1" 2>/dev/null || echo missing)
  if [ "$got" = "$2" ]; then pass "$3 ($1 mode=$got)"; else bad "$3 (want $2, got $got: $1)"; fi
}
W="$ROOT/bin/fm-tasks-axi.sh"

printf '== worktree: %s\n== head: %s\n== caller umask: %s\n\n' \
  "$ROOT" "$(cd "$ROOT" && git rev-parse --short HEAD)" "$(umask)"

# --- 1. backlog: create + real rewrite under an open caller umask -------------
home="$TMP/backlog-home"
mkdir -p "$home/data" "$home/state"
out=$(umask 022; FM_HOME="$home" "$W" add ev-live-bl1 "Owner-only live backlog row" 2>&1) \
  || bad "backlog add failed: $out"
expect_mode "$home/data/backlog.md" 600 "backlog created under umask 022"
before=$(inode "$home/data/backlog.md")
out=$(umask 000; FM_HOME="$home" "$W" done ev-live-bl1 --note "closed live" 2>&1) \
  || bad "backlog done rewrite failed: $out"
[ "$(inode "$home/data/backlog.md")" != "$before" ] \
  && pass "the done transition really rewrote data/backlog.md (new inode)" \
  || bad "the done transition did not rewrite data/backlog.md"
expect_mode "$home/data/backlog.md" 600 "backlog after a real rewrite under umask 000"
show=$(FM_HOME="$home" "$W" show ev-live-bl1 2>&1) || bad "owner read-back failed: $show"
printf '%s\n' "$show" | grep -F 'ev-live-bl1' >/dev/null \
  && pass "the owner still reads the rewritten row back" \
  || bad "the owner could not read the row back: $show"

# --- 2. documented captain-hold flow under an open caller umask --------------
home="$TMP/hold-home"
mkdir -p "$home/data" "$home/state"
(umask 022; FM_HOME="$home" "$W" add ev-live-hold1 "Captain hold live row" >/dev/null 2>&1)
before=$(inode "$home/data/backlog.md")
out=$(umask 022; FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold ev-live-hold1 \
  --reason "live art. 2 captain hold" 2>&1) || bad "captain-hold hold failed: $out"
[ "$(inode "$home/data/backlog.md")" != "$before" ] \
  && pass "the captain hold really rewrote data/backlog.md" \
  || bad "the captain hold did not rewrite data/backlog.md"
expect_mode "$home/data/backlog.md" 600 "backlog after a documented captain hold (umask 022)"
show=$(FM_HOME="$home" "$W" show ev-live-hold1 2>&1)
printf '%s\n' "$show" | grep -F 'held: yes' >/dev/null \
  && pass "the held row still reports held: yes" \
  || bad "the held row lost its hold state: $show"
printf '%s\n' "$show" | grep -F 'live art. 2 captain hold' >/dev/null \
  && pass "the hold reason survives the rewrite" \
  || bad "the hold reason was lost: $show"

# --- 3. secondmate home seed under an open caller umask ----------------------
parent="$TMP/seed-parent"
child="$TMP/seed-child"
mkdir -p "$parent/data" "$parent/state" "$parent/projects"
out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" \
  FM_SECONDMATE_CHARTER='live owner-only charter' FM_SECONDMATE_SCOPE='live scope' \
  "$ROOT/bin/fm-home-seed.sh" live-sm "$child" --no-projects 2>&1) \
  || bad "fm-home-seed failed: $(printf '%s\n' "$out" | tail -n 3)"
expect_mode "$parent/data/secondmates.md" 600 "parent data/secondmates.md after seed"
expect_mode "$child/data/charter.md" 600 "seeded data/charter.md"
expect_mode "$child/data/projects.md" 600 "seeded data/projects.md"
for d in data state config; do
  expect_mode "$child/$d" 700 "seeded home $d/ directory"
done
# The deliberate exclusion: projects/ is NOT forced owner-only.
expect_mode "$child/projects" 755 "seeded projects/ keeps the caller-umask mode (documented exclusion)"
grep -F 'live owner-only charter' "$child/data/charter.md" >/dev/null \
  && pass "the seeded charter is readable by the owner" \
  || bad "the seeded charter is unreadable by the owner"

# --- 4. handoff then receive under an open caller umask ----------------------
id=live-sm
key=ev-live-handoff1
out=$(umask 022; FM_HOME="$parent" "$W" add "$key" "handoff live row" 2>&1) \
  || bad "seeding the handoff row failed: $out"
before=$(inode "$parent/data/backlog.md")
out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$parent" \
  "$ROOT/bin/fm-backlog-handoff.sh" "$id" "$key" 2>&1) || true
printf '%s\n' "$out" | grep -F "handed off 1 item(s) to $id: $key" >/dev/null \
  && pass "the documented handoff reported the staged move" \
  || bad "the handoff did not report the staged move: $out"
[ "$(inode "$parent/data/backlog.md")" != "$before" ] \
  && pass "the handoff really rewrote the parent backlog" \
  || bad "the handoff did not rewrite the parent backlog"
expect_mode "$parent/data/backlog.md" 600 "parent backlog after a real handoff"
expect_mode "$child/data/backlog.md" 600 "handed-off destination backlog"
grep -F "$key" "$child/data/backlog.md" >/dev/null \
  && pass "the destination owns the handed-off row" \
  || bad "the handed-off row is missing from the destination"

# A second, locally-staged delivery goes through the receive path.
rkey=ev-live-recv1
mkdir -p "$child/state/handoff"
printf '## Queued\n\n- [ ] %s - delivered live row (repo: %s)\n' "$rkey" "$id" \
  > "$child/state/handoff/$id.outbox.md"
bytes=$(LC_ALL=C wc -c < "$child/state/handoff/$id.outbox.md" | tr -d ' ')
hash=$(shasum -a 256 "$child/state/handoff/$id.outbox.md" | awk '{print $1}')
printf '1\n%s\n%s\n' "$bytes" "$hash" > "$child/state/handoff/.$id.upload-generation"
before=$(inode "$child/data/backlog.md")
out=$(umask 022; FM_ROOT_OVERRIDE='' FM_HOME="$child" \
  "$ROOT/bin/fm-backlog-receive.sh" "state/handoff/$id.outbox.md" "$bytes" "$hash" 1 2>&1) \
  || bad "backlog receive failed: $out"
printf '%s\n' "$out" | grep -F 'moved=1' >/dev/null \
  && pass "the receive reported the delivered move" \
  || bad "the receive did not report the move: $out"
[ "$(inode "$child/data/backlog.md")" != "$before" ] \
  && pass "the receive really rewrote the destination backlog" \
  || bad "the receive did not rewrite the destination backlog"
expect_mode "$child/data/backlog.md" 600 "destination backlog after a real receive"
grep -F "$rkey" "$child/data/backlog.md" >/dev/null \
  && pass "the delivered row landed in the destination backlog" \
  || bad "the delivered row did not land: $(tail -n 5 "$child/data/backlog.md")"
grep -F "$key" "$child/data/backlog.md" >/dev/null \
  && pass "the receive preserved the destination's existing rows" \
  || bad "the receive dropped the destination's existing rows"

# --- 5. watcher family under an open caller umask ---------------------------
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || bad "could not mint the lab home"
mkdir -p "$lab/tmux"
fakebin=$(mktemp -d "${TMPDIR:-/tmp}/fm-fakebin.XXXXXX")
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/gh"; chmod +x "$fakebin/gh"
( umask 022
  PATH="$fakebin:$PATH" FM_HOME="$lab" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$TMP/watch.out" 2>&1 & echo $! > "$TMP/watch.pid" )
wpid=$(cat "$TMP/watch.pid")
i=0
while [ "$i" -lt 80 ]; do
  [ "$(cat "$lab/state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] \
    && [ -e "$lab/state/.last-watcher-beat" ] && break
  sleep 0.1; i=$((i + 1))
done
if [ "$(cat "$lab/state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ]; then
  pass "the real watcher started against a lab home under umask 022"
  expect_mode "$lab/state/.watch.lock" 700 "watcher lock owner dir (symlink target)"
  expect_mode "$lab/state/.last-watcher-beat" 600 "watcher beat"
  [ "$(mode "$lab/state/.watch.lock/pid")" = 600 ] \
    && pass "watcher lock pid record is 600" \
    || bad "watcher lock pid record is $(mode "$lab/state/.watch.lock/pid")"
else
  bad "the watcher did not start: $(tail -n 3 "$TMP/watch.out" 2>/dev/null)"
fi
kill "$wpid" 2>/dev/null || true
i=0; while [ "$i" -lt 50 ] && kill -0 "$wpid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
wait "$wpid" 2>/dev/null || true
rm -rf "$lab" "$fakebin"

printf '\n== overall: %s\n' "$([ "$FAILED" -eq 0 ] && echo ALL-PASS || echo FAILURES)"
exit "$FAILED"
