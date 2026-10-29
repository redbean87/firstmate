#!/usr/bin/env bash
# Manual live drive of the fork PR-green readiness capability against the real
# extension host, real process-event runner, real adapter, and real seam.
# Only the GitHub CLI is a disposable fixture; nothing contacts the network.
set -u
ROOT=/Users/cortezashley/.no-mistakes/worktrees/ea4b1a4b43db/01M63XJHWJ0SFD2S3J7FQ4B453
PKG_SRC=$ROOT/fork/pr-green/extension
ENTRY=$PKG_SRC/fm-pr-green.mjs
PROCEVENT=$ROOT/bin/fm-procevent.sh
EXT_HOST=$ROOT/bin/fm-extension.mjs
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222
WORK=/private/tmp/fm-live-pr-green/work
rm -rf "$WORK"; mkdir -p "$WORK"
export FM_PROCEVENT_CLAIM_ROOT="$WORK/claims"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR CURSOR_PROJECT_DIR

record() { local home=$1 id=$2; shift 2; : > "$home/state/$id.meta"; local l; for l in "$@"; do printf '%s\n' "$l" >> "$home/state/$id.meta"; done; chmod 0600 "$home/state/$id.meta"; }
armed() { printf '#!/usr/bin/env bash\n' > "$1/state/$2.check.sh"; chmod 0600 "$1/state/$2.check.sh"; }
p_home() { mkdir -p "$1/state" "$1/config" "$1/data"; }
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }

fixture_gh() {  # <home> <forge-dir>
  mkdir -p "$1/bin" "$2"
  { printf '#!/usr/bin/env bash\n';
    printf 'FAKE_GH_DIR=%q FAKE_GH_LOG=%q exec %q "$@"\n' "$2" "$2/calls.log" "$ROOT/fork/tests/pr-green-fake-gh"; } > "$1/bin/gh"
  chmod +x "$1/bin/gh"
  printf '%s\n' "$1/bin/gh" > "$1/config/pr-green-gh"
}
green_forge() {  # <forge> <head>
  mkdir -p "$1"
  jq -cn --arg head "$2" '{state:"OPEN",isDraft:false,headRefOid:$head,baseRefName:"main",
    statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS",startedAt:"2026-01-01T00:00:00Z"},
                       {__typename:"StatusContext",context:"legacy",state:"SUCCESS"}]}' > "$1/pr-view.json"
  printf '%s\n' '{"protected": false}' > "$1/branch.json"
  printf '%s\n' '[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci","integration_id":null}]}}]]' > "$1/rules.json"
}
pending_forge() {  # <forge> <head>
  mkdir -p "$1"
  jq -cn --arg head "$2" '{state:"OPEN",isDraft:false,headRefOid:$head,baseRefName:"main",
    statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"IN_PROGRESS",conclusion:""}]}' > "$1/pr-view.json"
  printf '%s\n' '{"protected": false}' > "$1/branch.json"
  printf '%s\n' '[[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci","integration_id":null}]}}]]' > "$1/rules.json"
}
fast_poll() { mkdir -p "$1/state/pr-green"; printf '100\n' > "$1/state/pr-green/poll-wait-ms"; }
install_pkg() {  # <home> <pkg-copy>
  FM_HOME="$1" "$EXT_HOST" bind "$2" --adapter pr-green --trust-same-user-code \
    --consent task-metadata --consent credential-store --consent network >/dev/null
  FM_HOME="$1" "$PROCEVENT" register-extension pr-green pr-green --config-ref "home:$1" >/dev/null
}
run_until_result() {  # <home> <file>
  local _; for _ in $(seq 1 60); do
    FM_HOME="$1" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
    [ -f "$2" ] && return 0; sleep 0.2; done; return 1
}
calls() { [ -f "$1/forge/calls.log" ] && wc -l < "$1/forge/calls.log" | tr -d ' ' || printf 0; }

say() { printf '\n=== %s ===\n' "$*"; }

