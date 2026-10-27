#!/usr/bin/env bash
# fm-chatgpt-plan-validate.sh - check one ChatGPT plan-stage reply against the
# implementation-plan contract, version 1.
# Usage: fm-chatgpt-plan-validate.sh --reply-file FILE --findings-file FILE [--cited]
#
# fork/chatgpt/plan-contract.template is the single owner of the contract and
# its numbered rules (P1-P12); this script enforces them and holds no second
# statement of what they mean. Every refusal names its rule.
#
# The reply is the raw model answer. On success the plan object from its one
# fenced json block is printed to stdout as compact JSON, key order kept, and
# nothing else. On a rule refusal stdout stays empty, stderr carries
# "plan rule P<n>: <reason>", and the exit is 1. A usage error or a missing
# jq exits 2.
#
# --findings-file is the recorded audit findings the plan's basis entries are
# checked against (P11): the finding ids are the A<n> tokens in that text.
# --cited says the findings came from a cited prior audit rather than a
# dispatched audit worker; only then, and only when those findings carry no
# finding ids at all, is the `none: <reason>` basis accepted.
#
# This checks shape only. It never runs, resolves, or judges a verification
# command, so a valid plan is not evidence that any command exists or passes.
set -u

REPLY="" FINDINGS="" CITED=0
usage() {
  printf 'usage: %s --reply-file FILE --findings-file FILE [--cited]\n' "$(basename "$0")" >&2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --reply-file) [ $# -ge 2 ] || { usage; exit 2; }; REPLY=$2; shift 2 ;;
    --findings-file) [ $# -ge 2 ] || { usage; exit 2; }; FINDINGS=$2; shift 2 ;;
    --cited) CITED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$REPLY" ] && [ -f "$REPLY" ] || { printf 'fm-chatgpt-plan: --reply-file must name an existing file\n' >&2; usage; exit 2; }
[ -n "$FINDINGS" ] && [ -f "$FINDINGS" ] || { printf 'fm-chatgpt-plan: --findings-file must name an existing file\n' >&2; usage; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'fm-chatgpt-plan: plan validation needs jq\n' >&2; exit 2; }

MAX_BYTES=65536

refuse() {
  printf 'fm-chatgpt-plan: plan rule %s\n' "$1" >&2
  exit 1
}

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
BLOCK="$WORK/block.json"

