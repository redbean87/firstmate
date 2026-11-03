#!/usr/bin/env bash
# Fork progress-stall guard: the scope gate, the silence of the shipped package
# while evidence is fresh, and the real binding, registration, capture, wake,
# classification, and acknowledgement path for one stalled task.
#
# Every case drives the REAL extension host (bin/fm-extension.mjs) and the REAL
# process-event runner (bin/fm-procevent.sh) against an isolated fixture home
# holding real upstream task records. No test contacts a network, a live
# fleet, or the running session's own home. The stall evidence is plain fixture
# files whose mtimes are pinned to a fixed old instant with `touch -t`, so the
# shipped default threshold (25 minutes) applies without any test waiting.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/progress-guard/extension"
ENTRY="$PKG_SRC/fm-progress-guard.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"

PTMP=$(fm_test_tmproot fm-fork-progress-guard)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
# Source ownership claims are per user, not per home: without this, a real
# registered source of the same id on this machine owns the fixture's claim.
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }

record() {  # <home> <id> <key=value>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

# make_worktree <dir>: a plain worktree fixture with one source file.
make_worktree() {
  mkdir -p "$1/src"
  printf 'export const x = 1;\n' > "$1/src/main.js"
}

# backdate_status / backdate_tree / backdate_data <path>: pin evidence to fixed
# old instants (2020, years before any legal threshold) with the portable
# touch -t form, so the shipped 25-minute default applies with no test waiting.
# The three instants differ so the newest-evidence line has a deterministic
# winner: the data file.
backdate_status() { touch -t 202001010000 "$1"; }
backdate_tree() { find "$1" -exec touch -t 202001020000 {} +; }
backdate_data() { find "$1" -exec touch -t 202001030000 {} +; }

working_status() {  # <home> <id>
  printf 'working [at=1793000000]: building the guard\n' > "$1/state/$2.status"
}

# build_stalled_home <home> <id>: a working task whose every evidence source
# is aged far past the threshold, with the data file newest of the three.
build_stalled_home() {
  p_home "$1"
  make_worktree "$1/worktree"
  record "$1" "$2" kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4200.7 worktree="$1/worktree"
  working_status "$1" "$2"
  mkdir -p "$1/data/$2"
  printf 'report\n' > "$1/data/$2/report.md"
  backdate_status "$1/state/$2.status"
  backdate_tree "$1/worktree"
  backdate_data "$1/data/$2"
  fast_poll "$1"
}

fast_poll() {
  mkdir -p "$1/state/progress-guard"
  printf '100\n' > "$1/state/progress-guard/poll-wait-ms"
}

poll_request() {  # <request-hex> <config-ref>
  jq -cn --arg rid "sha256:$1" --arg ref "$2" '{schema: "firstmate.extension-request.v1", request_id: $rid,
    host_protocol: 1, extension_id: "org.firstmate.fork.progress-guard", extension_version: "0.1.0",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "progress-guard",
    operation: "source.poll", input: {source_id: "progress-guard", config_ref: $ref}}'
}

adapter_poll() {  # <config-ref> (stdout is the response envelope)
  poll_request "$(printf '3%.0s' $(seq 1 64))" "$1" | node "$ENTRY" invoke
}

