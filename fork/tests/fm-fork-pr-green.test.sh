#!/usr/bin/env bash
# Fork PR readiness wake: the scope gate, the silence of the shipped package,
# and the real binding, registration, capture, wake, and acknowledgement path.
#
# Every case drives the REAL extension host (bin/fm-extension.mjs) and the REAL
# process-event runner (bin/fm-procevent.sh) against an isolated fixture home
# holding real upstream task records. No test contacts GitHub, a forge CLI, a
# live PR, or the running session's own home. The wake comes from a package copy
# whose readiness seam (extension/readiness.mjs) is a fixture stub, which is what
# proves the seam: replacing that one file is the only way to produce a wake.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: node absent\n'; exit 0; }

PKG_SRC="$ROOT/fork/pr-green/extension"
ENTRY="$PKG_SRC/fm-pr-green.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222

PTMP=$(fm_test_tmproot fm-fork-pr-green)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR
# Source ownership claims are per user, not per home: without this, a real
# registered source of the same id on this machine owns the fixture's claim.
export FM_PROCEVENT_CLAIM_ROOT="$PTMP/procevent-claims"

# p_home <home>: an isolated Firstmate home with the directories the extension
# host, the runner, and the adapter read.
p_home() {
  mkdir -p "$1/state" "$1/config" "$1/data"
}

# record <home> <id> <key=value>...: one task record exactly as upstream writes
# it, mode 0600.
record() {
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}

# armed <home> <id>: the armed merge poll's sidecar, as bin/fm-pr-check.sh
# publishes it.
armed() {
  printf '#!/usr/bin/env bash\n' > "$1/state/$2.check.sh"
  chmod 0600 "$1/state/$2.check.sh"
}

# now_ms: the wall clock in milliseconds, for the read-budget cases.
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

# fast_poll <home>: a fixture poll wait, so a no-result poll returns quickly
# instead of holding its ordinary 50 seconds.
fast_poll() {
  mkdir -p "$1/state/pr-green"
  printf '100\n' > "$1/state/pr-green/poll-wait-ms"
}

# fixture_forge <home> <kind>: point this home at the fixture GitHub CLI and give
# it a recorded answer set. The readiness predicate reads GitHub, so no test here
# may reach a real gh: an unconfigured home would probe the operator's own
# install and call the live forge for the fixture owner.
fixture_forge() {  # <home> <kind> [forge-dir]
  local home=$1 kind=$2 forge=${3:-$1/forge}
  # The wrapper is the executable the predicate resolves; config/pr-green-gh names
  # it by absolute path, which is the explicit override a real home uses. A case
  # that must prove a poll writes nothing keeps the recorded answer set and its
  # call log outside the home entirely.
  fork_fixture_gh "$home/bin/gh" "$forge"
  mkdir -p "$home/config"
  printf '%s\n' "$home/bin/gh" > "$home/config/pr-green-gh"
  case "$kind" in
    green) fork_pr_green_forge "$forge" "$HEAD_A" ;;
    pending) fork_pr_pending_forge "$forge" "$HEAD_A" ;;
    *) fail "fixture_forge: unknown fixture $kind" ;;
  esac
}

poll_request() {  # <request-hex> <config-ref>
  jq -cn --arg rid "sha256:$1" --arg ref "$2" '{schema: "firstmate.extension-request.v1", request_id: $rid,
    host_protocol: 1, extension_id: "org.firstmate.fork.pr-green", extension_version: "0.4.0",
    package_digest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    capability: "process-event-adapter", capability_version: 1, adapter: "pr-green",
    operation: "source.poll", input: {source_id: "pr-green", config_ref: $ref}}'
}

# adapter_poll <entrypoint> <config-ref>: one protocol invocation of one poll.
adapter_poll() {  # <entrypoint> <config-ref> (stdout is the response envelope)
  poll_request "$(printf '3%.0s' $(seq 1 64))" "$2" | node "$1" invoke
}

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

