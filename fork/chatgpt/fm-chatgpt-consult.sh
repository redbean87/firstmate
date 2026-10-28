#!/usr/bin/env bash
# fm-chatgpt-consult.sh - Firstmate-owned ChatGPT consultation client.
# Usage: fm-chatgpt-consult.sh --prompt-file FILE --mode audit|plan
#          --thread THREAD-ID [--project NAME]
#
# Builds one openai-responses request from the prompt file, stamps it with the
# Codex turn identity the local bridge requires (fork/chatgpt/fm-chatgpt-bridge-lib.sh
# owns that contract), POSTs it to the already-running loopback bridge, and
# prints ChatGPT's response text to stdout and nothing else.
#
# --project NAME is optional and names the repository this consultation is
# about. When present (validated like the bridge's header contract:
# ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$, owned by the lib's
# fm_chatgpt_project_name_valid)
# the request additionally carries the header x-fm-chatgpt-project: NAME, so
# the codex-chatgpt-web fork opens its ChatGPT chat inside that repository's
# ChatGPT project. When absent, no project header is sent and the request is
# byte-for-byte the upstream shape. Routing is advisory, never a gate: after a
# successful turn whose routing outcome the bridge recorded as a fallback,
# exactly one stderr notice (fm-chatgpt: project routing: fallback (<reason>))
# is printed and the exit status stays 0 with stdout unchanged. The health
# probe in the lib sends no project header.
#
# The --mode audit instructions inject fork/chatgpt/audit-brief-template
# verbatim, so the generated audit prompt's shape
# (exact initial scope, expansion clause, reading budgets, carry-forward
# discipline, stop rules, finding ids) has one owner and this script holds no
# second copy; a missing template refuses on stderr before any bridge contact.
# The --mode plan instructions inject fork/chatgpt/plan-contract.template the
# same way and refuse the same way without it. This script returns the plan
# reply as text; fork/chatgpt/fm-chatgpt-loop.sh validates it.
#
# --thread is required and names the Firstmate-owned turn-identity id stamped
# into every request. It does not carry conversation continuity by itself:
# the bridge replays prior turns only via previous_response_id chaining or
# history inside the request, and this client sends neither (the lib owns the
# verified details). Each call is one self-contained turn, so Firstmate
# includes any prior context it needs considered in the prompt file.
#
# This is a consultation channel, not a Pi provider: no harness, no model
# registry, no account pin, no local-tool execution. The bridge lifecycle
# stays external - this script never installs, authenticates, or repairs the
# bridge. An unreachable or failing bridge is a reported prerequisite
# (nonzero exit, diagnostic on stderr, no response on stdout), never a setup
# step. A rejection the bridge reports as a structured .error payload is a
# genuine consult failure too: the bridge's own diagnostic - message and
# code verbatim, including any token count it reports - goes to the caller
# on stderr, stdout stays empty, and the bridge stays the sole authority on
# why a turn failed; this script never estimates request size itself.
# fork/chatgpt/README owns the operator contract.
set -u

LIBDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fork/chatgpt/fm-chatgpt-bridge-lib.sh
. "$LIBDIR/fm-chatgpt-bridge-lib.sh"

usage() {
  printf 'usage: %s --prompt-file FILE --mode audit|plan --thread ID [--project NAME]\n' "$(basename "$0")" >&2
}

PROMPT_FILE="" MODE="" THREAD="" PROJECT="" MODEL="$FM_CHATGPT_WEB_MODEL"
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-file) [ $# -ge 2 ] || { printf 'fm-chatgpt: %s needs a value\n' "$1" >&2; usage; exit 2; }; PROMPT_FILE=$2; shift 2 ;;
    --mode) [ $# -ge 2 ] || { printf 'fm-chatgpt: %s needs a value\n' "$1" >&2; usage; exit 2; }; MODE=$2; shift 2 ;;
    --thread) [ $# -ge 2 ] || { printf 'fm-chatgpt: %s needs a value\n' "$1" >&2; usage; exit 2; }; THREAD=$2; shift 2 ;;
    --project) [ $# -ge 2 ] || { printf 'fm-chatgpt: %s needs a value\n' "$1" >&2; usage; exit 2; }; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fm-chatgpt: unknown argument %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PROMPT_FILE" ] || { printf 'fm-chatgpt: --prompt-file is required\n' >&2; usage; exit 2; }
[ -f "$PROMPT_FILE" ] || { printf 'fm-chatgpt: prompt file not found: %s\n' "$PROMPT_FILE" >&2; exit 2; }
case "$MODE" in
  audit|plan) ;;
  *) printf 'fm-chatgpt: --mode must be audit or plan\n' >&2; usage; exit 2 ;;