########################################################################
say "S1: green PR -> one advisory wake (real host + runner + adapter)"
home=$WORK/s1; p_home "$home"
record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/7 pr_head=$HEAD_A
armed "$home" green-ship
fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
pkg=$WORK/s1-pkg; mkdir -p "$(dirname "$pkg")"; cp -R "$PKG_SRC" "$pkg"
install_pkg "$home" "$pkg"
run_until_result "$home" "$home/state/procevent-inbox/pr-green.1.result" || { echo "NO RESULT"; exit 1; }
echo "--- captured result body ---"
cat "$home/state/procevent-inbox/pr-green.1.result"
echo "--- wake queue ---"
cat "$home/state/.wake-queue"
echo "--- classify ---"
FM_HOME="$home" "$PROCEVENT" classify "$home/state/procevent-inbox/pr-green.1.result"
echo "--- forge calls ---"; cat "$home/forge/calls.log"
echo "--- authority/decision records (expect none) ---"
find "$home/state" \( -name '*merge-authority*' -o -name '*.answer*' -o -name '*captain-hold*' -o -name '.pr-poll-merge-notified*' \) -print
echo "--- task record unchanged? ---"
shasum -a 256 "$home/state/green-ship.meta"

########################################################################
say "S2: pending check -> silence, one read, no required read"
home=$WORK/s2; p_home "$home"
record "$home" pending-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/7 pr_head=$HEAD_A
armed "$home" pending-ship
fixture_gh "$home" "$home/forge"; pending_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
: > "$home/forge/calls.log"
out=$(printf '%s' "$(jq -cn --arg rid "sha256:$(printf '3%.0s' $(seq 1 64))" --arg ref "home:$home" '{schema:"firstmate.extension-request.v1",request_id:$rid,host_protocol:1,extension_id:"org.firstmate.fork.pr-green",extension_version:"0.2.0",package_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000",capability:"process-event-adapter",capability_version:1,adapter:"pr-green",operation:"source.poll",input:{source_id:"pr-green",config_ref:$ref}}')" | node "$ENTRY" invoke 2>"$WORK/s2.err")
echo "$out" | jq -c .result
echo "--- seam log ---"; cat "$WORK/s2.err"
echo "--- forge calls (expect 1, pr view only) ---"; cat "$home/forge/calls.log"

########################################################################
say "S3: green rollup + unreadable required-context source -> silence"
for breakage in fail-rules fail-branch raw-rules-malformed no-rules-answer; do
  home=$WORK/s3-$breakage; p_home "$home"
  record "$home" src-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/7 pr_head=$HEAD_A
  armed "$home" src-ship
  fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
  case $breakage in
    fail-rules) : > "$home/forge/fail-rules" ;;
    fail-branch) : > "$home/forge/fail-branch" ;;
    raw-rules-malformed) printf 'not json\n' > "$home/forge/raw-rules" ;;
    no-rules-answer) rm -f "$home/forge/rules.json" ;;
  esac
  : > "$home/forge/calls.log"
  out=$(jq -cn --arg rid "sha256:$(printf '3%.0s' $(seq 1 64))" --arg ref "home:$home" '{schema:"firstmate.extension-request.v1",request_id:$rid,host_protocol:1,extension_id:"org.firstmate.fork.pr-green",extension_version:"0.2.0",package_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000",capability:"process-event-adapter",capability_version:1,adapter:"pr-green",operation:"source.poll",input:{source_id:"pr-green",config_ref:$ref}}' | node "$ENTRY" invoke 2>"$WORK/$breakage.err")
  printf '%-20s status=%s output=%s  reads=%s  reason=%s\n' "$breakage" \
    "$(printf '%s' "$out" | jq -r .result.status)" "$(printf '%s' "$out" | jq -r .result.output)" \
    "$(calls "$home")" "$(grep -o 'not-ready [^ ]* .*' "$WORK/$breakage.err" | head -1)"
done