# eligible_only_home: the gate fixture. Three records are inside this fork's
# authority and every other record is refused for one specific reason.
build_gate_home() {
  local home=$1
  p_home "$home"
  record "$home" ok-nomistakes kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_A"
  armed "$home" ok-nomistakes
  record "$home" ok-directpr kind=ship harness=pi mode=direct-PR yolo=on \
    pr=https://github.com/acme/app/pull/8 pr_head="$HEAD_B"
  armed "$home" ok-directpr
  printf 'ghe.corp.example\n' > "$home/config/github-hosts"
  record "$home" ok-enterprise kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://ghe.corp.example/acme/app/pull/9 pr_head="$HEAD_A"
  armed "$home" ok-enterprise
  record "$home" mr-gitlab kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://gitlab.com/acme/app/-/merge_requests/3 pr_head="$HEAD_A"
  armed "$home" mr-gitlab
  record "$home" change-gerrit kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://review.example.com/c/acme/app/+/12345 pr_head="$HEAD_A"
  armed "$home" change-gerrit
  record "$home" forgejo kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://code.example.com/acme/app/pulls/4 pr_head="$HEAD_A"
  armed "$home" forgejo
  record "$home" yolo-off kind=ship harness=pi mode=no-mistakes yolo=off \
    pr=https://github.com/acme/app/pull/10 pr_head="$HEAD_A"
  armed "$home" yolo-off
  record "$home" local-only kind=ship harness=pi mode=local-only yolo=on \
    pr=https://github.com/acme/app/pull/11 pr_head="$HEAD_A"
  armed "$home" local-only
  record "$home" mate kind=secondmate mode=secondmate yolo=off
  record "$home" no-head kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/12
  armed "$home" no-head
  record "$home" bad-head kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/13 pr_head=abc123
  armed "$home" bad-head
  record "$home" not-armed kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/14 pr_head="$HEAD_A"
  record "$home" ghe-unlisted kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://other.corp.example/acme/app/pull/15 pr_head="$HEAD_A"
  armed "$home" ghe-unlisted
  record "$home" duplicated kind=ship mode=no-mistakes yolo=on mode=direct-PR \
    pr=https://github.com/acme/app/pull/16 pr_head="$HEAD_A"
  armed "$home" duplicated
  # A record that is not a plain file can never become a candidate.
  armed "$home" linked
  printf '%s\n' kind=ship mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/17 pr_head="$HEAD_A" > "$home/config/linked-target.meta"
  ln -s ../config/linked-target.meta "$home/state/linked.meta"
  # A not-ready forge, so this case can only ever observe the gate: a green one
  # here would produce a wake through the now-installed readiness predicate.
  fixture_forge "$home" pending "$PTMP/gate/forge"
  fast_poll "$home"
}

test_scope_gate_admits_only_authorized_github_tasks() {
  local home out err before after
  home="$PTMP/gate/home"
  build_gate_home "$home"
  before=$(find "$home" -type f | sort)
  out=$(adapter_poll "$ENTRY" "home:$home" 2>"$PTMP/gate.err") || fail "the shipped adapter's poll failed"
  err=$(cat "$PTMP/gate.err")
  [ "$(printf '%s' "$out" | jq -r .ok)" = true ] || fail "the poll response must be ok: $out"
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "with no readiness predicate installed the adapter must stay silent: $out"
  [ "$(printf '%s' "$out" | jq -r .result.output)" = "" ] || fail "a no-result poll carries no output"
  [ "$(printf '%s\n' "$err" | grep -c '^pr-green: eligible ')" = 3 ] \
    || fail "exactly three records are inside this fork's authority: $err"
  for id in ok-nomistakes ok-directpr ok-enterprise; do
    assert_contains "$err" "pr-green: eligible $id" "$id is inside this fork's authority"
  done
  for skip in "mr-gitlab unsupported-provider" "change-gerrit unsupported-provider" \
    "forgejo unsupported-provider" "yolo-off yolo-off" "local-only mode-local-only" \
    "mate secondmate" "no-head no-pr-head" "bad-head pr-head-invalid" \
    "not-armed not-armed" "ghe-unlisted host-not-listed" "duplicated record-unreadable" \
    "linked record-unreadable"; do
    assert_contains "$err" "pr-green: skipped $skip" "$skip is refused"
  done
  after=$(find "$home" -type f | sort)
  [ "$before" = "$after" ] || fail "a poll writes nothing: $(printf '%s\n' "$after" | comm -13 <(printf '%s\n' "$before") -)"
  pass "scope gate: only armed GitHub pull requests of mode no-mistakes/direct-PR yolo=on ships are offered, and polling writes nothing"
}

