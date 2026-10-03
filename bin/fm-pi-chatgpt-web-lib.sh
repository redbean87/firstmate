#!/usr/bin/env bash
# fm-pi-chatgpt-web-lib.sh - the single owner of Firstmate's ChatGPT Web
# provider mapping for Pi workers: which model selector names the bridge,
# which tracked extension registers that provider and stamps its turns, and
# which loopback endpoint the extension talks to by default.
#
# The bridge is the already-installed codex-chatgpt-web daemon
# (~/tools/codex-chatgpt-web, loopback only); Firstmate never installs it,
# authenticates it, or touches its session state. This lib only maps the
# explicit `--model chatgpt-web/<id>` selection to the extension file below,
# which bin/fm-spawn.sh loads with an extra `-e` on Pi-family launches and
# bin/fm-worker-account-lib.sh loads for its `pi --list-models` sign-in
# fallback. Without that `-e` the provider is unknown to Pi, so ambient
# launches, existing providers, and default routing are unchanged.
#
# Selection contract: the Pi-level selector is `chatgpt-web/gpt-5.6-luna`,
# where `chatgpt-web` names the provider and `gpt-5.6-luna` is the bare model
# id. The doubled `chatgpt-web/chatgpt-web/gpt-5.6-luna` is never valid.
# A pinned home must also list `chatgpt-web` on line 2 of
# config/pi-account before it may spend this provider; docs/configuration.md
# "Worker account pin" owns that allowlist.
#
# Runtime contract (owned here, consumed by
# .pi/extensions/fm-chatgpt-web-provider.ts): the extension registers the
# provider against FM_CHATGPT_WEB_BASE_URL unless CHATGPT_WEB_BRIDGE_URL names
# another loopback URL, sends api `openai-responses`, and stamps every bridge
# turn with native Codex turn identity. Pi keeps executing all local tools;
# the bridge runs in browser-only mode, so the web model answers from its own
# context and never drives MCP or full-harness local execution.

FM_CHATGPT_WEB_PROVIDER="chatgpt-web"
FM_CHATGPT_WEB_MODEL_ID="gpt-5.6-luna"
FM_CHATGPT_WEB_MODEL="chatgpt-web/gpt-5.6-luna"
FM_CHATGPT_WEB_BASE_URL="http://127.0.0.1:17841/v1"

# fm_chatgpt_web_extension_path [model-or-provider]
# Prints the absolute path of the tracked provider extension when the argument
# selects the chatgpt-web provider (a full `chatgpt-web/<id>` selector or the
# bare provider name). Prints nothing and returns 1 otherwise, so callers add
# no flag for any other provider. The path resolves against this lib's own
# location, never FM_ROOT, so fm-spawn, fm-control, and tests agree.
fm_chatgpt_web_extension_path() {
  local selection=${1:-} provider
  case "$selection" in
  */*) provider=${selection%%/*} ;;
  *) provider=$selection ;;
  esac
  [ -n "$provider" ] && [ "$provider" = "$FM_CHATGPT_WEB_PROVIDER" ] || return 1
  local libdir
  libdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  printf '%s\n' "$(dirname "$libdir")/.pi/extensions/fm-chatgpt-web-provider.ts"
}
