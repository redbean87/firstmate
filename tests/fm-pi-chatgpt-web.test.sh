#!/usr/bin/env bash
# Behavior tests for the explicitly-selected ChatGPT Web Pi provider
# (bin/fm-pi-chatgpt-web-lib.sh, .pi/extensions/fm-chatgpt-web-provider.ts,
# and its bin/fm-spawn.sh + bin/fm-worker-account-lib.sh wiring).
#
# Each spawn case drives the real fm-spawn.sh through the shared fake tmux,
# which records the launch command. The fake pi answers the pinned sign-in
# check the way the real runner does for an extension-registered provider -
# `auth check` reports provider_not_found, and `--list-models` lists the
# bridge row only when the registering extension rides `-e`.
# test_real_pi_lists_the_registered_provider proves the registration against
# the real Pi; it spends no model calls.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-pi-chatgpt-web-lib.sh
. "$ROOT/bin/fm-pi-chatgpt-web-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-chatgpt-web)
unset LAVISH_AXI_HOST PI_CODING_AGENT_DIR

EXT="$ROOT/.pi/extensions/fm-chatgpt-web-provider.ts"
METADATA_EXT=$(fm_chatgpt_web_metadata_extension_path)

# make_bridge_fakes <fakebin> <case-dir>
make_bridge_fakes() {
  local fakebin=$1 dir=$2
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
root=\${PI_CODING_AGENT_DIR:-\$HOME/.pi/agent}
extargs=
preve=
for a in "\$@"; do
  if [ -n "\$preve" ]; then extargs="\${extargs:+\$extargs }\$a"; preve=; continue; fi
  if [ "\$a" = -e ]; then preve=1; fi
done
args=()
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = -e ]; then shift 2; else args+=("\$1"); shift; fi
done
set -- "\${args[@]}"
case "\${1:-}" in
  --help) printf '%s\n' 'Pi 0.86.1' 'Options: --help --tui-mode <mode>'; exit 0 ;;
  auth)
    provider=\$4
    printf '%s %s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" "\${extargs:-no-ext}" >> '$dir/pi-checks'
    if grep -qx "\$provider" "\$root/signed-in" 2>/dev/null; then
      printf '{"status":"ready","provider":"%s","authType":"oauth"}\n' "\$provider"
      exit 0
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"provider_not_found"}\n' "\$provider"
    exit 1
    ;;
  --list-models)
    provider=\${2:-}
    printf '%s %s %s\n' "\${PI_CODING_AGENT_DIR-unset}" "\$provider" "\${extargs:-no-ext}" >> '$dir/pi-checks'
    printf 'provider  model  context\n'
    if [ -n "\$extargs" ]; then printf 'chatgpt-web  gpt-5.6-luna  1.1M\n'; fi
    [ ! -f "\$root/listed" ] || cat "\$root/listed"
    exit 0
    ;;
esac
{
  printf 'EXTARGS=%s\n' "\$extargs"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/pi-worker'
SH
  chmod +x "$fakebin/pi"
}

# new_case <name>: sets CASE HOME_DIR PROJ WT FAKEBIN.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_bridge_fakes "$FAKEBIN" "$CASE"
  fm_test_spawn_home "$HOME_DIR" pi
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  : > "$CASE/launch.log"
}

# spawn_ship <id> [fm-spawn args...]
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  rm -f "$CASE/pi-checks"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    FM_CHATGPT_WEB_METADATA_EXTENSION="$METADATA_EXT" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

test_lib_maps_only_the_bridge_provider() {
  local path rc
  path=$(fm_chatgpt_web_extension_path "chatgpt-web/gpt-5.6-luna"); rc=$?
  expect_code 0 "$rc" "the full bridge selector should map to the extension"
  [ "$path" = "$EXT" ] || fail "the mapping should resolve to the tracked extension: $path"
  [ -f "$path" ] || fail "the mapped extension must exist: $path"
  path=$(fm_chatgpt_web_extension_path "chatgpt-web"); rc=$?
  expect_code 0 "$rc" "the bare provider name should map to the extension"
  [ "$path" = "$EXT" ] || fail "the bare provider should resolve to the same extension: $path"
  path=$(fm_chatgpt_web_extension_path "opencode-go/fm-fallback-chain"); rc=$?
  expect_code 1 "$rc" "another provider must not map"
  [ -z "$path" ] || fail "another provider must print no path: $path"
  path=$(fm_chatgpt_web_extension_path "default"); rc=$?
  expect_code 1 "$rc" "the default model must not map"
  path=$(fm_chatgpt_web_extension_path ""); rc=$?
  expect_code 1 "$rc" "an empty selection must not map"
  pass "the lib maps only the bridge provider to the tracked extension"
}