########################################################################
say "S4: head mismatch / closed / draft -> silence"
for shape in head-mismatch closed draft no-draft-flag; do
  home=$WORK/s4-$shape; p_home "$home"
  record "$home" life-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/7 pr_head=$HEAD_A
  armed "$home" life-ship
  fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
  case $shape in
    head-mismatch) green_forge "$home/forge" "$HEAD_B" ;;
    closed) jq '.state="CLOSED"' "$home/forge/pr-view.json" > "$home/pv" && mv "$home/pv" "$home/forge/pr-view.json" ;;
    draft) jq '.isDraft=true' "$home/forge/pr-view.json" > "$home/pv" && mv "$home/pv" "$home/forge/pr-view.json" ;;
    no-draft-flag) jq 'del(.isDraft)' "$home/forge/pr-view.json" > "$home/pv" && mv "$home/pv" "$home/forge/pr-view.json" ;;
  esac
  out=$(jq -cn --arg rid "sha256:$(printf '3%.0s' $(seq 1 64))" --arg ref "home:$home" '{schema:"firstmate.extension-request.v1",request_id:$rid,host_protocol:1,extension_id:"org.firstmate.fork.pr-green",extension_version:"0.2.0",package_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000",capability:"process-event-adapter",capability_version:1,adapter:"pr-green",operation:"source.poll",input:{source_id:"pr-green",config_ref:$ref}}' | node "$ENTRY" invoke 2>"$WORK/s4-$shape.err")
  printf '%-16s status=%s output=%s  reason=%s\n' "$shape" "$(printf '%s' "$out" | jq -r .result.status)" \
    "$(printf '%s' "$out" | jq -r .result.output)" "$(grep -o 'not-ready [^ ]* .*' "$WORK/s4-$shape.err" | head -1)"
done

########################################################################
say "S5: out-of-scope records are refused before any forge read"
home=$WORK/s5; p_home "$home"
record "$home" green-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/7 pr_head=$HEAD_A; armed "$home" green-ship
record "$home" yolo-off kind=ship harness=pi mode=no-mistakes yolo=off pr=https://github.com/acme/app/pull/8 pr_head=$HEAD_A; armed "$home" yolo-off
record "$home" gitlab-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://gitlab.com/acme/app/-/merge_requests/3 pr_head=$HEAD_A; armed "$home" gitlab-ship
record "$home" gerrit-ship kind=ship harness=pi mode=no-mistakes yolo=on pr=https://review.example.com/c/acme/app/+/12345 pr_head=$HEAD_A; armed "$home" gerrit-ship
record "$home" unlisted-gh kind=ship harness=pi mode=no-mistakes yolo=on pr=https://ghe.other.example/acme/app/pull/9 pr_head=$HEAD_A; armed "$home" unlisted-gh
record "$home" not-armed kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/10 pr_head=$HEAD_A
fixture_gh "$home" "$home/forge"; pending_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
: > "$home/forge/calls.log"
jq -cn --arg rid "sha256:$(printf '3%.0s' $(seq 1 64))" --arg ref "home:$home" '{schema:"firstmate.extension-request.v1",request_id:$rid,host_protocol:1,extension_id:"org.firstmate.fork.pr-green",extension_version:"0.2.0",package_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000",capability:"process-event-adapter",capability_version:1,adapter:"pr-green",operation:"source.poll",input:{source_id:"pr-green",config_ref:$ref}}' | node "$ENTRY" invoke 2>"$WORK/s5.err" >/dev/null
echo "--- gate decisions ---"; grep -E 'pr-green: (eligible|skipped)' "$WORK/s5.err"
echo "--- forge reads for the whole out-of-scope set ---"; cat "$home/forge/calls.log"

