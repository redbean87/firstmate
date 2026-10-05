#!/usr/bin/env bash
# tests/fm-wake-drain-discord-relay.test.sh - executable regressions for the
# Discord relay seam in bin/fm-wake-drain.sh. The drain relays each
# captain-relevant item it presents (BRANCH OUTCOMES captain rows, keyed OPEN
# DECISIONS, and backstop sightings) through bin/fm-discord-notify.sh, reusing
# the branch append path's own class and logical event key via
# bin/fm-branch-outcome.sh notify-event. These tests drive the real drain and
# assert on the recorded Discord posts and the drain's notify log, not on the
# scripts' source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-discord-relay-tests)

fake_curl() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=""
posted=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -D)
      # discord_api reads Retry-After from the header dump; keep it readable.
      : > "$2"
      shift 2 ;;
    -m|-H|-X|-w) shift 2 ;;
    -s) shift ;;
    --data-binary)
      case "$2" in @*) posted=$(cat -- "${2#@}") ;; *) posted=$2 ;; esac
      shift 2 ;;
    http://*|https://*|file://*) shift ;;
    *) shift ;;
  esac
done
[ -z "$ofile" ] || printf '%s' "${FAKE_HTTP_BODY:-{\"id\":\"m1\"}}" > "$ofile"
if [ -n "${FAKE_POST_DIR:-}" ] && [ -n "$posted" ]; then
  d=$(mktemp "$FAKE_POST_DIR/post.XXXXXX") && chmod 600 "$d" && printf '%s' "$posted" > "$d"
fi
printf '%s' "${FAKE_HTTP_CODE:-200}"
exit 0
SH
  chmod +x "$fakebin/curl"
}

make_relay_case() {  # <name> -> prints case dir with .env + supervision-host + posts
  local name=$1 dir fakebin
  dir=$(make_case "$name")
  fakebin="$dir/fakebin"
  fake_curl "$fakebin"
  mkdir -p "$dir/config" "$dir/posts"
  : > "$dir/config/supervision-host"
  printf 'DISCORD_CHANNEL_ID=c1\n' > "$dir/.env"
  printf '%s\n' "$dir"
}

write_discord_env() {  # <dir>
  cat > "$1/.env" <<'EOF'
DISCORD_CLIENT_ID=cid
DISCORD_CLIENT_SECRET=sec
DISCORD_BOT_TOKEN=tok1234567890
DISCORD_GUILD_ID=g1
DISCORD_OWNER_USER_ID=u9
DISCORD_CHANNEL_ID=c1
EOF
}

run_drain() {  # <dir> <outfile>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_TEST_SEAM=1 FM_TEST_HARNESS=claude FAKE_POST_DIR="$dir/posts" \
    FM_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$out" 2>&1
}

post_count() {  # <dir>
  find "$1/posts" -maxdepth 1 -type f -name 'post.*' 2>/dev/null | wc -l | tr -d ' '
}