test_a_malformed_or_unusable_config_ref_is_an_error_not_a_wake() {
  local home out
  home="$PTMP/configref/home"
  p_home "$home"
  fast_poll "$home"
  out=$(adapter_poll "$ENTRY" "$home" 2>/dev/null) || fail "a malformed config_ref must answer, not crash"
  [ "$(printf '%s' "$out" | jq -r .ok)" = false ] || fail "a bare path is not a valid config_ref: $out"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = invalid-request ] || fail "a malformed config_ref is an invalid request"
  out=$(adapter_poll "$ENTRY" "home:$home/../nowhere" 2>/dev/null) || fail "a traversing config_ref must answer"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = invalid-request ] || fail "a non-normalized config_ref is refused"
  rm -rf "$home/state"
  out=$(adapter_poll "$ENTRY" "home:$home" 2>/dev/null) || fail "a home without state must answer"
  [ "$(printf '%s' "$out" | jq -r .error.code)" = unavailable ] || fail "a missing state directory is unavailable"
  [ "$(printf '%s' "$out" | jq -r .result)" = null ] || fail "an error response never carries a result"
  pass "config_ref: a malformed, traversing, or unusable reference answers with an error code and never a wake"
}

# install_package <home> <package-copy> [config-ref]: bind the copy and register
# the source through the real host and runner; sets PKG_TOKEN.
install_package() {
  local home=$1 pkg=$2 ref=${3:-} reg
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter pr-green --trust-same-user-code \
    --consent task-metadata --consent credential-store --consent network >/dev/null \
    || fail "the real extension host must bind the package"
  reg=$(FM_HOME="$home" "$PROCEVENT" register-extension pr-green pr-green --config-ref "${ref:-home:$home}") \
    || fail "registration failed"
  PKG_TOKEN=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')
  [ -n "$PKG_TOKEN" ] || fail "registration must print its owner token"
}

# run_source_until_result <home> <result-file>: run the real runner once per
# attempt until that exact result sequence exists. `start` reports success when
# another runner already owns the source, so an empty inbox alone is not proof.
run_source_until_result() {
  local home=$1 file=$2 _
  for _ in $(seq 1 50); do
    FM_HOME="$home" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
    [ -f "$file" ] && return 0
    sleep 0.2
  done
  return 1
}

# start_source <home>: one runner invocation, run to completion. It blocks until
# the source's poll has finished, so a poll that answers nothing is directly
# observable as a missing result file.
start_source() {  # <home>
  FM_HOME="$1" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
}

# run_source_once_until_result <home>: run the real runner until it has published
# the first readiness result.
run_source_once_until_result() {  # <home>
  run_source_until_result "$1" "$1/state/procevent-inbox/pr-green.1.result"
}

result_files() {  # <home>
  local f
  for f in "$1"/state/procevent-inbox/pr-green.*.result; do [ -f "$f" ] && printf '%s\n' "$f"; done
}

