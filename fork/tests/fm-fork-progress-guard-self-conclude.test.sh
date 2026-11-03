#!/usr/bin/env bash
# Capture self-conclusion: a progress-stall capture whose own task is already
# concluded by the time the capture is read - its task record state/<id>.meta
# gone, or its last status line a terminal done/failed declaration - is
# recorded handled without a wake, so a moot advisory is never presented and
# never re-delivered, and a conclusion that lands between capture and read
# concludes the capture at read time. The live direction is pinned beside it:
# an advisory for a live task still declaring working keeps its wake and its
# re-announcement, and every doubt - an unreadable status file, a missing home
# reference, non-advisory content - keeps the wake too.
#
# Side cases drive the shipped entrypoint's result.silent verdict directly.
# The end-to-end cases bind the real package and drive the REAL
# bin/fm-extension.mjs and bin/fm-procevent.sh: capture while the task is
# live, conclude the task, then let the runner's next read of that capture
# self-conclude it. No test contacts a network, a live fleet, or the running
# session's own home.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/progress-guard/extension"
ENTRY="$PKG_SRC/fm-progress-guard.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"

PTMP=$(fm_test_tmproot fm-fork-progress-guard-self-conclude)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

# One advisory body exactly as the real seam writes it - four lines, opening
# with the header the self-conclusion parses - for one task.
advisory() {  # <task-id>
  printf 'PROGRESS STALL (advisory): task %s has produced no new evidence for 25m (threshold 25m).\n' "$1"
  printf 'last status line: working [at=1793000000]: building the guard (25m ago)\n'
  printf 'newest evidence: /tmp/%s/report.md (25m ago)\n' "$1"
  printf 'sources: status /tmp/%s.status (25m ago); worktree /tmp/%s (25m ago); data /tmp/%s (25m ago)\n' "$1" "$1" "$1"
  printf 'Advisory evidence that this worker may be stuck; not a decision, an instruction, or authority to steer, stop, or answer anything.\n'
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

record() {  # <home> <id> <key=value>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

# --- side verdicts through the shipped entrypoint ---------------------------

# verdict_request <content> [config-ref]: one well-formed result.silent
# invocation; the optional second argument attaches the home reference the
# host's HK7 block supplies on the real path.
verdict_request() {
  local c=$1 ref=${2-}
  jq -cn --arg c "$c" --arg ref "$ref" \
    --arg rid "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    '{schema: "firstmate.extension-request.v1", request_id: $rid,
      host_protocol: 1, extension_id: "org.firstmate.fork.progress-guard",
      extension_version: "0.1.0",
      package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      capability: "process-event-adapter", capability_version: 1, adapter: "progress-guard",
      operation: "result.silent",
      input: (if $ref == "" then {source_id: "progress-guard", sequence: 1, content: $c}
              else {source_id: "progress-guard", sequence: 1, content: $c, config_ref: $ref} end)}'
}

verdict() {  # <content> [config-ref] -> prints true|false
  verdict_request "$1" "${2-}" | node "$ENTRY" invoke | jq -r '.result.value'
}

test_a_gone_task_record_concludes_its_capture() {
  local home out
  home="$PTMP/side-gone/home"
  p_home "$home"
  # No task record: the verdict must conclude from the gone record alone.
  out=$(verdict "$(advisory green-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose task record is gone must conclude, got: $out"
  pass "side: a capture whose task record is gone concludes"
}

test_a_terminal_status_line_concludes_its_capture_while_the_record_exists() {
  local home out
  home="$PTMP/side-terminal/home"
  p_home "$home"
  record "$home" done-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4600.7
  printf 'done [at=1793000500]: shipped it\n' > "$home/state/done-ship.status"
  out=$(verdict "$(advisory done-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose task declared done must conclude, got: $out"

  printf 'failed [at=1793000600]: the build broke\n' > "$home/state/done-ship.status"
  out=$(verdict "$(advisory done-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose task declared failed must conclude, got: $out"
  pass "side: a capture whose last status line is terminal done/failed concludes while its record still exists"
}

test_a_live_task_or_any_doubt_keeps_the_wake() {
  local home out
  home="$PTMP/side-live/home"
  p_home "$home"
  record "$home" live-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4601.7
  printf 'working [at=1793000000]: building the guard\n' > "$home/state/live-ship.status"
  out=$(verdict "$(advisory live-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a live task still declaring working must keep its wake, got: $out"

  # An existing record behind an unreadable status file is doubt, not proof.
  rm -f "$home/state/live-ship.status"
  out=$(verdict "$(advisory live-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "an unreadable status file must keep the wake, got: $out"

  # A declared pause is not a conclusion: the task still exists and waits.
  printf 'paused [at=1793000100]: waiting for the window\n' > "$home/state/live-ship.status"
  out=$(verdict "$(advisory live-ship)" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a paused task must keep the wake of its earlier capture, got: $out"

  # No home reference (an older host) keeps the wake, exactly as before.
  out=$(verdict "$(advisory live-ship)") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a capture without a home reference must keep its wake, got: $out"

  # Non-advisory content never concludes, even for a task that is gone.
  rm -f "$home/state/live-ship.meta"
  out=$(verdict '{"schema":"firstmate.process-event-extension-error.v1","code":"internal"}' "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "non-advisory content must keep its wake, got: $out"
  out=$(verdict "" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "an empty capture must keep its wake, got: $out"
  out=$(verdict "some foreign leading line
$(advisory live-ship)" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a capture with a non-advisory leading line must keep its wake, got: $out"

  # The host's own poll-timeout evidence stays the other silent content, and
  # only for THIS extension.
  out=$(verdict "$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
    extension_id: "org.firstmate.fork.progress-guard", operation: "source.poll", code: "timeout"}')" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "the poll-timeout absorb must survive with a home reference, got: $out"
  out=$(verdict "$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
    extension_id: "org.firstmate.fork.pr-green", operation: "source.poll", code: "timeout"}')" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "another extension's timeout must keep its wake, got: $out"
  out=$(verdict "$(jq -cnS '{schema: "firstmate.process-event-extension-error.v1",
    extension_id: "org.firstmate.fork.progress-guard", operation: "source.invoke", code: "timeout"}')" "home:$home") \
    || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "a timeout naming another operation must keep its wake, got: $out"
  pass "side: a live, paused, or unreadable task, a missing home reference, non-advisory content, and a foreign timeout all keep their wake"
}

test_a_multi_advisory_capture_concludes_only_when_every_task_does() {
  local home out both
  both="$(advisory task-a)
$(advisory task-b)"
  home="$PTMP/side-multi/home"
  p_home "$home"
  # task-b is live; task-a has no record at all.
  record "$home" task-b kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4602.7
  printf 'working [at=1793000000]: building\n' > "$home/state/task-b.status"
  out=$(verdict "$both" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = false ] || fail "one live task must keep the whole multi-advisory capture announced, got: $out"

  # Both concluded: the capture concludes.
  rm -f "$home/state/task-b.meta"
  out=$(verdict "$both" "home:$home") || fail "the result.silent invocation failed"
  [ "$out" = true ] || fail "a capture whose every task is gone must conclude, got: $out"
  pass "side: a multi-advisory capture concludes only when every advisory in it does"
}

# --- the real host and runner, end to end -----------------------------------

# install_package <home> <package-copy>: bind the copy and register the source
# through the real host and runner.
install_package() {
  local home=$1 pkg=$2
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter progress-guard --trust-same-user-code \
    --consent task-metadata >/dev/null \
    || fail "the real extension host must bind the package"
  FM_HOME="$home" "$PROCEVENT" register-extension progress-guard progress-guard \
    --config-ref "home:$home" >/dev/null || fail "registration failed"
}

run_source_until_result() {
  local home=$1 file=$2 _
  for _ in $(seq 1 50); do
    FM_HOME="$home" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
    [ -f "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

# build_live_home <home>: a working task whose evidence is aged past the
# threshold, ready to produce one stall capture.
build_live_home() {
  p_home "$1"
  mkdir -p "$1/worktree/src" "$1/data/green-ship"
  printf 'export const x = 1;\n' > "$1/worktree/src/main.js"
  printf 'report\n' > "$1/data/green-ship/report.md"
  record "$1" green-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4700.7 worktree="$1/worktree"
  printf 'working [at=1793000000]: building the guard\n' > "$1/state/green-ship.status"
  touch -t 202001010000 "$1/state/green-ship.status"
  find "$1/worktree" -exec touch -t 202001020000 {} +
  find "$1/data/green-ship" -exec touch -t 202001030000 {} +
  mkdir -p "$1/state/progress-guard"
  printf '100\n' > "$1/state/progress-guard/poll-wait-ms"
}

test_a_capture_for_a_concluded_task_concludes_through_the_real_runner() {
  local home pkg
  home="$PTMP/e2e-gone/home"
  build_live_home "$home"
  pkg="$PTMP/e2e-gone/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the installed stall seam published no result for a stalled task"
  assert_contains "$(cat "$home/state/procevent-inbox/progress-guard.1.result")" \
    "PROGRESS STALL (advisory): task green-ship" "the capture carries the advisory body"
  assert_contains "$(wake_payloads "$home")" "procevent progress-guard progress-guard 1" \
    "the live advisory is announced once"
  assert_present "$home/state/green-ship.progress-guard-latch" "the wake publishes its latch marker"

  # The task is cleaned up after the capture exists: the next read of that
  # capture concludes it from the gone record alone.
  rm -f "$home/state/green-ship.meta"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a concluded task's capture must not be re-announced: $(wake_payloads "$home")"
  assert_present "$home/state/procevent-inbox/progress-guard.1.handled" \
    "the concluded capture is recorded handled"
  # And it stays concluded: a later read never brings it back.
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "a concluded capture must stay concluded: $(wake_payloads "$home")"
  # The next poll prunes the concluded task's latch marker, so nothing
  # outlives the task it was written for. A reconcile may have left a runner
  # still holding the source, so give any owner its poll and re-drive until
  # the prune is observable.
  for _ in $(seq 1 50); do
    [ ! -e "$home/state/green-ship.progress-guard-latch" ] && break
    FM_HOME="$home" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
    sleep 0.2
  done
  assert_absent "$home/state/green-ship.progress-guard-latch" \
    "the poll prunes the latch marker of a task whose record is gone"
  pass "end to end: a task concluding between capture and read concludes the capture with no wake and no pending re-delivery, and its marker is pruned"
}

test_a_live_capture_still_reannounces_until_acknowledged() {
  local home pkg
  home="$PTMP/e2e-live/home"
  build_live_home "$home"
  pkg="$PTMP/e2e-live/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the installed stall seam published no result for a stalled task"

  # Nothing concluded: the same read that would self-conclude a moot capture
  # keeps re-announcing this live one until firstmate acknowledges it.
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  assert_contains "$(wake_payloads "$home")" "procevent progress-guard progress-guard 1" \
    "a live task's unhandled capture is still re-announced"
  assert_absent "$home/state/procevent-inbox/progress-guard.1.handled" "a live capture stays unhandled"
  FM_HOME="$home" "$PROCEVENT" handled progress-guard 1 >/dev/null || fail "acknowledging the capture failed"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] \
    || fail "an acknowledged capture is not re-announced: $(wake_payloads "$home")"
  pass "end to end: a live task's capture keeps its ordinary wake and re-announcement until acknowledged"
}

fork_run_tests
