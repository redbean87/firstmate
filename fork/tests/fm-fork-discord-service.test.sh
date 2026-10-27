#!/usr/bin/env bash
# Service readiness of the fork Discord bridge: stop/status decided by the run
# lock (never a pid file alone), log rotation, the content-addressed release
# tool (fork/bin/fm-discord-release), the reviewed LaunchAgent plist, and the
# release launcher under a supervisor that restarts only after an unexpected
# exit - all in disposable homes against the fake Discord API. Nothing here
# loads a launchd job: launchd's own KeepAlive and ExitTimeOut handling is
# exercised only by the separately authorized activation.
set -u
# shellcheck source=fork/tests/discord-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/discord-lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

RELEASE_TOOL="$ROOT/fork/bin/fm-discord-release"
QUIET_HEALTH=(DISCORD_WATCHER_STALE_SECS=999999999)

wait_for() {  # <seconds> <command...>
  local n=$(( $1 * 10 ))
  shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
log_has() { grep -c "\"event\": \"$1\"" "$W_HOME/state/discord-bridge/bridge.log" 2>/dev/null | grep -qx "${2:-1}"; }
mode_of() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
alive() { kill -0 "$1" 2>/dev/null; }

test_stop_and_status_trust_only_the_run_lock() {
  local bystander run_pid out rc
  discord_world svclock
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}")
  bridge tick >/dev/null 2>&1 || fail "first bridge pass failed"
  sleep 60 & bystander=$!
  # A released lock whose pid file names a live, unrelated process.
  printf '%s' "$bystander" > "$W_HOME/state/discord-bridge/bridge.lock"
  assert_contains "$(bridge status)" "bridge: not running" "a stale pid with a free lock is not a running bridge"
  out=$(bridge stop); rc=$?
  expect_code 0 "$rc" "stop with no bridge succeeds"
  assert_contains "$out" "not running" "stop says nothing is running"
  alive "$bystander" || fail "stop must never signal a pid the lock does not prove"

  D_EXEC=1 bridge run --no-gateway 2>/dev/null & run_pid=$!
  wait_for 15 log_has bridge-started || fail "the bridge did not start"
  assert_contains "$(bridge status)" "bridge: running (pid $run_pid)" "a held lock reports its holder"
  out=$(bridge run --no-gateway 2>&1); rc=$?
  expect_code 1 "$rc" "a second instance is refused"
  assert_contains "$out" "already running" "the refusal is named"
  alive "$run_pid" || fail "the refused second instance leaves the first running"
  bridge stop >/dev/null
  wait "$run_pid"; rc=$?
  expect_code 0 "$rc" "stop ends the holder cleanly"
  log_has bridge-stopped || fail "the stop is logged"
  assert_contains "$(bridge status)" "bridge: not running" "after a stop the lock is free"
  alive "$bystander" || fail "the bystander is still untouched"
  kill "$bystander" 2>/dev/null
  pass "lifecycle: status and stop decide by the run lock; a stale pid is never signalled; a second instance is refused"
}

test_log_rotates_at_the_limit_and_stays_private() {
  local log
  discord_world svclog
  D_EXTRA_ENV=("${QUIET_HEALTH[@]}" FM_DISCORD_BRIDGE_LOG_MAX=2000)
  bridge tick >/dev/null 2>&1 || fail "first bridge pass failed"
  log="$W_HOME/state/discord-bridge/bridge.log"
  python3 -c 'print("x" * 2500)' > "$log"
  chmod 600 "$log"
  bridge ingest "$(owner_event 700000000000000081 "refused here" 320000000000000032)" >/dev/null
  [ "$(wc -c < "$log.1" | tr -d ' ')" = 2501 ] || fail "the full log moves to bridge.log.1 unchanged"
  [ "$(grep -c 'inbound-refused' "$log")" = 1 ] || fail "the new line starts a fresh log"
  [ "$(mode_of "$log")" = 600 ] && [ "$(mode_of "$log.1")" = 600 ] || fail "both logs stay owner-only: $(mode_of "$log") $(mode_of "$log.1")"
  bridge ingest "$(owner_event 700000000000000082 "refused here" 320000000000000032)" >/dev/null
  [ "$(grep -c 'inbound-refused' "$log")" = 2 ] || fail "a small log is appended, not rotated"
  python3 -c 'print("y" * 2500)' >> "$log"
  bridge ingest "$(owner_event 700000000000000083 "refused here" 320000000000000032)" >/dev/null
  assert_grep 'yyyy' "$log.1" "a second rotation replaces the older copy"
  assert_no_grep 'xxxx' "$log.1" "only one older copy is kept"
  pass "log rotation: at the limit bridge.log moves to bridge.log.1, both 0600, one older copy kept"
}

