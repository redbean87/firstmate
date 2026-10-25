#!/usr/bin/env bash
# claude-subscription launch policy: a Claude launch needs upstream's Claude
# account pin and a claude.ai login, asked of the claude that both the launching
# process and the worker's login shell resolve. Unit cases call the policy with
# the hook contract directly (relaunch-preflight is HK2's phase); the HK1 cases
# drive the REAL upstream bin/fm-spawn.sh. A fake claude reports signed out when
# USER or LOGNAME is missing, as the macOS keychain login does.
set -u
# shellcheck source=fork/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-claude-subscription)
mkdir -p "$TMP_ROOT"

# new_case <name>: sets CASE HOME_DIR FAKEBIN FAKE_SHELL FAKE_DIR, a pinned
# home (config/claude-account = ordinary, claude-subscription enabled), a fake
# claude signed in with claude.ai, and a login shell resolving that claude.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  FAKEBIN="$CASE/bin"
  FAKE_DIR="$CASE/fake"
  FAKE_SHELL="$CASE/shell/zsh"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN" "$FAKE_DIR" "$CASE/shell" "$CASE/project"
  fork_policies "$HOME_DIR" claude-subscription
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
FAKE='$FAKE_DIR'
SH
  cat >> "$FAKEBIN/claude" <<'SH'
[ "${1:-} ${2:-}" = "auth status" ] || exit 0
env | sort > "$FAKE/auth-env"
if [ -z "${USER:-}" ] || [ -z "${LOGNAME:-}" ]; then
  printf '{"loggedIn":false,"authMethod":"none"}\n'; exit 1
fi
cat "$FAKE/auth.json"
jq -e '.loggedIn == true' "$FAKE/auth.json" >/dev/null 2>&1
SH
  chmod +x "$FAKEBIN/claude"
  printf '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}\n' > "$FAKE_DIR/auth.json"
  cat > "$FAKE_SHELL" <<SH
#!/usr/bin/env bash
FAKE='$FAKE_DIR'
SH
  cat >> "$FAKE_SHELL" <<'SH'
printf '%s\n' "$*" > "$FAKE/shell-args"
pwd > "$FAKE/shell-cwd"
echo "login banner noise"
[ ! -f "$FAKE/shell-resolves" ] || cat "$FAKE/shell-resolves"
SH
  chmod +x "$FAKE_SHELL"
  printf '%s\n' "$FAKEBIN/claude" > "$FAKE_DIR/shell-resolves"
}

auth_as() { printf '%s\n' "$1" > "$FAKE_DIR/auth.json"; }

# run_policy <phase> <kind> <task> <harness> [raw-launch]: prints output, returns rc.
run_policy() {
  FM_LP_PHASE=$1 FM_LP_KIND=$2 FM_LP_TASK=$3 FM_LP_HARNESS=$4 FM_LP_RAW_LAUNCH=${5:-} \
    FM_LP_PROJECT="$CASE/project" FM_LP_MODEL='' FM_LP_EFFORT='' FM_LP_HOME="$HOME_DIR" \
    FM_LP_STATE="$HOME_DIR/state" FM_LP_DATA="$HOME_DIR/data" FM_LP_CONFIG="$HOME_DIR/config" \
    SHELL="$FAKE_SHELL" PATH="$FAKEBIN:$PATH" ANTHROPIC_API_KEY=ambient-key-must-not-reach-the-check \
    "$POLICY" 2>&1
}

test_subscription_login_allows_spawn_and_relaunch() {
  local out rc
  new_case allow
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 0 ] || fail "a claude.ai login must allow the spawn: $out"
  out=$(run_policy relaunch-preflight ship t1 claude); rc=$?
  [ "$rc" -eq 0 ] || fail "a claude.ai login must allow the relaunch preflight (HK2): $out"
  assert_grep 'USER=' "$FAKE_DIR/auth-env" "the check passes USER"
  assert_grep 'LOGNAME=' "$FAKE_DIR/auth-env" "the check passes LOGNAME"
  assert_no_grep 'ANTHROPIC_API_KEY' "$FAKE_DIR/auth-env" "an ambient API key never reaches the check"
  assert_no_grep 'CLAUDE_CONFIG_DIR' "$FAKE_DIR/auth-env" "an ordinary pin leaves CLAUDE_CONFIG_DIR unset"
  assert_grep '-lic command -v claude' "$FAKE_DIR/shell-args" "the login shell is asked which claude it runs"
  assert_grep "$CASE/project" "$FAKE_DIR/shell-cwd" "the login shell is asked from the project directory"
  pass "claude-subscription: a claude.ai login allows spawn and relaunch preflight, with USER and LOGNAME and no ambient API key"
}