# P1: a fence opens on a line starting with three backticks and closes on a
# line of exactly three backticks (trailing spaces allowed); a backtick line
# inside an open block that carries an info string is block content.
summary=$(awk -v out="$BLOCK" '
  BEGIN { inside = 0; n = 0 }
  {
    if (!inside && $0 ~ /^```/) {
      n++
      info = substr($0, 4)
      gsub(/^[ \t]+|[ \t]+$/, "", info)
      infos[n] = info
      inside = 1
      next
    }
    if (inside && $0 ~ /^```[ \t]*$/) { inside = 0; next }
    if (inside && n == 1) print > out
  }
  END {
    # The label goes last: it may be empty, and read would otherwise shift
    # the fields after it.
    printf "%d %s %s\n", n, (inside ? "open" : "closed"), (n >= 1 ? infos[1] : "")
  }
' "$REPLY") || exit 2
read -r count state info <<<"$summary"
[ "$count" -eq 1 ] || refuse "P1: the reply must hold exactly one fenced block, found $count"
[ -n "$info" ] || refuse "P1: the fenced block has no language label; it must open with a line of exactly \`\`\`json"
[ "$info" = json ] || refuse "P1: the fenced block must be labelled json, found '${info}'"
[ "$state" = closed ] || refuse "P1: the fenced json block is not closed"
[ -f "$BLOCK" ] || : > "$BLOCK"

size=$(wc -c < "$BLOCK" | tr -d ' ')
[ "$size" -le "$MAX_BYTES" ] || refuse "P2: the plan block is $size bytes, over the $MAX_BYTES-byte limit"

jq -e -s 'length == 1 and (.[0] | type == "object")' "$BLOCK" >/dev/null 2>&1 \
  || refuse "P3: the plan block must parse as exactly one JSON object"

# Finding ids are A<n> tokens in the recorded findings, bounded by anything
# that is not a letter, digit, or underscore.
IDS=$(tr -c 'A-Za-z0-9_' '\n' < "$FINDINGS" | grep -E '^A[1-9][0-9]*$' | sort -u | jq -R . | jq -s -c .) || exit 2
ALLOW_NONE=false
if [ "$CITED" -eq 1 ] && [ "$IDS" = "[]" ]; then
  ALLOW_NONE=true
fi

# shellcheck disable=SC2016 # jq program, not shell expansion
err=$(jq -r --argjson ids "$IDS" --argjson allow_none "$ALLOW_NONE" '
  def nes: type == "string" and test("\\S");
  def strs: type == "array" and all(.[]; nes);
  def strs1: strs and length >= 1;
  def keyset($want): (keys | sort) == ($want | sort);
  # A line break or control character: C0 controls (tab, CR, and LF
  # included), DEL, C1 controls, and the Unicode line and paragraph separators.
  def unsafe_char: explode | any(.[]; . < 32 or (. >= 127 and . <= 159) or . == 8232 or . == 8233);
  def first_unsafe_path:
    [paths(type == "string") as $p | select(getpath($p) | unsafe_char) | $p] | .[0];
  def task_error($i):
    . as $t
    | ($i + 1) as $n
    | if type != "object" then "P5: task \($n) must be an object"
      elif (keyset(["id", "title", "basis", "depends_on", "steps", "acceptance_criteria", "verification"]) | not) then
        "P5: task \($n) must have exactly the keys id, title, basis, depends_on, steps, acceptance_criteria, verification (has \(keys | join(", ")))"
      elif $t.id != "T\($n)" then "P8: task \($n) must have id T\($n), got \($t.id | tojson)"
      elif ($t.depends_on | type) != "array"
        or ($t.depends_on | all(.[]; type == "string" and test("^T[1-9][0-9]*$") and ((.[1:] | tonumber) < $n)) | not)
        or (($t.depends_on | unique | length) != ($t.depends_on | length)) then
        "P9: task T\($n) depends_on must list earlier task ids only, each at most once"
      elif ($t.title | nes | not) then "P10: task T\($n) needs a non-empty title"
      elif ($t.steps | strs1 | not) then "P10: task T\($n) needs at least one non-empty step"
      elif ($t.acceptance_criteria | strs1 | not) then "P10: task T\($n) needs at least one non-empty acceptance criterion"
      elif ($t.verification | type) != "array" or ($t.verification | length) < 1 then
        "P10: task T\($n) needs at least one verification entry"
      elif ($t.verification | all(.[]; type == "object" and keyset(["command", "expect"])) | not) then
        "P5: every verification entry of task T\($n) must have exactly the keys command, expect"
      elif ($t.verification | all(.[]; (.command | nes) and (.expect | nes)) | not) then
        "P10: every verification entry of task T\($n) needs a non-empty command and expect"
      elif ($t.basis | strs1 | not) then "P11: task T\($n) needs a non-empty basis"
      elif ($t.basis | all(.[]; test("^A[1-9][0-9]*$") and (. as $b | $ids | any(.[]; . == $b)))) then empty
      elif $allow_none and ($t.basis | length) == 1 and ($t.basis[0] | test("^none: \\S")) then empty
      elif $allow_none then
        "P11: task T\($n) basis must be exactly one \"none: <reason>\" entry, because the cited prior audit carries no finding ids"
      else
        "P11: task T\($n) basis must cite recorded finding ids (A1, A2, ...); \($t.basis | map(select((test("^A[1-9][0-9]*$") and (. as $b | $ids | any(.[]; . == $b))) | not)) | join(", ")) not found in the findings"
      end;
  if .v != 1 or (.v | type) != "number" then "P4: v must be the integer 1, got \(.v | tojson)"
  elif (keyset(["v", "summary", "assumptions", "out_of_scope", "tasks", "stop_conditions"]) | not) then
    "P5: the plan must have exactly the keys v, summary, assumptions, out_of_scope, tasks, stop_conditions (has \(keys | join(", ")))"
  elif (.summary | nes | not) then "P6: summary must be a non-empty string"
  elif (.assumptions | strs | not) then "P6: assumptions must be an array of non-empty strings"
  elif (.out_of_scope | strs | not) then "P6: out_of_scope must be an array of non-empty strings"
  elif (.stop_conditions | strs1 | not) then "P6: stop_conditions must be an array of at least one non-empty string"
  elif (.tasks | type) != "array" or (.tasks | length) < 1 or (.tasks | length) > 12 then
    "P7: tasks must hold 1 to 12 tasks"
  elif first_unsafe_path != null then
    "P10: every plan string must be a single line with no control characters; \(first_unsafe_path | map(tostring) | join(".")) has one"
  else
    ([.tasks | to_entries[] | .key as $i | .value | task_error($i)] | .[0])
    // (if [.. | strings | select(test("@\\[[^\\]]*\\]"))] | length > 0 then
          "P12: the plan contains a citation marker; model output is never a citation source"
        else empty end)
    // empty
  end
' "$BLOCK" 2>&1) || refuse "P3: the plan block could not be checked: $err"
[ -z "$err" ] || refuse "$err"

jq -c . "$BLOCK"