# release_src: a fixture checkout with a committed bin/ and untracked bridge
# files, as in the real repository; sets REL_SRC.
release_src() {
  REL_SRC="$DTMP/$1/src"
  mkdir -p "$REL_SRC/bin" "$REL_SRC/fork/discord/extension"
  printf '#!/bin/sh\necho fixture\n' > "$REL_SRC/bin/fm-procevent.sh"
  printf 'fixture lib\n' > "$REL_SRC/bin/fm-env-lib.sh"
  git -C "$REL_SRC" init -q
  git -C "$REL_SRC" add bin
  git -C "$REL_SRC" -c user.email=t@example.invalid -c user.name=t commit -q -m fixture
  local f
  for f in fm-discord-bridge.py fm-discord-send.sh fm-discord-lib.sh fm-discord-reply-hook.sh fm-discord-service README \
           extension/firstmate-extension.json extension/fm-discord-inbound.mjs; do
    cp "$ROOT/fork/discord/$f" "$REL_SRC/fork/discord/$f"
  done
  printf 'DISCORD_BOT_TOKEN=%s\n' "$D_TOKEN" > "$REL_SRC/.env"
  mkdir -p "$REL_SRC/state/discord-bridge" && : > "$REL_SRC/state/discord-bridge/bridge.log"
}