test_missing_user_and_logname_are_supplied() {
  local out rc
  new_case nouser
  out=$(env -u USER -u LOGNAME bash -c "$(declare -f run_policy); POLICY='$POLICY' CASE='$CASE' HOME_DIR='$HOME_DIR' FAKE_SHELL='$FAKE_SHELL' FAKEBIN='$FAKEBIN' run_policy spawn ship t1 claude"); rc=$?
  [ "$rc" -eq 0 ] || fail "USER and LOGNAME must be supplied when the caller lacks them: $out"
  assert_grep "USER=$(id -un)" "$FAKE_DIR/auth-env" "USER falls back to the account name"
  assert_grep "LOGNAME=$(id -un)" "$FAKE_DIR/auth-env" "LOGNAME falls back to the account name"
  pass "claude-subscription: USER and LOGNAME are derived when the launching environment lacks them"
}

test_non_subscription_logins_refuse() {
  local out rc method
  for method in console apiKey; do
    new_case "refuse-$method"
    auth_as '{"loggedIn":true,"authMethod":"'"$method"'"}'
    out=$(run_policy spawn ship t1 claude); rc=$?
    [ "$rc" -eq 1 ] || fail "a $method login must refuse (rc 1), got $rc: $out"
    assert_contains "$out" "signed in with $method" "the refusal names the $method login"
  done
  new_case refuse-preflight
  auth_as '{"loggedIn":true,"authMethod":"console"}'
  out=$(run_policy relaunch-preflight ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "a console login must refuse the relaunch preflight before the agent is stopped: $out"
  pass "claude-subscription: Console and API-key logins refuse at spawn and at the relaunch preflight"
}

test_signed_out_and_unreadable_refuse() {
  local out rc
  new_case signed-out
  auth_as '{"loggedIn":false,"authMethod":"none"}'
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "a signed-out root must refuse: $out"
  assert_contains "$out" "signed out" "the refusal says signed out"
  new_case unreadable
  auth_as 'not json'
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "an unreadable answer must refuse: $out"
  assert_contains "$out" "could not read the account type" "the refusal says the answer was unreadable"
  pass "claude-subscription: signed-out and unreadable answers refuse rather than risk API billing"
}

test_pin_is_required_and_old_format_is_unusable() {
  local out rc
  new_case nopin
  rm "$HOME_DIR/config/claude-account"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "a home without config/claude-account must refuse: $out"
  assert_contains "$out" "needs a Claude account pin" "the refusal names the missing pin"
  new_case oldformat
  printf 'ordinary\nsubscription\n' > "$HOME_DIR/config/claude-account"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 2 ] || fail "the retired two-line pin must be unusable (rc 2), as upstream's parser refuses it: $out"
  pass "claude-subscription: the upstream pin is required, and the retired two-line pin format refuses"
}

test_config_root_reaches_the_check() {
  local out rc
  new_case root
  mkdir -p "$CASE/claude-root"
  printf '%s\n' "$CASE/claude-root" > "$HOME_DIR/config/claude-account"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 0 ] || fail "a pinned config root signed in with claude.ai must allow: $out"
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/claude-root" "$FAKE_DIR/auth-env" "the pinned root is the one checked"
  pass "claude-subscription: a pinned config root is the root the check asks about"
}

test_secondmate_uses_its_own_pin() {
  local out rc
  new_case mate
  mkdir -p "$CASE/mate-root" "$HOME_DIR/config/secondmate-accounts/mate1"
  printf '%s\n' "$CASE/mate-root" > "$HOME_DIR/config/secondmate-accounts/mate1/claude-account"
  out=$(run_policy spawn secondmate mate1 claude); rc=$?
  [ "$rc" -eq 0 ] || fail "a secondmate with its own claude.ai pin must allow: $out"
  assert_grep "CLAUDE_CONFIG_DIR=$CASE/mate-root" "$FAKE_DIR/auth-env" "the secondmate's own pin is the one checked"
  pass "claude-subscription: a secondmate is checked against its own per-mate pin"
}