esac
[ -n "$THREAD" ] || { printf 'fm-chatgpt: --thread is required (Firstmate owns the turn-identity id)\n' >&2; usage; exit 2; }
# An empty --project is absent by contract (no header); a non-empty one must
# be a name the bridge's routing accepts, refused here before any bridge
# contact rather than silently dropped by the bridge's HK1 validation.
if [ -n "$PROJECT" ] && ! fm_chatgpt_project_name_valid "$PROJECT"; then
  printf 'fm-chatgpt: refusing invalid --project name %s (need ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$)\n' "$PROJECT" >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || { printf 'fm-chatgpt: consultation needs curl\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'fm-chatgpt: consultation needs jq\n' >&2; exit 1; }

BRIDGE_URL=$(fm_chatgpt_bridge_url) || exit 1
fm_chatgpt_record_channel_use

case "$MODE" in
  audit)
    # The audit-brief template is the single owner of the generated prompt's
    # shape (exact initial scope, expansion clause, reading budgets, carry-
    # forward discipline, stop rules); it is injected verbatim so this script
    # never holds a second copy of that contract. A missing template refuses
    # before any bridge contact rather than generating prompts without it.
    AUDIT_TEMPLATE_FILE="$LIBDIR/audit-brief-template"
    [ -f "$AUDIT_TEMPLATE_FILE" ] || {
      printf 'fm-chatgpt: audit-brief template missing: %s\n' "$AUDIT_TEMPLATE_FILE" >&2
      printf 'fm-chatgpt: the audit stage needs fork/chatgpt/audit-brief-template so every generated audit prompt carries the shared scope, expansion, and carry-forward contract\n' >&2
      exit 1
    }
    AUDIT_TEMPLATE=$(cat "$AUDIT_TEMPLATE_FILE") || {
      printf 'fm-chatgpt: audit-brief template could not be read: %s\n' "$AUDIT_TEMPLATE_FILE" >&2
      exit 1
    }
    INSTRUCTIONS="You are a senior engineer writing audit instructions for a worker. Read the objective and context below and return only a self-contained audit prompt that the worker will follow; this is prompt generation, not the audit itself. The prompt must state the specific questions the worker must answer, the evidence and scope to inspect, the required report shape including the template's stable finding ids, and explicit stop rules, and it must carry the objective's essential details so it stands alone. Structure the returned prompt on the audit-brief template below, filling every field the objective and context support; where they supply no files, symbols, or line ranges, the prompt opens with the template's bounded reconnaissance phase to establish exact initial scope before deep inspection. This turn has no local tools and does not need any local tools: do not attempt tool use and never emit or discuss a tool-availability notice or banner. Return only the audit prompt.