adapter_poll_with_id() {  # <config-ref> <64-hex-request-id>
  poll_request "$2" "$1" | node "$ENTRY" invoke
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# install_package <home> <package-copy> [config-ref]: bind the copy and register
# the source through the real host and runner; sets PKG_TOKEN.
install_package() {
  local home=$1 pkg=$2 ref=${3:-} reg
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter progress-guard --trust-same-user-code \
    --consent task-metadata >/dev/null \
    || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$home" "$PROCEVENT" register-extension progress-guard progress-guard \
    --config-ref "${ref:-home:$home}") || fail "registration failed"
  PKG_TOKEN=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')
  [ -n "$PKG_TOKEN" ] || fail "registration must print its owner token"
}

# run_source_until_result <home> <result-file>: run the real runner once per
# attempt until that exact result sequence exists. `start` reports success when
# another runner already owns the source, so an empty inbox alone is not proof.
run_source_until_result() {
  local home=$1 file=$2 _
  for _ in $(seq 1 50); do
    FM_HOME="$home" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
    [ -f "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

start_source() {  # <home>: one runner invocation, run to completion
  FM_HOME="$1" "$PROCEVENT" start progress-guard >/dev/null 2>&1 || true
}

result_files() {  # <home>
  local f
  for f in "$1"/state/procevent-inbox/progress-guard.*.result; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

# --- the scope gate ---------------------------------------------------------

# build_gate_home <home>: one task inside the stall signal's authority and
# every other record refused for one specific reason. All evidence is fresh,
# so this fixture can only ever observe the gate.
build_gate_home() {
  local home=$1
  p_home "$home"
  make_worktree "$home/worktree"
  record "$home" ok-ship kind=ship harness=pi mode=direct-PR yolo=on \
    spawn_gen=s1793000000.4200.7 worktree="$home/worktree"
  working_status "$home" ok-ship
  record "$home" mate kind=secondmate mode=secondmate yolo=off \
    spawn_gen=s1793000000.4200.8
  working_status "$home" mate
  record "$home" paused-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4200.9 worktree="$home/worktree"
  printf 'paused [at=1793000100]: waiting for the window until 2026-11-04T00:00Z\n' \
    > "$home/state/paused-ship.status"
  record "$home" done-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4201.0 worktree="$home/worktree"
  printf 'done [at=1793000200]: shipped it\n' > "$home/state/done-ship.status"
  record "$home" prose-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4201.1 worktree="$home/worktree"
  printf 'working [at=1793000300]: implementing\nalso rewriting the docs and the tests\n' \
    > "$home/state/prose-ship.status"
  record "$home" no-status-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4201.2 worktree="$home/worktree"
  record "$home" no-wt-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4201.3
  working_status "$home" no-wt-ship
  record "$home" gone-wt-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4201.4 worktree="$home/never-created"
  working_status "$home" gone-wt-ship
  record "$home" no-inc-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    worktree="$home/worktree"
  working_status "$home" no-inc-ship
  record "$home" duplicated kind=ship mode=no-mistakes spawn_gen=s1793000000.4201.5 \
    worktree="$home/worktree" mode=direct-PR
  working_status "$home" duplicated
  record "$home" linked kind=ship harness=pi mode=no-mistakes \
    spawn_gen=s1793000000.4201.6 worktree="$home/worktree"
  working_status "$home" linked
  printf '%s\n' kind=ship mode=no-mistakes spawn_gen=s1793000000.4201.7 \
    worktree="$home/worktree" > "$home/config/linked-target.meta"
  rm -f "$home/state/linked.meta"
  ln -s ../config/linked-target.meta "$home/state/linked.meta"
  fast_poll "$home"
}

test_the_gate_admits_only_working_tasks_with_an_attributable_worktree() {
  local home out err before after
  home="$PTMP/gate/home"
  build_gate_home "$home"
  before=$(find "$home" -type f | sort)
  out=$(adapter_poll "home:$home" 2>"$PTMP/gate.err") || fail "the shipped adapter's poll failed"
  err=$(cat "$PTMP/gate.err")
  [ "$(printf '%s' "$out" | jq -r .ok)" = true ] || fail "the poll response must be ok: $out"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "with fresh evidence the adapter must stay silent: $out"
  [ "$(printf '%s' "$out" | jq -r .result.output)" = "" ] || fail "a no-result poll carries no output"
  [ "$(printf '%s\n' "$err" | grep -c '^progress-guard: eligible ')" = 1 ] \
    || fail "exactly one record is inside this source's authority: $err"
  assert_contains "$err" "progress-guard: eligible ok-ship" "a working task with an attributed worktree is offered"
  for skip in "mate secondmate" "paused-ship verb-paused" "done-ship verb-done" \
    "prose-ship verb-also" "no-status-ship status-unreadable" \
    "no-wt-ship worktree-unattributed" "gone-wt-ship worktree-gone" \
    "no-inc-ship incarnation-unusable" "duplicated record-unreadable" \
    "linked record-unreadable"; do
    assert_contains "$err" "progress-guard: skipped $skip" "$skip is refused"
  done
  after=$(find "$home" -type f | sort)
  [ "$before" = "$after" ] || fail "a gate-only poll writes nothing: $(printf '%s\n' "$after" | comm -13 <(printf '%s\n' "$before") -)"
  pass "gate: only a working task of this home with a usable incarnation and an attributable worktree is offered, and polling writes nothing"
}

test_a_working_task_with_fresh_evidence_stays_silent() {
  local home out err before after
  home="$PTMP/fresh/home"
  p_home "$home"
  make_worktree "$home/worktree"
  record "$home" fresh-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    spawn_gen=s1793000000.4300.7 worktree="$home/worktree"
  working_status "$home" fresh-ship
  mkdir -p "$home/data/fresh-ship"
  printf 'report\n' > "$home/data/fresh-ship/report.md"
  fast_poll "$home"
  before=$(find "$home" -type f | sort)
  out=$(adapter_poll "home:$home" 2>"$PTMP/fresh.err") || fail "the shipped adapter's poll failed"
  err=$(cat "$PTMP/fresh.err")
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a working task with fresh evidence must stay silent: $out"
  assert_contains "$err" "progress-guard: eligible fresh-ship" "the task was actually evaluated, not skipped"
  assert_absent "$home/state/fresh-ship.progress-guard-latch" "a silent task writes no latch marker"
  after=$(find "$home" -type f | sort)
  [ "$before" = "$after" ] || fail "the silent poll writes nothing"
  pass "silence: a working task with fresh evidence in all three sources is evaluated and stays silent"
}

test_a_malformed_or_unusable_config_ref_is_an_error_not_a_wake() {
  local home out
  home="$PTMP/configref/home"
  p_home "$home"
  fast_poll "$home"
  out=$(adapter_poll "$home" 2>/dev/null) || fail "a malformed config_ref must answer, not crash"
  [ "$(printf '%s' "$out" | jq -r .ok)" = false ] || fail "a bare path is not a valid config_ref: $out"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = invalid-request ] || fail "a malformed config_ref is an invalid request"
  out=$(adapter_poll "home:$home/../nowhere" 2>/dev/null) || fail "a traversing config_ref must answer"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = invalid-request ] || fail "a non-normalized config_ref is refused"
  rm -rf "$home/state"
  out=$(adapter_poll "home:$home" 2>/dev/null) || fail "a home without state must answer"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = unavailable ] || fail "a missing state directory is unavailable"
  [ "$(printf '%s' "$out" | jq -r .result)" = null ] || fail "an error response never carries a result"
  pass "config_ref: a malformed, traversing, or unusable reference answers with an error code and never a wake"
}

# --- one stall, one wake, through the real path -----------------------------

test_a_stalled_task_wakes_once_through_the_real_path() {
  local home pkg result before_meta after_meta
  home="$PTMP/stall/home"
  build_stalled_home "$home" stalled-ship
  pkg="$PTMP/stall/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  before_meta=$(shasum -a 256 "$home"/state/*.meta | sort)
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the runner published no progress-stall result"
  result="$home/state/procevent-inbox/progress-guard.1.result"
  assert_contains "$(cat "$result")" "PROGRESS STALL (advisory): task stalled-ship" \
    "the captured result names the stalled task"
  assert_contains "$(cat "$result")" "has produced no new evidence for" \
    "the wake states the observed silence"
  assert_contains "$(cat "$result")" "(threshold 25m)" \
    "the wake states the shipped 25-minute threshold"
  assert_contains "$(cat "$result")" "newest evidence: $home/data/stalled-ship/report.md" \
    "the wake names the newest evidence it could find"
  assert_contains "$(cat "$result")" "status $home/state/stalled-ship.status" \
    "the wake lists the status evidence source"
  assert_contains "$(cat "$result")" "worktree $home/worktree" \
    "the wake lists the worktree evidence source"
  assert_contains "$(cat "$result")" "not a decision, an instruction, or authority to steer" \
    "the advisory body states plainly that it carries no authority"
  assert_contains "$(wake_payloads "$home")" "procevent progress-guard progress-guard 1" \
    "Firstmate gets the existing bounded process-event wake"
  [ "$(FM_HOME="$home" "$PROCEVENT" classify "$result")" = stall-advisory ] \
    || fail "the result classifies as stall-advisory"
  assert_present "$home/state/stalled-ship.progress-guard-latch" "the wake publishes its latch marker"
  [ "$(wc -l < "$home/state/stalled-ship.progress-guard-latch" | tr -d ' ')" = 6 ] \
    || fail "the latch marker is a fixed six-field record"
  assert_absent "${result%.result}.handled" "the result stays unhandled until firstmate acknowledges it"

  # The same stall swept again stays silent: the latch holds, and a second
  # sweep after handling produces no second wake.
  FM_HOME="$home" "$PROCEVENT" handled progress-guard 1 >/dev/null || fail "handling the capture failed"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  [ -z "$(wake_payloads "$home")" ] || fail "a handled wake is not re-announced: $(wake_payloads "$home")"
  start_source "$home"
  [ ! -e "$home/state/procevent-inbox/progress-guard.2.result" ] \
    || fail "the same stall woke twice: $(cat "$home/state/procevent-inbox/progress-guard.2.result")"
  assert_present "$home/state/procevent/progress-guard.source" "the source stays registered for the next stall"

  # Advisory by construction: no task record or data file is written.
  after_meta=$(shasum -a 256 "$home"/state/*.meta | sort)
  [ "$before_meta" = "$after_meta" ] || fail "the stall path rewrites no task record"
  [ -z "$(find "$home/data" -type f -not -path "$home/data/extensions/*" -newer "$home/state/progress-guard/poll-wait-ms")" ] \
    || fail "nothing is filed under data/ by the adapter"
  FM_HOME="$home" "$PROCEVENT" retire progress-guard --if-owner "$PKG_TOKEN" >/dev/null 2>&1
  assert_absent "$home/state/procevent/progress-guard.source" "the owner token retires the registration"
  pass "delivery: the real binding, registration, capture, wake, latch, classification, and acknowledgement path carries one stall wake and records no authority"
}

test_a_failed_read_is_classified_as_error_evidence() {
  local home pkg other result out
  home="$PTMP/classify/home"
  p_home "$home"
  other="$PTMP/classify/unusable-home"
  mkdir -p "$other"
  pkg="$PTMP/classify/packages/progress-guard"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg" "home:$other"
  run_source_until_result "$home" "$home/state/procevent-inbox/progress-guard.1.result" \
    || fail "the runner captured no evidence for a read it cannot perform"
  result="$home/state/procevent-inbox/progress-guard.1.result"
  assert_contains "$(cat "$result")" '"schema":"firstmate.process-event-extension-error.v1"' \
    "a failed read is captured as host failure evidence"
  out=$(FM_HOME="$home" "$PROCEVENT" classify "$result") || fail "classifying captured failure evidence failed"
  [ "$out" = stall-error ] || fail "a failed read must not classify as stall advice: $out"
  pass "classification: captured failure evidence is labelled stall-error, and stall-advisory is reserved for a stall body"
}

fork_run_tests
