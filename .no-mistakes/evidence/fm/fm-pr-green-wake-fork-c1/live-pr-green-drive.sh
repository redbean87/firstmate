#!/usr/bin/env bash
# Live drive of the fork PR-green extension against the real product surfaces:
# bin/fm-extension.mjs (binding host + process-event protocol), the shipped
# adapter fork/pr-green/extension/fm-pr-green.mjs, and bin/fm-procevent.sh
# (register / start / reconcile / classify / handled / list).
#
# Disposable marked lab homes only; no network, no real fleet state, no
# operator home. Every lab is removed at the end of this script.
set -u
ROOT=${ROOT:?}
EV=${EV:?}

PASS=0
FAIL=0
TOKEN=
ok()   { PASS=$((PASS+1)); printf 'ok - %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$*"; }
check(){ # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}
contains(){ # <description> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (missing [$2])" ;; esac
}
assert_absent(){ # <description> <path>
  if [ -e "$2" ]; then bad "$1 (present: $2)"; else ok "$1"; fi
}
assert_present(){ # <description> <path>
  if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi
}

PKG_SRC="$ROOT/fork/pr-green/extension"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
EXT_HOST="$ROOT/bin/fm-extension.mjs"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222

LABS=()
NEW_LAB=''
# new_lab <name>: mint one marked disposable lab home and set NEW_LAB.
# Registered in the parent shell (not a subshell) so the EXIT trap tears down
# every base it created.
new_lab() {
  local base name=$1 lab
  base=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || return 1
  # Canonical, symlink-free, normalized path: the host refuses a package root or
  # config_ref that traverses a symlink or is not normalized (/var -> /private/var).
  base=$(cd "$base" && pwd -P) || return 1
  lab="$base/$name"
  mkdir -p "$lab"
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || return 1
  LABS+=("$base")
  NEW_LAB=$lab
}
# The extension host materializes its content-addressed package store read-only
# (0555 directories) as intentional hardening, so the lab is restored to
# owner-writable before removal.
cleanup() {
  local b
  for b in "${LABS[@]:-}"; do
    [ -n "$b" ] || continue
    chmod -R u+w "$b" 2>/dev/null
    rm -rf "$b"
  done
}
trap cleanup EXIT

fast_poll() { mkdir -p "$1/state/pr-green"; printf '300\n' > "$1/state/pr-green/poll-wait-ms"; }

# record <home> <id> <key=value>...: one upstream task record.
record() {
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.meta"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  chmod 0600 "$home/state/$id.meta"
}
armed() { printf '#!/usr/bin/env bash\n' > "$1/state/$2.check.sh"; chmod 0600 "$1/state/$2.check.sh"; }

poll_request() { # <config-ref>
  jq -cn --arg ref "$1" '{schema: "firstmate.extension-request.v1",
    request_id: ("sha256:" + ("3" * 64)), host_protocol: 1,
    extension_id: "org.firstmate.fork.pr-green", extension_version: "0.1.0",
    package_digest: ("sha256:" + ("0" * 64)), capability: "process-event-adapter",
    capability_version: 1, adapter: "pr-green", operation: "source.poll",
    input: {source_id: "pr-green", config_ref: $ref}}'
}

results() { local f; for f in "$1"/state/procevent-inbox/pr-green.*.result; do [ -f "$f" ] && printf '%s\n' "$f"; done; }

start_until_result() { # <home>
  local home=$1 i
  for i in $(seq 1 50); do
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$PROCEVENT" start pr-green >/dev/null 2>&1 || true
    [ -n "$(results "$home")" ] && return 0
    sleep 0.2
  done
  return 1
}

install_package() { # <home> <package-root> [config-ref]  -> sets TOKEN
  local home=$1 pkg=$2 ref=${3:-} reg
  FM_HOME="$home" "$EXT_HOST" bind "$pkg" --adapter pr-green --trust-same-user-code --consent task-metadata >/dev/null \
    || { bad "bind $pkg"; return 1; }
  reg=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" "$PROCEVENT" register-extension pr-green pr-green --config-ref "${ref:-home:$home}") \
    || { bad "register $pkg"; return 1; }
  TOKEN=$(printf '%s\n' "$reg" | sed -n 's/^owner-token: //p')
  [ -n "$TOKEN" ]
}

# Fixture home: three authorized armed GitHub PRs plus every refused shape.
build_gate_home() {
  local home=$1
  record "$home" ok-nomistakes kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/7 pr_head="$HEAD_A"; armed "$home" ok-nomistakes
  record "$home" ok-directpr kind=ship harness=pi mode=direct-PR yolo=on \
    pr=https://github.com/acme/app/pull/8 pr_head="$HEAD_B"; armed "$home" ok-directpr
  printf 'ghe.corp.example\n' > "$home/config/github-hosts"
  record "$home" ok-enterprise kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://ghe.corp.example/acme/app/pull/9 pr_head="$HEAD_A"; armed "$home" ok-enterprise
  record "$home" mr-gitlab kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://gitlab.com/acme/app/-/merge_requests/3 pr_head="$HEAD_A"; armed "$home" mr-gitlab
  record "$home" change-gerrit kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://review.example.com/c/acme/app/+/12345 pr_head="$HEAD_A"; armed "$home" change-gerrit
  record "$home" forgejo kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://code.example.com/acme/app/pulls/4 pr_head="$HEAD_A"; armed "$home" forgejo
  record "$home" yolo-off kind=ship harness=pi mode=no-mistakes yolo=off \
    pr=https://github.com/acme/app/pull/10 pr_head="$HEAD_A"; armed "$home" yolo-off
  record "$home" local-only kind=ship harness=pi mode=local-only yolo=on \
    pr=https://github.com/acme/app/pull/11 pr_head="$HEAD_A"; armed "$home" local-only
  record "$home" mate kind=secondmate mode=secondmate yolo=off
  record "$home" no-head kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/12; armed "$home" no-head
  record "$home" bad-head kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/13 pr_head=abc123; armed "$home" bad-head
  record "$home" not-armed kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/14 pr_head="$HEAD_A"
  record "$home" ghe-unlisted kind=ship harness=pi mode=no-mistakes yolo=on \
    pr=https://other.corp.example/acme/app/pull/15 pr_head="$HEAD_A"; armed "$home" ghe-unlisted
  record "$home" duplicated kind=ship mode=no-mistakes yolo=on mode=direct-PR \
    pr=https://github.com/acme/app/pull/16 pr_head="$HEAD_A"; armed "$home" duplicated
  armed "$home" linked
  printf '%s\n' kind=ship mode=no-mistakes yolo=on \
    pr=https://github.com/acme/app/pull/17 pr_head="$HEAD_A" > "$home/config/linked-target.meta"
  ln -s ../config/linked-target.meta "$home/state/linked.meta"
  fast_poll "$home"
}

printf '########## scenario 1+2: scope gate and silence of the shipped package\n'
new_lab gate || { bad "could not mint lab home"; exit 1; }
LAB_A=$NEW_LAB
build_gate_home "$LAB_A"
before=$(find "$LAB_A" -type f | sort)
out=$(poll_request "home:$LAB_A" | node "$PKG_SRC/fm-pr-green.mjs" invoke 2>"$EV/gate-stderr.log")
check "poll envelope ok" true "$(printf '%s' "$out" | jq -r .ok)"
check "shipped package stays silent (no-result)" no-result "$(printf '%s' "$out" | jq -r .result.status)"
check "no-result carries no output" "" "$(printf '%s' "$out" | jq -r .result.output)"
check "exactly three eligible records" 3 "$(grep -c '^pr-green: eligible ' "$EV/gate-stderr.log")"
for id in ok-nomistakes ok-directpr ok-enterprise; do
  contains "eligible $id" "pr-green: eligible $id" "$(cat "$EV/gate-stderr.log")"
done
for skip in "mr-gitlab unsupported-provider" "change-gerrit unsupported-provider" \
  "forgejo unsupported-provider" "yolo-off yolo-off" "local-only mode-local-only" \
  "mate secondmate" "no-head no-pr-head" "bad-head pr-head-invalid" \
  "not-armed not-armed" "ghe-unlisted host-not-listed" "duplicated record-unreadable" \
  "linked record-unreadable"; do
  contains "refused $skip" "pr-green: skipped $skip" "$(cat "$EV/gate-stderr.log")"
done
after=$(find "$LAB_A" -type f | sort)
check "a silent poll writes nothing" "$before" "$after"

# Registration exactly as fork/pr-green/README documents it, against that home.
# A bound package must live outside the home it serves, as upstream requires.
cp -R "$PKG_SRC" "$(dirname "$LAB_A")/packages-gate"
install_package "$LAB_A" "$(dirname "$LAB_A")/packages-gate" || true
assert_present "source registered" "$LAB_A/state/procevent/pr-green.source"
FM_HOME="$LAB_A" FM_PROCEVENT_CLAIM_ROOT="$LAB_A/claims" "$PROCEVENT" list >"$EV/list-registered.txt" 2>&1 || true
contains "list reports the registered source" "pr-green" "$(cat "$EV/list-registered.txt")"
FM_HOME="$LAB_A" FM_PROCEVENT_CLAIM_ROOT="$LAB_A/claims" "$PROCEVENT" start pr-green >"$EV/start-silent.txt" 2>&1 || true
check "registered shipped package captures no result" "" "$(results "$LAB_A")"
check "registered shipped package publishes no wake" "" "$(cat "$LAB_A/state/.wake-queue" 2>/dev/null)"
assert_present "silent source stays registered for the next poll" "$LAB_A/state/procevent/pr-green.source"
assert_absent "no readiness evidence captured" "$LAB_A/state/procevent-inbox/pr-green.1.result"

printf '\n########## scenario 3: an advisory readiness body wakes firstmate, advisory by construction\n'
new_lab delivery || { bad "could not mint lab home"; exit 1; }
LAB_B=$NEW_LAB
build_gate_home "$LAB_B"
SEAMLAB="$(dirname "$LAB_B")/packages-delivery"
cp -R "$PKG_SRC" "$SEAMLAB"
# The documented seam fill: replace extension/readiness.mjs only.
cat > "$SEAMLAB/readiness.mjs" <<'JS'
import fs from "node:fs";
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
before_meta=$(shasum -a 256 "$LAB_B"/state/*.meta | sort)
install_package "$LAB_B" "$SEAMLAB" || true
token=$TOKEN
start_until_result "$LAB_B" || bad "the runner published no readiness result"
result=$(results "$LAB_B" | head -1)
cp "$result" "$EV/delivery-result.txt"
cat "$EV/delivery-result.txt" >> /dev/null
contains "captured result carries the advisory body" "PR READINESS (advisory)" "$(cat "$result")"
contains "advisory body names the pull request" "https://github.com/acme/app/pull/7" "$(cat "$result")"
contains "advisory body names the recorded head" "at head $HEAD_A" "$(cat "$result")"
contains "Firstmate gets the bounded process-event wake" "procevent pr-green pr-green 1" \
  "$(cat "$LAB_B/state/.wake-queue" 2>/dev/null)"
classify_out=$(FM_HOME="$LAB_B" FM_PROCEVENT_CLAIM_ROOT="$LAB_B/claims" "$PROCEVENT" classify "$result" 2>&1)
check "a readiness body classifies as pr-ready-advisory" "pr-ready-advisory" "$classify_out"
check "seam offered exactly the authorized tasks" \
  "$(printf 'ok-directpr\nok-enterprise\nok-nomistakes')" "$(sort -u "$LAB_B/seam-observed.txt")"
: > "$LAB_B/state/.wake-queue"
FM_HOME="$LAB_B" FM_PROCEVENT_CLAIM_ROOT="$LAB_B/claims" "$PROCEVENT" reconcile >/dev/null 2>&1
contains "unhandled wake is re-announced" "procevent pr-green pr-green 1" "$(cat "$LAB_B/state/.wake-queue" 2>/dev/null)"
FM_HOME="$LAB_B" FM_PROCEVENT_CLAIM_ROOT="$LAB_B/claims" "$PROCEVENT" handled pr-green 1 >/dev/null 2>&1 \
  && ok "handled acknowledgement accepted" || bad "handled acknowledgement failed"
: > "$LAB_B/state/.wake-queue"
FM_HOME="$LAB_B" FM_PROCEVENT_CLAIM_ROOT="$LAB_B/claims" "$PROCEVENT" reconcile >/dev/null 2>&1
check "a handled wake is not re-announced" "" "$(cat "$LAB_B/state/.wake-queue" 2>/dev/null)"
check "the readiness path rewrites no task record" "$before_meta" "$(shasum -a 256 "$LAB_B"/state/*.meta | sort)"
check "no decision answer, merge authority, or captain hold written" "" \
  "$(find "$LAB_B/state" \( -name '*.answer*' -o -name '*merge-authority*' -o -name '*captain-hold*' \) -print)"
FM_HOME="$LAB_B" FM_PROCEVENT_CLAIM_ROOT="$LAB_B/claims" "$PROCEVENT" retire pr-green --if-owner "$token" >/dev/null 2>&1 \
  && ok "owner token retires the source" || bad "retire failed"
assert_absent "retired source record removed" "$LAB_B/state/procevent/pr-green.source"

printf '\n########## scenario 4: an unreadable readiness read is captured as error evidence, not readiness\n'
new_lab classify || { bad "could not mint lab home"; exit 1; }
LAB_C=$NEW_LAB
fast_poll "$LAB_C"
OTHER="$LAB_C/unusable-home"
mkdir -p "$OTHER"   # home exists; state/ is missing, so the read cannot run
cp -R "$PKG_SRC" "$(dirname "$LAB_C")/packages-classify"
install_package "$LAB_C" "$(dirname "$LAB_C")/packages-classify" "home:$OTHER" || true
start_until_result "$LAB_C" || bad "no evidence captured for an unreadable readiness read"
err_result=$(results "$LAB_C" | head -1)
cp "$err_result" "$EV/error-result.txt"
contains "captured body is host failure evidence" '"schema":"firstmate.process-event-extension-error.v1"' "$(cat "$err_result")"
err_classify=$(FM_HOME="$LAB_C" FM_PROCEVENT_CLAIM_ROOT="$LAB_C/claims" "$PROCEVENT" classify "$err_result" 2>&1)
check "failure evidence classifies as pr-ready-error" "pr-ready-error" "$err_classify"

printf '\n########## scenario 5: fail-closed adversarial inputs stay silent or answer with an error\n'
new_lab failclosed || { bad "could not mint lab home"; exit 1; }
LAB_D=$NEW_LAB
build_gate_home "$LAB_D"
for ref in "$LAB_D" "home:$LAB_D/../nowhere" "home:relative/path" "home:/"; do
  out=$(poll_request "$ref" | node "$PKG_SRC/fm-pr-green.mjs" invoke 2>/dev/null)
  check "config_ref [$ref] is refused as an invalid request" \
    "invalid-request" "$(printf '%s' "$out" | jq -r '.error.code // .result.status')"
  check "config_ref [$ref] answers no result" "null" "$(printf '%s' "$out" | jq -r .result)"
done
out=$(poll_request "home:$LAB_D" | node "$PKG_SRC/fm-pr-green.mjs" invoke 2>/dev/null)
EMPTYHOME="$LAB_D/empty-home"; mkdir -p "$EMPTYHOME"
out=$(poll_request "home:$EMPTYHOME" | node "$PKG_SRC/fm-pr-green.mjs" invoke 2>/dev/null)
check "a home without a state directory is unavailable" unavailable "$(printf '%s' "$out" | jq -r .error.code)"
check "...and answers no result" "null" "$(printf '%s' "$out" | jq -r .result)"

# Seam bodies that are not a usable advisory are silence, never a claim of green.
SEAMLESS="$(dirname "$LAB_D")/packages-failclosed"
cp -R "$PKG_SRC" "$SEAMLESS"
cat > "$SEAMLESS/readiness.mjs" <<'JS'
export function decideWake() { return { advisory: "   " }; }
JS
out=$(poll_request "home:$LAB_D" | node "$SEAMLESS/fm-pr-green.mjs" invoke 2>"$EV/seam-empty.log")
check "an empty advisory body stays silent" no-result "$(printf '%s' "$out" | jq -r .result.status)"
contains "empty body is named as seam-invalid" "seam-invalid" "$(cat "$EV/seam-empty.log")"
cat > "$SEAMLESS/readiness.mjs" <<'JS'
export function decideWake() { return { advisory: "x".repeat(40000) }; }
JS
out=$(poll_request "home:$LAB_D" | node "$SEAMLESS/fm-pr-green.mjs" invoke 2>"$EV/seam-oversized.log")
check "an oversized advisory body stays silent" no-result "$(printf '%s' "$out" | jq -r .result.status)"
contains "oversized body is named as seam-invalid" "seam-invalid" "$(cat "$EV/seam-oversized.log")"

# A seam that throws becomes an adapter failure record, never a green wake.
new_lab throwing || { bad "could not mint lab home"; exit 1; }
LAB_E=$NEW_LAB
build_gate_home "$LAB_E"
THROWLAB="$(dirname "$LAB_E")/packages-throwing"
cp -R "$PKG_SRC" "$THROWLAB"
cat > "$THROWLAB/readiness.mjs" <<'JS'
export function decideWake() { throw new Error("readiness read failed"); }
JS
install_package "$LAB_E" "$THROWLAB" || true
start_until_result "$LAB_E" || bad "no evidence captured for a throwing readiness read"
throw_result=$(results "$LAB_E" | head -1)
cp "$throw_result" "$EV/throwing-result.txt"
throw_classify=$(FM_HOME="$LAB_E" FM_PROCEVENT_CLAIM_ROOT="$LAB_E/claims" "$PROCEVENT" classify "$throw_result" 2>&1)
check "a throwing readiness seam classifies as pr-ready-error" "pr-ready-error" "$throw_classify"

printf '\n########## scenario 6: the seam contract the package documents is what it supplies\n'
new_lab contract || { bad "could not mint lab home"; exit 1; }
LAB_F=$NEW_LAB
build_gate_home "$LAB_F"
CONTRACTLAB="$(dirname "$LAB_F")/packages-contract"
cp -R "$PKG_SRC" "$CONTRACTLAB"
cat > "$CONTRACTLAB/readiness.mjs" <<'JS'
import fs from "node:fs";
export function decideWake(entry, ctx) {
  fs.writeFileSync(`${ctx.home}/seam-contract.json`, JSON.stringify({
    entryKeys: Object.keys(entry).sort(),
    ctxKeys: Object.keys(ctx).sort(),
    owner: entry.owner, repo: entry.repo, number: entry.number,
    hasPathKey: Object.prototype.hasOwnProperty.call(entry, "path"),
    mode: entry.mode, yolo: entry.yolo, pr: entry.pr, head: entry.head,
    metaIsPath: typeof entry.meta === "string" && entry.meta.startsWith(ctx.stateDir),
  }));
  return null;
}
JS
poll_request "home:$LAB_F" | node "$CONTRACTLAB/fm-pr-green.mjs" invoke >"$EV/seam-contract-poll.json" 2>/dev/null
cp "$LAB_F/seam-contract.json" "$EV/seam-contract.json" 2>/dev/null || bad "the seam recorded nothing"
check "the seam receives exactly the documented entry keys" \
  '["head","host","id","kind","meta","mode","number","owner","pr","repo","yolo"]' \
  "$(jq -c '.entryKeys' "$EV/seam-contract.json" 2>/dev/null)"
check "the seam receives no undocumented path key" false "$(jq -r '.hasPathKey' "$EV/seam-contract.json" 2>/dev/null)"
check "the seam receives the parsed pull request identity" \
  "acme app 7" "$(jq -r '"\(.owner) \(.repo) \(.number)"' "$EV/seam-contract.json" 2>/dev/null)"
check "the seam receives the documented ctx keys" \
  '["configDir","home","log","now","stateDir"]' "$(jq -c '.ctxKeys' "$EV/seam-contract.json" 2>/dev/null)"
check "entry.meta is inside the home's state directory" true "$(jq -r '.metaIsPath' "$EV/seam-contract.json" 2>/dev/null)"

# An advisory body that cannot survive JSON encoding becomes host failure
# evidence, never a green wake.
new_lab surrogate || { bad "could not mint lab home"; exit 1; }
LAB_G=$NEW_LAB
build_gate_home "$LAB_G"
SURROGATELAB="$(dirname "$LAB_G")/packages-surrogate"
cp -R "$PKG_SRC" "$SURROGATELAB"
cat > "$SURROGATELAB/readiness.mjs" <<'JS'
export function decideWake(entry) {
  return { advisory: `PR READINESS (advisory): ${entry.pr} at head ${entry.head}\uD800` };
}
JS
install_package "$LAB_G" "$SURROGATELAB" || true
start_until_result "$LAB_G" || bad "no evidence captured for an unencodable advisory body"
surrogate_result=$(results "$LAB_G" | head -1)
cp "$surrogate_result" "$EV/surrogate-result.txt" 2>/dev/null
contains "an unencodable body is captured as host failure evidence" "json-invalid" "$(cat "$surrogate_result" 2>/dev/null)"
surrogate_classify=$(FM_HOME="$LAB_G" FM_PROCEVENT_CLAIM_ROOT="$LAB_G/claims" "$PROCEVENT" classify "$surrogate_result" 2>&1)
check "an unencodable body never classifies as readiness advice" "pr-ready-error" "$surrogate_classify"

printf '\n########## summary: %s checks passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