########################################################################
say "S6: one poll announces every simultaneously ready PR in one result"
home=$WORK/s6; p_home "$home"
for pair in "a-ship 7" "b-ship 8" "c-ship 9"; do
  id=${pair% *}; num=${pair#* }
  record "$home" "$id" kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/$num pr_head=$HEAD_A
  armed "$home" "$id"
done
fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
pkg=$WORK/s6-pkg; mkdir -p "$(dirname "$pkg")"; cp -R "$PKG_SRC" "$pkg"
install_pkg "$home" "$pkg"
run_until_result "$home" "$home/state/procevent-inbox/pr-green.1.result" || { echo "NO RESULT"; exit 1; }
echo "--- one result, every ready PR ---"
grep -o 'PR READINESS (advisory): [^ ]* https://[^ ]* at head [0-9a-f]*' "$home/state/procevent-inbox/pr-green.1.result"
echo "advisory blocks: $(grep -c 'PR READINESS (advisory)' "$home/state/procevent-inbox/pr-green.1.result")"
echo "--- acknowledge, then the next poll ---"
FM_HOME="$home" "$PROCEVENT" handled pr-green 1 >/dev/null
run_until_result "$home" "$home/state/procevent-inbox/pr-green.2.result" || { echo "NO SECOND RESULT"; exit 1; }
echo "adv blocks in sequence 2: $(grep -c 'PR READINESS (advisory)' "$home/state/procevent-inbox/pr-green.2.result")"

########################################################################
say "S7: fair split - three hanging reads, every entry still read inside one budget"
home=$WORK/s7; p_home "$home"
for pair in "a-ship 7" "b-ship 8" "c-ship 9"; do
  id=${pair% *}; num=${pair#* }
  record "$home" "$id" kind=ship harness=pi mode=no-mistakes yolo=on pr=https://github.com/acme/app/pull/$num pr_head=$HEAD_A
  armed "$home" "$id"
done
fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"; fast_poll "$home"
mkdir -p "$home/state/pr-green"; printf '4000\n' > "$home/state/pr-green/read-budget-ms"
printf '30\n' > "$home/forge/hang-pr-view"
: > "$home/forge/calls.log"
started=$(now_ms)
out=$(jq -cn --arg rid "sha256:$(printf '3%.0s' $(seq 1 64))" --arg ref "home:$home" '{schema:"firstmate.extension-request.v1",request_id:$rid,host_protocol:1,extension_id:"org.firstmate.fork.pr-green",extension_version:"0.2.0",package_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000",capability:"process-event-adapter",capability_version:1,adapter:"pr-green",operation:"source.poll",input:{source_id:"pr-green",config_ref:$ref}}' | node "$ENTRY" invoke 2>/dev/null)
elapsed=$(( $(now_ms) - started ))
echo "status=$(printf '%s' "$out" | jq -r .result.status) output='$(printf '%s' "$out" | jq -r .result.output)'"
echo "reads=$(calls "$home") elapsed=${elapsed}ms budget=4000ms"
cat "$home/forge/calls.log"

########################################################################
say "S8: advisory body wording for 0 and 1 required checks (seam output)"
for shape in zero one; do
  home=$WORK/s8-$shape; p_home "$home"
  fixture_gh "$home" "$home/forge"; green_forge "$home/forge" "$HEAD_A"
  case $shape in
    zero) printf '%s\n' '[[{"type":"deletion"}]]' > "$home/forge/rules.json" ;;
    one) : ;;  # the shared green fixture already requires exactly one check
  esac
  jq -cn --arg home "$home" --arg state "$home/state" --arg config "$home/config" \
    '{home:$home,stateDir:$state,configDir:$config,now:0,evaluateCount:1}' > "$WORK/ctx-$shape.json"
  entry=$WORK/entry-$shape.json
  jq -cn --arg head "$HEAD_A" '{id:"wording-task",mode:"no-mistakes",yolo:"on",kind:"ship",pr:"https://github.com/acme/app/pull/7",host:"github.com",owner:"acme",repo:"app",number:"7",head:$head,meta:"/fixture/state/none.meta"}' > "$entry"
  cat > "$WORK/seam-driver.mjs" <<'JS'
import fs from "node:fs";
const { decideWake } = await import(process.argv[2]);
const entry = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const ctx = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
ctx.log = (line) => process.stderr.write(`${line}\n`);
process.stdout.write(`${JSON.stringify(decideWake(entry, ctx))}\n`);
JS
  printf '%-6s ' "$shape"
  node "$WORK/seam-driver.mjs" "$ROOT/fork/pr-green/extension/readiness.mjs" "$entry" "$WORK/ctx-$shape.json" 2>/dev/null \
    | jq -r '.advisory // "SILENT"'
done

echo
echo "DONE"