test_release_tool_builds_verifies_switches_and_refuses() {
  local dep id1 id2 out rc
  release_src reltool
  dep="$DTMP/reltool/deploy"
  id1=$("$RELEASE_TOOL" build "$REL_SRC" "$dep") || fail "build failed"
  [[ "$id1" =~ ^[0-9a-f]{16}$ ]] || fail "the id is 16 hex digits: $id1"
  assert_absent "$dep/current" "build never switches current"
  "$RELEASE_TOOL" verify "$dep" "$id1" >/dev/null || fail "a fresh release verifies"
  [ "$(cd "$dep/releases/$id1" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" \
    = "./MANIFEST.sha256 ./RELEASE ./bin/fm-env-lib.sh ./bin/fm-procevent.sh ./fork/discord/README ./fork/discord/extension/firstmate-extension.json ./fork/discord/extension/fm-discord-inbound.mjs ./fork/discord/fm-discord-bridge.py ./fork/discord/fm-discord-lib.sh ./fork/discord/fm-discord-reply-hook.sh ./fork/discord/fm-discord-send.sh ./fork/discord/fm-discord-service " ] \
    || fail "the release holds exactly bin/ and the bridge files: $(cd "$dep/releases/$id1" && find . -type f | sort)"
  [ -z "$(find "$dep/releases/$id1" -perm -u+w)" ] || fail "the release is read-only"
  assert_no_grep "$D_TOKEN" "$dep/releases/$id1/MANIFEST.sha256" "no secret reaches the release"
  assert_contains "$(cat "$dep/releases/$id1/RELEASE")" "bin from git $(git -C "$REL_SRC" rev-parse HEAD)" "RELEASE names the bin/ commit"
  assert_contains "$(cat "$dep/releases/$id1/RELEASE")" "at git $(git -C "$REL_SRC" rev-parse HEAD) (modified)" "RELEASE marks fork/discord files that are not committed at that commit"
  "$RELEASE_TOOL" switch "$dep" "$id1" >/dev/null || fail "switch failed"
  [ "$(readlink "$dep/current")" = "releases/$id1" ] || fail "current points at the release"

  out=$("$RELEASE_TOOL" build "$REL_SRC" "$dep" 2>&1)
  assert_contains "$out" "already exists; left unchanged" "equal content is the same release"
  [ "$(printf '%s\n' "$out" | tail -n 1)" = "$id1" ] || fail "and the same id"

  printf '\n# changed\n' >> "$REL_SRC/fork/discord/README"
  id2=$("$RELEASE_TOOL" build "$REL_SRC" "$dep" 2>/dev/null) || fail "second build failed"
  [ "$id2" != "$id1" ] || fail "changed content gives a new id"
  [ "$(readlink "$dep/current")" = "releases/$id1" ] || fail "building a new release leaves current alone"
  "$RELEASE_TOOL" switch "$dep" "$id2" >/dev/null || fail "switch forward"
  "$RELEASE_TOOL" switch "$dep" "$id1" >/dev/null || fail "switch back"
  [ "$(readlink "$dep/current")" = "releases/$id1" ] || fail "rollback restores the earlier release"
  "$RELEASE_TOOL" verify "$dep" "$id2" >/dev/null || fail "older and newer releases both stay intact"
  assert_contains "$("$RELEASE_TOOL" list "$dep")" "* $id1" "list marks current"

  printf 'edited\n' >> "$REL_SRC/bin/fm-env-lib.sh"
  out=$("$RELEASE_TOOL" build "$REL_SRC" "$dep" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an uncommitted bin/ change is refused"
  assert_contains "$out" "bin/ differs from HEAD" "the refusal is named"
  git -C "$REL_SRC" checkout -q -- bin
  : > "$REL_SRC/bin/untracked-helper"
  "$RELEASE_TOOL" build "$REL_SRC" "$dep" >/dev/null 2>&1 && fail "an untracked bin/ file is refused too"
  rm "$REL_SRC/bin/untracked-helper"
  mv "$REL_SRC/fork/discord/fm-discord-service" "$DTMP/reltool/service.aside"
  out=$("$RELEASE_TOOL" build "$REL_SRC" "$dep" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a missing bridge file is refused"
  [ -z "$(find "$dep" -maxdepth 1 -name '.stage.*')" ] || fail "a failed build leaves no stage behind"
  [ "$(find "$dep/releases" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 2 ] || fail "a failed build adds no release"

  chmod u+w "$dep/releases/$id2/fork/discord" "$dep/releases/$id2/fork/discord/README"
  printf 'tampered\n' >> "$dep/releases/$id2/fork/discord/README"
  out=$("$RELEASE_TOOL" verify "$dep" "$id2" 2>&1) && fail "a changed file fails verification"
  assert_contains "$out" "files differ from the manifest" "the tampering is named"
  "$RELEASE_TOOL" switch "$dep" "$id2" >/dev/null 2>&1 && fail "switch refuses a release that does not verify"
  [ "$(readlink "$dep/current")" = "releases/$id1" ] || fail "a refused switch leaves current alone"
  chmod -R u+w "$dep"  # let the test root be cleaned up
  pass "release tool: content-addressed read-only releases of bin/@HEAD and the bridge files only; same content same id; switch and rollback are atomic and verified; dirty bin/, missing files, and tampering are refused"
}

test_launchd_plist_is_the_reviewed_agent() {
  local plist dep
  discord_world svcplist
  dep="$DTMP/svcplist/deploy"
  plist="$DTMP/svcplist/agent.plist"
  bridge launchd-plist --deploy "$dep" > "$plist" || fail "the plist was not printed"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "plutil rejects the plist"
  fi
  python3 - "$plist" "$dep" "$W_HOME" <<'EOF' || fail "the plist is not the reviewed agent"
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb")); dep, home = sys.argv[2], sys.argv[3]
assert p["Label"] == "org.firstmate.fork.discord-bridge", p["Label"]
assert p["ProgramArguments"] == [dep + "/current/fork/discord/fm-discord-service"], p["ProgramArguments"]
assert p["EnvironmentVariables"] == {"FM_HOME": home}, p["EnvironmentVariables"]
assert p["KeepAlive"] == {"SuccessfulExit": False}, p["KeepAlive"]
assert p["RunAtLoad"] is True and p["ThrottleInterval"] == 60 and p["ExitTimeOut"] == 75 and p["Umask"] == 0o077
assert p["StandardOutPath"] == p["StandardErrorPath"] == home + "/state/discord-bridge/launchd.log"
assert "UserName" not in p and "GroupName" not in p
EOF
  assert_no_grep "$D_TOKEN" "$plist" "the plist carries no secret"
  pass "LaunchAgent plist: valid, reviewed label, release launcher, FM_HOME only, restart only after an unexpected exit, 75s stop timeout, private umask, logs in the home"
}

# --- the release launcher under a KeepAlive-like supervisor -----------------

# supervise <launcher> <events-file> <args...>: run the launcher, restart it
# after any non-zero or signal exit (as KeepAlive {SuccessfulExit: false}
# does), stop after a clean exit. Writes "start <pid>" and "exit <code>".
supervise() {
  local launcher=$1 events=$2 pid rc
  shift 2
  while :; do
    "$launcher" "$@" 2>>"$events.err" & pid=$!
    printf 'start %s\n' "$pid" >> "$events"
    wait "$pid"; rc=$?
    printf 'exit %s\n' "$rc" >> "$events"
    [ "$rc" -eq 0 ] && return 0
    sleep 1
  done
}
starts() { grep -c '^start ' "$1" 2>/dev/null || true; }
starts_are() { [ "$(starts "$1")" = "$2" ]; }  # <events> <n>, re-read on every call
ops_posts_are() { [ "$(post_count "$D_OPS")" = "$1" ]; }
pr_ready_posted() { posts "$D_OPS" | grep -q "PR ready for review - svc-test"; }
last_start() { sed -n 's/^start //p' "$1" | tail -n 1; }

test_release_launcher_survives_crashes_stops_cleanly_and_replays_nothing() {
  local dep id launcher events sup p1 p2 out rc env_file
  discord_world svcrun
  dep="$DTMP/svcrun/deploy"
  id=$("$RELEASE_TOOL" build "$ROOT" "$dep") || fail "building a release of this checkout failed"
  "$RELEASE_TOOL" switch "$dep" "$id" >/dev/null || fail "switch failed"
  launcher="$dep/current/fork/discord/fm-discord-service"
  env_file="$W_HOME/.env"
  ( umask 077
    printf '%s\n' "DISCORD_BOT_TOKEN=$D_TOKEN" "DISCORD_GUILD_ID=$D_GUILD" "DISCORD_OWNER_USER_ID=$D_OWNER" \
      "DISCORD_COMMAND_CHANNEL_IDS=$D_CMD" "DISCORD_REPLIES_CHANNEL_ID=$W_REPLIES" "DISCORD_OPERATIONS_CHANNEL_ID=$D_OPS" \
      "DISCORD_API_BASE=https://discord.test/api/v10" "DISCORD_WATCHER_STALE_SECS=999999999" > "$env_file" )
  : > "$W_HOME/config/fleet-ledger"
  fresh_beat  # monitoring is running, so no health notice joins the count
  events="$DTMP/svcrun/supervisor.events"
  export FM_HOME="$W_HOME" FM_DISCORD_PYTHON FM_DISCORD_TEST_PATH="$D_FAKEBIN" FAKE_DISCORD_DIR="$W_FAKE"
  FM_DISCORD_PYTHON=$(command -v python3)
  supervise "$launcher" "$events" --no-gateway & sup=$!
  # shellcheck disable=SC2064 # stop this test's own supervisor and bridge only
  trap "kill $sup 2>/dev/null; p=\$(last_start '$events'); [ -n \"\$p\" ] && kill \$p 2>/dev/null" EXIT

  wait_for 20 log_has bridge-started || fail "the service did not start: $(cat "$events.err" 2>/dev/null)"
  p1=$(last_start "$events")
  ps -o command= -p "$p1" | grep -q "$dep/releases/$id/fork/discord/fm-discord-bridge.py run" \
    || fail "the bridge runs from the physical release path: $(ps -o command= -p "$p1")"
  assert_contains "$(bridge status)" "running (pid $p1)" "status names the service's pid"
  [ "$(mode_of "$W_HOME/state/discord-bridge/bridge.log")" = 600 ] || fail "the service's log is owner-only"

  FM_HOME="$W_HOME" "$LEDGER" pr_ready svc-test https://example.com/svc-test
  wait_for 20 pr_ready_posted || fail "the service delivers operations notices"
  ops_posts_are 1 || fail "exactly one operations notice: $(posts "$D_OPS")"
  [ "$(bridge ingest "$(owner_event 710000000000000001 "queued before the crash")")" = accepted ] || fail "an owner message is accepted"

  kill -KILL "$p1"
  wait_for 20 starts_are "$events" 2 || fail "an unexpected exit is restarted"
  wait_for 20 log_has bridge-started 2 || fail "the restarted bridge started"
  p2=$(last_start "$events")
  [ "$p2" != "$p1" ] || fail "a new process replaced the killed one"
  assert_contains "$(bridge status)" "running (pid $p2)" "the restarted bridge holds the lock"
  sleep 3
  [ "$(post_count "$D_OPS")" = 1 ] || fail "nothing delivered before the crash is sent again"
  [ "$(pending_ids_svc)" = "710000000000000001 " ] || fail "the inbox keeps its one message: $(pending_ids_svc)"
  printf '%s\n' "$(jq -cn --arg o "$D_OWNER" '[{id: "710000000000000001", type: 0, content: "queued before the crash", author: {id: $o}}]')" \
    > "$W_FAKE/get/_channels_${D_CMD}_messages_after_710000000000000000_limit_100.json"
  printf '{"after":"710000000000000000"}\n' > "$W_HOME/state/discord-bridge/cursors/inbound-$D_CMD.json"
  bridge recover-history || fail "history recovery after the restart failed"
  [ "$(pending_ids_svc)" = "710000000000000001 " ] || fail "recovery replays nothing already accepted"
  assert_grep '"event": "inbound-duplicate"' "$W_HOME/state/discord-bridge/bridge.log" "recovery sees it as a duplicate"

  out=$("$launcher" --no-gateway 2>&1); rc=$?
  expect_code 1 "$rc" "a second service instance is refused"
  assert_contains "$out" "already running" "the refusal is named"
  alive "$p2" || fail "the running service is untouched"

  bridge stop >/dev/null
  wait_for 20 grep -qx 'exit 0' "$events" || fail "a deliberate stop exits 0: $(cat "$events")"
  wait "$sup"; rc=$?
  expect_code 0 "$rc" "the supervisor stops after a clean exit"
  [ "$(starts "$events")" = 2 ] || fail "a clean exit is not restarted"
  assert_contains "$(bridge status)" "bridge: not running" "nothing runs after the stop"
  trap - EXIT
  chmod -R u+w "$dep"
  pass "service: the release launcher runs the physical release, restarts after a crash, delivers nothing twice, recovery replays nothing, refuses a second instance, and stays stopped after a clean exit"
}
pending_ids_svc() { find "$W_HOME/state/discord-bridge/inbox/pending" -type f -name '*.json' | sed 's#.*/##; s#\.json$##' | sort | tr '\n' ' '; }

fork_run_tests