test_unpinned_bridge_launch_carries_the_extension() {
  local out rc id=cw-unpinned launch
  new_case unpinned
  out=$(spawn_ship "$id" --model chatgpt-web/gpt-5.6-luna); rc=$?
  expect_code 0 "$rc" "an unpinned bridge spawn should succeed: $out"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--model 'chatgpt-web/gpt-5.6-luna'" "the launch must name the bridge model"
  assert_contains "$launch" "-e '$EXT' -e '$METADATA_EXT'" "the bridge launch must carry provider and required metadata extensions"
  assert_not_contains "$launch" "--provider" "an unpinned launch must not add a provider flag"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" "the bridge launch must keep the turn-end extension"
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" \
    bash -c "$launch" || fail "the recorded bridge launch failed in the synthetic pane"
  assert_grep "$EXT" "$CASE/pi-worker" "the worker must receive the provider extension"
  assert_grep "$METADATA_EXT" "$CASE/pi-worker" "the worker must receive the required metadata extension"
  assert_grep "chatgpt-web/gpt-5.6-luna" "$CASE/pi-worker" "the worker must receive the bridge model"
  pass "an unpinned bridge-model launch carries the provider extension and keeps the turn-end guard"
}

test_other_provider_launch_carries_no_bridge_extension() {
  local out rc id=cw-other
  new_case other
  out=$(spawn_ship "$id" --model opencode-go/fm-fallback-chain); rc=$?
  expect_code 0 "$rc" "an ordinary-model spawn should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "fm-chatgpt-web-provider" \
    "an ordinary launch must not mention the bridge extension"
  assert_absent "$CASE/pi-checks" "an unpinned spawn must not run a sign-in check"
  pass "an ordinary-model launch stays byte-identical with no bridge extension"
}

test_pinned_bridge_launch_passes_the_extension_aware_check() {
  local out rc id=cw-pinned launch
  new_case pinned
  mkdir -p "$HOME_DIR/user-home/.pi/agent"
  printf 'ordinary\nchatgpt-web\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model chatgpt-web/gpt-5.6-luna); rc=$?
  expect_code 0 "$rc" "a pinned bridge spawn should succeed: $out"
  assert_contains "$out" "account_provider=chatgpt-web" "the spawn should report the bridge provider"
  launch=$(cat "$CASE/launch.log")
  assert_contains "$launch" "--provider 'chatgpt-web'" "a pinned launch must confine model lookup to the bridge"
  assert_contains "$launch" "-e '$EXT' -e '$METADATA_EXT'" "a pinned bridge launch must carry provider and required metadata extensions"
  assert_grep "chatgpt-web no-ext" "$CASE/pi-checks" "the auth check must ask about the bridge provider"
  assert_grep "chatgpt-web $EXT $METADATA_EXT" "$CASE/pi-checks" "the list-models fallback must carry provider and required metadata extensions"
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    PI_CODING_AGENT_DIR="$CASE/ambient-pi" \
    bash -c "$launch" || fail "the recorded pinned launch failed in the synthetic pane"
  assert_grep "$EXT" "$CASE/pi-worker" "the pinned worker must receive the provider extension"
  assert_grep "$METADATA_EXT" "$CASE/pi-worker" "the pinned worker must receive the required metadata extension"
  pass "a pinned bridge-model launch passes the extension-aware sign-in check and carries the extension"
}

test_pinned_bridge_launch_still_refuses_an_unlisted_provider() {
  local out rc id=cw-pinned-refuse
  new_case pinned-refuse
  mkdir -p "$HOME_DIR/user-home/.pi/agent"
  printf 'ordinary\nchatgpt-web\n' > "$HOME_DIR/config/pi-account"
  out=$(spawn_ship "$id" --model opencode-go/fm-fallback-chain); rc=$?
  expect_code 1 "$rc" "a pinned launch naming an undeclared provider must refuse"
  assert_contains "$out" "names provider 'opencode-go'" "the refusal must name the undeclared provider"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker"
  pass "the provider allowlist still refuses undeclared providers"
}

test_real_pi_lists_the_registered_provider() {
  local dir listing
  if ! command -v pi >/dev/null 2>&1; then
    echo "skip: pi not found for the provider-registration proof"
    return 0
  fi
  dir="$TMP_ROOT/real-pi-agent"
  mkdir -p "$dir"
  listing=$(PI_CODING_AGENT_DIR="$dir" pi -e "$EXT" -e "$METADATA_EXT" --list-models chatgpt-web 2>&1) || \
    fail "real pi --list-models chatgpt-web failed: $listing"
  assert_contains "$listing" "gpt-5.6-luna" "real pi must list the bridge model under the extension"
  printf '%s\n' "$listing" | awk 'NR > 1 && $1 == "chatgpt-web" && $2 == "gpt-5.6-luna" { found = 1 } END { exit !found }' || \
    fail "the listed row must pair provider chatgpt-web with the bare model id, never the doubled selector: $listing"
  assert_not_contains "$listing" "chatgpt-web/chatgpt-web" "the doubled model id must never appear"
  pass "real pi lists chatgpt-web/gpt-5.6-luna from the tracked extension with no model call"
}

test_lib_maps_only_the_bridge_provider
test_unpinned_bridge_launch_carries_the_extension
test_other_provider_launch_carries_no_bridge_extension
test_pinned_bridge_launch_passes_the_extension_aware_check
test_pinned_bridge_launch_still_refuses_an_unlisted_provider
test_real_pi_lists_the_registered_provider