test_the_registered_source_delivers_one_advisory_wake() {
  local home pkg token result before_meta after_meta
  home="$PTMP/seam/home"
  build_gate_home "$home"
  pkg="$PTMP/seam/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  # The fixture seam: it records every entry it is offered and reports exactly
  # one of them ready. This is the same single file a later slice fills in.
  cat > "$pkg/readiness.mjs" <<'JS'
import fs from "node:fs";
// The adapter imports the whole seam, so a fixture seam implements the whole
// interface: the readiness judgment the adapter calls, and the fork-owned cleanup
// of the latch state that judgment never wrote.
export function pruneReadinessMarkers() { return 0; }
export function decideWake(entry, ctx) {
  fs.appendFileSync(`${ctx.home}/seam-observed.txt`, `${entry.id}\n`);
  if (entry.id !== "ok-nomistakes") return null;
  return {
    advisory: `PR READINESS (advisory): ${entry.id} ${entry.pr} at head ${entry.head}. `
      + "Every required check is reported green. This is evidence for firstmate to look, not approval, "
      + "and the merge step re-reads every requirement before merging.",
  };
}
JS
  before_meta=$(shasum -a 256 "$home"/state/*.meta | sort)
  install_package "$home" "$pkg"
  token=$PKG_TOKEN
  run_source_once_until_result "$home" || fail "the runner published no readiness result"
  result=$(result_files "$home" | head -1)
  assert_contains "$(cat "$result")" "PR READINESS (advisory)" "the captured result carries the advisory body"
  assert_contains "$(cat "$result")" "https://github.com/acme/app/pull/7" "the advisory body names the recorded pull request"
  assert_contains "$(cat "$result")" "at head $HEAD_A" "the advisory body names the recorded head"
  assert_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" \
    "Firstmate gets the existing bounded process-event wake"
  [ "$(FM_HOME="$home" "$PROCEVENT" classify "$result")" = pr-ready-advisory ] \
    || fail "the result classifies as advisory readiness evidence"
  assert_absent "${result%.result}.handled" "the result stays unhandled until firstmate acknowledges it"
  assert_present "$home/state/procevent/pr-green.source" "the source stays registered for the next pull request"
  [ "$(sort -u "$home/seam-observed.txt")" = "$(printf 'ok-directpr\nok-enterprise\nok-nomistakes')" ] \
    || fail "the seam sees exactly the authorized tasks: $(sort -u "$home/seam-observed.txt")"

  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  assert_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" "an unhandled wake is re-announced"
  FM_HOME="$home" "$PROCEVENT" handled pr-green 1 >/dev/null || fail "handled acknowledgement failed"
  : > "$home/state/.wake-queue"
  FM_HOME="$home" "$PROCEVENT" reconcile >/dev/null 2>&1
  assert_not_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" "a handled wake is not re-announced"

  # Advisory by construction: no approval, merge authority, decision answer, or
  # task-record change is written by the adapter or the runner.
  after_meta=$(shasum -a 256 "$home"/state/*.meta | sort)
  [ "$before_meta" = "$after_meta" ] || fail "the readiness path rewrites no task record"
  [ -z "$(find "$home/state" -name '*.answer*' -o -name '*merge-authority*' -o -name '*captain-hold*')" ] \
    || fail "no decision answer or merge authority record is written"
  [ -z "$(find "$home/data" -type f -not -path "$home/data/extensions/*")" ] \
    || fail "nothing is filed under data/ beyond the installed extension"
  FM_HOME="$home" "$PROCEVENT" retire pr-green --if-owner "$token" >/dev/null 2>&1
  assert_absent "$home/state/procevent/pr-green.source" "the owner token retires the registration"
  pass "delivery: the real binding, registration, capture, wake, re-announcement, and acknowledgement path carries one advisory readiness event and records no authority"
}

test_a_failed_read_is_classified_as_error_evidence() {
  local home pkg other result out
  home="$PTMP/classify/home"
  p_home "$home"
  other="$PTMP/classify/unusable-home"
  mkdir -p "$other"
  pkg="$PTMP/classify/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg" "home:$other"
  run_source_once_until_result "$home" || fail "the runner captured no evidence for a read it cannot perform"
  result=$(result_files "$home" | head -1)
  assert_contains "$(cat "$result")" '"schema":"firstmate.process-event-extension-error.v1"' \
    "a failed readiness read is captured as host failure evidence"
  out=$(FM_HOME="$home" "$PROCEVENT" classify "$result") || fail "classifying captured failure evidence failed"
  [ "$out" = pr-ready-error ] || fail "a failed readiness read must not classify as readiness advice: $out"
  pass "classification: captured failure evidence is labelled pr-ready-error, and pr-ready-advisory is reserved for a readiness body"
}

test_the_shipped_package_stays_silent_for_a_pull_request_that_is_not_green() {
  local home pkg
  home="$PTMP/silent/home"
  build_gate_home "$home"
  pkg="$PTMP/silent/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  : > "$PTMP/gate/forge/calls.log"
  FM_HOME="$home" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
  [ -z "$(result_files "$home")" ] || fail "a pull request whose checks are still running captures no result"
  [ -z "$(wake_payloads "$home")" ] || fail "the shipped package publishes no wake: $(wake_payloads "$home")"
  assert_absent "$home/state/procevent-inbox/pr-green.1.result" "no readiness evidence is captured"
  [ -s "$PTMP/gate/forge/calls.log" ] || fail "the installed predicate must actually read the fixture forge, or this case proves nothing"
  assert_contains "$(cat "$PTMP/gate/forge/calls.log")" "pr view https://github.com/acme/app/pull/7" \
    "the installed predicate reads the eligible pull request"
  assert_not_contains "$(cat "$PTMP/gate/forge/calls.log")" "branches/" \
    "a pull request whose checks are not green is refused before any required-context read"
  assert_present "$home/state/procevent/pr-green.source" "the silent source stays registered and listening"
  pass "silence: the shipped package binds, registers, reads the forge, and produces no wake while a check is still running"
}

test_one_poll_gives_every_task_its_own_read_inside_one_budget() {
  local home out calls started elapsed_ms
  home="$PTMP/budget/home"
  p_home "$home"
  record "$home" a-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  armed "$home" a-ship
  record "$home" b-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/8 pr_head="$HEAD_A" spawn_gen=s1793000000.4200.8
  armed "$home" b-ship
  record "$home" c-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/9 pr_head="$HEAD_A"
  armed "$home" c-ship
  fixture_forge "$home" green
  mkdir -p "$home/state/pr-green"
  printf '4000\n' > "$home/state/pr-green/read-budget-ms"
  printf '30\n' > "$home/forge/hang-pr-view"
  fast_poll "$home"
  : > "$home/forge/calls.log"
  started=$(now_ms)
  out=$(adapter_poll "$ENTRY" "home:$home" 2>/dev/null) || fail "the adapter's poll must answer, not crash"
  elapsed_ms=$(( $(now_ms) - started ))
  [ "$(printf '%s' "$out" | jq -r .result.status)" = no-result ] \
    || fail "a forge that never answers is silence, never a readiness result: $out"
  [ "$(printf '%s' "$out" | jq -r .result.output)" = "" ] || fail "a no-result poll carries no output"
  calls=$(wc -l < "$home/forge/calls.log" | tr -d ' ')
  [ "$calls" = 3 ] \
    || fail "every eligible task gets its own forge read in one poll, whatever its id sorts after: $(cat "$home/forge/calls.log")"
  assert_contains "$(cat "$home/forge/calls.log")" "pull/9" "the task that sorts last is read, not starved by the two before it"
  [ "$elapsed_ms" -lt 5200 ] \
    || fail "the three per-entry reads stay inside the poll's one 4000ms budget instead of taking a larger share each, took ${elapsed_ms}ms"
  pass "budget: one poll reads every eligible task once inside a single total budget, so a hang cannot cost a later task its read"
}

test_the_installed_predicate_delivers_a_readiness_wake_end_to_end() {
  local home pkg result
  home="$PTMP/readiness/home"
  p_home "$home"
  record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  armed "$home" green-ship
  fixture_forge "$home" green
  fast_poll "$home"
  pkg="$PTMP/readiness/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  # The real package, real seam, and real forge reads: only the forge is a fake.
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_once_until_result "$home" || fail "the installed readiness predicate published no result for a green pull request"
  result=$(result_files "$home" | head -1)
  assert_contains "$(cat "$result")" "PR READINESS (advisory)" "the captured result carries the advisory body"
  assert_contains "$(cat "$result")" "https://github.com/acme/app/pull/7" "the advisory body names the recorded pull request"
  assert_contains "$(cat "$result")" "at head $HEAD_A" "the advisory body names the recorded head"
  assert_contains "$(cat "$result")" "not an approval, a merge, or authority to merge" \
    "the advisory body states plainly that it carries no merge authority"
  [ "$(FM_HOME="$home" "$PROCEVENT" classify "$result")" = pr-ready-advisory ] \
    || fail "the result classifies as advisory readiness evidence"
  assert_contains "$(wake_payloads "$home")" "procevent pr-green pr-green 1" \
    "Firstmate gets the existing bounded process-event wake"
  assert_contains "$(cat "$home/forge/calls.log")" "api repos/acme/app/branches/main" \
    "the end-to-end path reads the required contexts only after the rollup looks green"
  [ -z "$(find "$home/state" -name '*merge-authority*' -o -name '*.answer*' -o -name '*captain-hold*' -o -name '.pr-poll-merge-notified*')" ] \
    || fail "a readiness wake records no approval, decision answer, or merge authority"
  pass "predicate: the real readiness seam turns a fully green fixture pull request into one advisory process-event wake, and records no authority"
}

test_one_result_carries_every_simultaneously_ready_task() {
  local home pkg first second
  home="$PTMP/multi/home"
  p_home "$home"
  record "$home" a-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_A" spawn_gen=s1793000000.4200.7
  armed "$home" a-ship
  record "$home" b-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/8 pr_head="$HEAD_A" spawn_gen=s1793000000.4200.8
  armed "$home" b-ship
  fixture_forge "$home" green
  fast_poll "$home"
  pkg="$PTMP/multi/packages/pr-green"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PKG_SRC" "$pkg"
  install_package "$home" "$pkg"
  run_source_once_until_result "$home" || fail "the installed predicate published no result for two green pull requests"
  first="$home/state/procevent-inbox/pr-green.1.result"
  assert_contains "$(cat "$first")" "a-ship https://github.com/acme/app/pull/7" \
    "the result carries the advisory for the first ready task"
  assert_contains "$(cat "$first")" "b-ship https://github.com/acme/app/pull/8" \
    "the same result carries the advisory for the second simultaneously ready task"
  [ "$(grep -c 'PR READINESS (advisory)' "$first")" = 2 ] \
    || fail "one result carries exactly one advisory block per ready task: $(cat "$first")"
  FM_HOME="$home" "$PROCEVENT" handled pr-green 1 >/dev/null || fail "acknowledging the first result failed"
  # Both heads are latched now, so the next poll has nothing to say.
  start_source "$home"
  [ ! -e "$home/state/procevent-inbox/pr-green.2.result" ] \
    || fail "an acknowledged head reappeared as a fresh wake: $(cat "$home/state/procevent-inbox/pr-green.2.result")"
  # Both tasks push a new head and both go green again: the later result still
  # carries every ready pull request, so the first never crowds out the second.
  record "$home" a-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_B" spawn_gen=s1793000000.4200.7
  armed "$home" a-ship
  record "$home" b-ship kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/8 pr_head="$HEAD_B" spawn_gen=s1793000000.4200.8
  armed "$home" b-ship
  fork_pr_green_forge "$home/forge" "$HEAD_B"
  run_source_until_result "$home" "$home/state/procevent-inbox/pr-green.2.result" \
    || fail "a later poll published no result after both heads changed"
  second="$home/state/procevent-inbox/pr-green.2.result"
  assert_contains "$(cat "$second")" "a-ship https://github.com/acme/app/pull/7" \
    "the later result still carries the first ready task"
  assert_contains "$(cat "$second")" "b-ship https://github.com/acme/app/pull/8" \
    "the later result is not starved by the first ready task"
  [ "$(grep -c 'PR READINESS (advisory)' "$second")" = 2 ] \
    || fail "a re-armed result still carries one advisory block per ready task: $(cat "$second")"
  pass "multiplicity: every simultaneously ready pull request reaches the one advisory result, latched heads stay quiet, and changed heads re-arm them together"
}

fork_run_tests