wait_for_posts() {  # <dir> <min>
  local dir=$1 min=$2 i=0
  while [ "$i" -lt 50 ]; do
    [ "$(post_count "$dir")" -ge "$min" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_log() {  # <dir> <pattern>
  local dir=$1 pattern=$2 i=0
  while [ "$i" -lt 50 ]; do
    grep -F "$pattern" "$dir/state/.wake-drain-notify.log" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

relsq() {  # <dir> <task> <summary>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$OUTCOMES" append \
    --task "$2" --verdict captain --summary "$3" >/dev/null
}

test_keyed_open_decision_notifies_and_unkeyed_stays_residual() {
  local dir out
  dir=$(make_relay_case keyed-decision)
  write_discord_env "$dir"
  # A keyed decision uses the tap's decision namespace; an unkeyed one has no
  # identity the branch append path can reproduce, so it is a residual gap.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$dir/state/ship-a.status"
  printf 'needs-decision: pick a name for the service\n' > "$dir/state/ship-b.status"

  run_drain "$dir" "$dir/out" || fail "drain failed on keyed and keyless decisions"
  grep -F 'OPEN DECISIONS' "$dir/out" >/dev/null || fail "open decisions section missing"
  wait_for_posts "$dir" 1 || fail "keyed decision produced no Discord post"
  [ "$(post_count "$dir")" = 1 ] || fail "keyed decision posted $(post_count "$dir") times, expected once"
  grep -F 'decision-ship-a-api-shape' "$dir/state/.wake-drain-notify.log" >/dev/null \
    || fail "keyed decision did not use the decision-<task>-<key> marker"
  grep -F '<@u9>' "$dir/posts"/post.* >/dev/null || fail "post did not mention the owner"
  wait_for_log "$dir" 'residual gap' || fail "unkeyed decision was not logged as a residual gap"

  run_drain "$dir" "$dir/out2" || fail "second drain failed"
  sleep 0.5
  [ "$(post_count "$dir")" = 1 ] || fail "re-presented keyed decision double-posted"
  pass "a keyed open decision pings under its decision key; an unkeyed one is a logged residual gap"
}

test_store_rows_relay_with_store_keys_once() {
  local dir out
  dir=$(make_relay_case store-rows)
  # Append before the Discord env exists, so only the drain's relay can send:
  # this isolates the drain seam from the append-time tap.
  relsq "$dir" ship-x 'PR ready for review: https://example.com/pr/9'
  relsq "$dir" ship-x 'needs-decision [key=shape]: pick A or B'
  write_discord_env "$dir"

  run_drain "$dir" "$dir/out" || fail "drain failed with store rows"
  grep -F 'BRANCH OUTCOMES' "$dir/out" >/dev/null || fail "branch outcomes section missing"
  wait_for_posts "$dir" 2 || fail "store captain rows did not both post (got $(post_count "$dir"))"
  grep -F 'branch-outcome-ship-x-completion-' "$dir/state/.wake-drain-notify.log" >/dev/null \
    || fail "completion row did not use the branch-outcome content key"
  grep -F 'decision-ship-x-shape' "$dir/state/.wake-drain-notify.log" >/dev/null \
    || fail "keyed decision row did not use the decision-key marker"

  run_drain "$dir" "$dir/out2" || fail "second drain failed"
  sleep 0.5
  [ "$(post_count "$dir")" = 2 ] || fail "re-presented store rows double-posted (got $(post_count "$dir"))"
  pass "store captain rows relay under the append path's own keys and only once"
}

test_failed_send_releases_marker_for_a_later_drain() {
  local dir
  dir=$(make_relay_case retry)
  write_discord_env "$dir"
  printf 'needs-decision [key=retry-key]: decide now\n' > "$dir/state/ship-r.status"

  FAKE_HTTP_CODE=400 run_drain "$dir" "$dir/out" || true
  wait_for_log "$dir" 'failed' || fail "failed send was not logged"
  [ "$(post_count "$dir")" = 1 ] || fail "failed send did not record an attempt"
  [ -e "$dir/state/discord-notify/decision-ship-r-retry-key" ] \
    && fail "failed send stranded its dedup marker"

  FAKE_HTTP_CODE='' run_drain "$dir" "$dir/out2" || fail "retry drain failed"
  wait_for_posts "$dir" 2 || fail "retry after a failed send did not deliver"
  [ -e "$dir/state/discord-notify/decision-ship-r-retry-key" ] \
    || fail "delivered retry did not hold its marker"
  pass "a failed relay releases its marker so the next drain retries"
}

test_non_captain_statuses_never_notify() {
  local dir
  dir=$(make_relay_case silent-statuses)
  write_discord_env "$dir"
  printf 'working: rebased onto merged #76\n' > "$dir/state/w.status"
  printf 'resolved [key=old]: answered earlier\n' > "$dir/state/r.status"
  printf 'paused: waiting for the release window\n' > "$dir/state/p.status"
  printf 'blocked: release credential unavailable\n' > "$dir/state/b.status"
  printf 'needs-decision: choose REST or RPC\n' > "$dir/state/d.status"
  relsq "$dir" quiet-task 'routine progress, nothing new'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$OUTCOMES" append \
    --task quiet-task --verdict routine --silent true --summary 'no-change note' >/dev/null

  run_drain "$dir" "$dir/out" || fail "drain failed on non-captain statuses"
  sleep 0.7
  [ "$(post_count "$dir")" = 0 ] || fail "non-captain statuses posted $(post_count "$dir") times"
  pass "working, resolved, paused, keyless blockers, and routine or silent rows never notify"
}

test_keyed_open_decision_notifies_and_unkeyed_stays_residual
test_store_rows_relay_with_store_keys_once
test_failed_send_releases_marker_for_a_later_drain
test_non_captain_statuses_never_notify