test_worker_shell_must_resolve_the_same_claude() {
  local out rc
  new_case othershell
  mkdir -p "$CASE/elsewhere"
  printf '#!/bin/sh\nexit 0\n' > "$CASE/elsewhere/claude"
  chmod +x "$CASE/elsewhere/claude"
  printf '%s\n' "$CASE/elsewhere/claude" > "$FAKE_DIR/shell-resolves"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "a login shell resolving a different claude must refuse: $out"
  assert_contains "$out" "$CASE/elsewhere/claude" "the refusal names the shell's claude"
  assert_absent "$FAKE_DIR/auth-env" "no sign-in check runs against an unconfirmed executable"
  new_case symlinked
  ln -s "$FAKEBIN/claude" "$CASE/shell/claude-link"
  printf '%s\n' "$CASE/shell/claude-link" > "$FAKE_DIR/shell-resolves"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 0 ] || fail "a symlink to the same claude must allow: $out"
  new_case noshell
  rm "$FAKE_DIR/shell-resolves"
  out=$(run_policy spawn ship t1 claude); rc=$?
  [ "$rc" -eq 1 ] || fail "a login shell that resolves no claude must refuse: $out"
  assert_contains "$out" "did not resolve a claude executable" "the refusal says the shell found none"
  pass "claude-subscription: the worker's login shell must resolve the same claude file the check runs"
}

test_other_harnesses_are_untouched_and_raw_claude_is_checked() {
  local out rc
  new_case pi
  auth_as '{"loggedIn":true,"authMethod":"console"}'
  out=$(run_policy spawn ship t1 pi); rc=$?
  [ "$rc" -eq 0 ] || fail "a non-Claude launch must not be judged by this policy: $out"
  assert_absent "$FAKE_DIR/auth-env" "a non-Claude launch runs no Claude check"
  out=$(run_policy spawn ship t1 claude "claude --model opus"); rc=$?
  [ "$rc" -eq 1 ] || fail "a raw claude launch must be checked too: $out"
  pass "claude-subscription: other harnesses are untouched and a raw claude launch is checked"
}

# HK1 through the REAL upstream fm-spawn.
new_spawn_case() {  # <name> <id>
  new_case "$1"
  PROJ="$CASE/repo"
  WT="$CASE/wt"
  LAUNCH_LOG="$CASE/launch.log"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_test_spawn_brief "$HOME_DIR" "$2"
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE" gh gh-axi no-mistakes)
  mv "$CASE/bin/claude" "$FAKEBIN/claude"
  printf '%s\n' "$FAKEBIN/claude" > "$FAKE_DIR/shell-resolves"
  : > "$LAUNCH_LOG"
}

spawn_claude() {  # <id>
  SHELL="$FAKE_SHELL" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" \
    "$1" "$PROJ" --mode no-mistakes --yolo off --harness claude
}

test_hk1_spawn_allows_subscription_and_refuses_console() {
  local out rc
  new_spawn_case hk1-allow t-allow
  out=$(spawn_claude t-allow); rc=$?
  [ "$rc" -eq 0 ] || fail "HK1: a claude.ai login must launch: $out"
  [ -f "$HOME_DIR/state/t-allow.meta" ] || fail "HK1: an allowed launch writes its task record: $out"
  [ -s "$LAUNCH_LOG" ] || fail "HK1: an allowed launch reaches the endpoint: $out"
  new_spawn_case hk1-refuse t-refuse
  auth_as '{"loggedIn":true,"authMethod":"console"}'
  out=$(spawn_claude t-refuse); rc=$?
  [ "$rc" -ne 0 ] || fail "HK1: a Console login must refuse the spawn: $out"
  assert_contains "$out" "signed in with console" "HK1: the refusal names the Console login"
  assert_absent "$HOME_DIR/state/t-refuse.meta" "HK1: a refused launch writes no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "HK1: a refused launch sends nothing to the endpoint"
  pass "HK1: the real fm-spawn launches a claude.ai-pinned Claude worker and refuses a Console one before any record"
}

fork_run_tests