Audit-brief template the returned prompt must follow:
$AUDIT_TEMPLATE"
    ;;
  plan)
    # The plan contract is the single owner of the plan's shape and rules, and
    # the same file fork/chatgpt/fm-chatgpt-plan-validate.sh enforces; it is
    # injected verbatim, and a missing contract refuses before bridge contact.
    PLAN_CONTRACT_FILE="$LIBDIR/plan-contract.template"
    [ -f "$PLAN_CONTRACT_FILE" ] || {
      printf 'fm-chatgpt: plan contract missing: %s\n' "$PLAN_CONTRACT_FILE" >&2
      printf 'fm-chatgpt: the plan stage needs fork/chatgpt/plan-contract.template so every generated plan follows the validated version-1 contract\n' >&2
      exit 1
    }
    PLAN_CONTRACT=$(cat "$PLAN_CONTRACT_FILE") || {
      printf 'fm-chatgpt: plan contract could not be read: %s\n' "$PLAN_CONTRACT_FILE" >&2
      exit 1
    }
    # The reply format is restated here, at the point a live reply went
    # wrong (an unlabelled fence after a banner); P1 in the contract stays
    # the rule's owner, and an unlabelled fence is still refused.
    PLAN_FORMAT=$(cat <<'EOF'
Reply format, required: your entire reply is exactly one fenced code block and nothing else - no preamble, no banner, no notice, and no text after it. The opening fence is a line of exactly ```json and the closing fence is a line of exactly ```. A reply shaped like this passes; an opening fence of ``` with no json label is refused:

```json
{"v": 1, "summary": "...", "assumptions": [], "out_of_scope": [], "tasks": [{"id": "T1", "title": "...", "basis": ["A1"], "depends_on": [], "steps": ["..."], "acceptance_criteria": ["..."], "verification": [{"command": "...", "expect": "..."}]}], "stop_conditions": ["..."]}
```
EOF
)
    INSTRUCTIONS="You are a senior implementation planner. Read the objective, context, and audit findings below and return a concrete execution plan a worker can follow without further design decisions, as exactly the JSON plan the contract below specifies. Every task cites the finding ids it acts on. This turn has no local tools and does not need any local tools: do not attempt tool use and never emit or discuss a tool-availability notice or banner.

$PLAN_FORMAT

Implementation plan contract the returned plan must follow:
$PLAN_CONTRACT"
    ;;
esac

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
REQUEST="$WORK/request.json"
RESPONSE="$WORK/response.json"

jq -n --arg m "$MODEL" --arg n "$INSTRUCTIONS" --rawfile p "$PROMPT_FILE" \
  '{model: $m, instructions: $n, input: [{role: "user", content: $p}]}' > "$REQUEST" || exit 1
fm_chatgpt_stamp_turn "$THREAD" "$REQUEST" >/dev/null || exit 1

# The consult's start instant bounds which routing outcome is this turn's:
# the bridge records fork-routes/<trace>.outcome.json during the turn, so an
# outcome older than this consult can never be mistaken for its fallback.
CONSULT_STARTED_AT_MS=$(($(date +%s) * 1000))
HTTP=$(curl -s -o "$RESPONSE" -w '%{http_code}' -m 120 \
  -X POST "$BRIDGE_URL/responses" \
  -H 'content-type: application/json' \
  ${PROJECT:+-H "x-fm-chatgpt-project: $PROJECT"} \
  --data-binary "@$REQUEST") || {
  printf 'fm-chatgpt: bridge unreachable at %s; start the codex-chatgpt-web bridge before consulting\n' "$BRIDGE_URL" >&2
  exit 1
}
case "$HTTP" in
  2*) ;;
  *)
    printf 'fm-chatgpt: bridge request failed with HTTP %s: %s\n' "$HTTP" "$(head -c 500 "$RESPONSE")" >&2
    exit 1
    ;;
esac

# Structured rejection first: an .error.message means the bridge refused
# the turn (e.g. a transport-budget rejection at HTTP 200), so the bridge's
# own code and message are the diagnostic - relayed verbatim, never parsed
# or reconstructed, and never followed by a synthesized size.
ERR=$(jq -r '.error.message // empty' "$RESPONSE" 2>/dev/null) || ERR=""
if [ -n "$ERR" ]; then
  ERR_CODE=$(jq -r '.error.code // empty' "$RESPONSE" 2>/dev/null) || ERR_CODE=""
  if [ -n "$ERR_CODE" ]; then
    printf 'fm-chatgpt: bridge rejected the request (%s): %s\n' "$ERR_CODE" "$ERR" >&2
  else
    printf 'fm-chatgpt: bridge rejected the request: %s\n' "$ERR" >&2
  fi
  exit 1
fi

TEXT=$(fm_chatgpt_response_text "$RESPONSE")
[ -n "$TEXT" ] || {
  printf 'fm-chatgpt: bridge returned no response text (HTTP %s)\n' "$HTTP" >&2
  exit 1
}
# Project routing is advisory: when a project was requested and the bridge
# recorded this turn's routing as a fallback, say so once on stderr and keep
# the answer on stdout with exit 0. An unreadable or absent outcome is silence.
if [ -n "$PROJECT" ]; then
  FALLBACK_REASON=$(fm_chatgpt_project_fallback_reason "$PROJECT" "$CONSULT_STARTED_AT_MS" 2>/dev/null) || FALLBACK_REASON=""
  if [ -n "$FALLBACK_REASON" ]; then
    printf 'fm-chatgpt: project routing: fallback (%s)\n' "$FALLBACK_REASON" >&2
  fi
fi
printf '%s\n' "$TEXT"
