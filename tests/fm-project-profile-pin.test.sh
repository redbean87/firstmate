#!/usr/bin/env bash
# Behavior tests for the deterministic project-to-worker-profile binding.
#
# The binding lives in config/crew-dispatch.json as an exact-match projects
# map plus projectDefault (docs/configuration.md "Crew dispatch profiles",
# bin/fm-project-profile-lib.sh), and is enforced structurally at initial
# spawn (bin/fm-spawn.sh) and at relaunch (bin/fm-control.sh): a contradicting
# harness or model is refused, never substituted, and a raw launch command
# never satisfies a pin. There is no per-task override.
#
# Spawn cases drive fm-spawn through meta writing and launch construction with
# a fake tmux pane and a real isolated git worktree, following
# tests/fm-spawn-dispatch-profile.test.sh. Relaunch cases drive fm-control
# against a stubbed session provider, following tests/fm-control.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-project-profile-lib.sh
. "$ROOT/bin/fm-project-profile-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-profile-pin)

PIN_OPENCODE_MODEL="opencode-go/muse-spark-1.3-contributor"
PIN_QWEN_MODEL="qwen-local/qwen3.8-27b-unsloth-ud-iq3xxs"

write_pin_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<JSON
{
  "rules": [],
  "projects": {
    "expo-bowling-journal": { "harness": "pi", "model": "$PIN_QWEN_MODEL" }
  },
  "projectDefault": { "harness": "opencode", "model": "$PIN_OPENCODE_MODEL" }
}
JSON
}

make_pin_pi_probe() {  # <fakebin> <tool>
  cat > "$1/$2" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$1/$2"
}

make_pin_fakebin() {  # <dir> -> fakebin with pi probes
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$1")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_pin_pi_probe "$fakebin" pi
  make_pin_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_pin_case() {  # <name> <project-name> <id>... -> case|home|proj|wt|fakebin|launchlog
  local name=$1 project=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/$project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_pin_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home"
  write_pin_config "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_pin_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_pin_spawn() {  # <home> <wt> <fakebin> <launchlog> [args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_pin_ship() {
  run_pin_spawn "$@" --mode no-mistakes --yolo off
}

test_project_profile_mapping_is_exact_match() {
  local cfg pin
  cfg="$TMP_ROOT/mapping-config"
  mkdir -p "$cfg"
  cat > "$cfg/crew-dispatch.json" <<JSON
{
  "rules": [],
  "projects": {
    "expo-bowling-journal": { "harness": "pi", "model": "$PIN_QWEN_MODEL" }
  },
  "projectDefault": { "harness": "opencode", "model": "$PIN_OPENCODE_MODEL" }
}
JSON
  pin=$(fm_project_profile_for "expo-bowling-journal" "$cfg")
  assert_equals "pi	$PIN_QWEN_MODEL	" "$pin" "bowling must pin to Pi with the local Qwen model"
  pin=$(fm_project_profile_for "swing-trader" "$cfg")
  assert_equals "opencode	$PIN_OPENCODE_MODEL	" "$pin" "any other project must pin to OpenCode with the configured model"
  pin=$(fm_project_profile_for "Expo-Bowling-Journal" "$cfg")
  assert_equals "opencode	$PIN_OPENCODE_MODEL	" "$pin" "the mapping must be exact-match, not case-insensitive"
  pin=$(fm_project_profile_for "expo-bowling-journal " "$cfg")
  assert_equals "opencode	$PIN_OPENCODE_MODEL	" "$pin" "the mapping must be exact-match, not trimmed or fuzzy"
  printf '%s' '{malformed' > "$cfg/crew-dispatch.json"
  fm_project_profile_for "swing-trader" "$cfg" 2>/dev/null \
    && fail "a malformed deterministic mapping must refuse, not fall back"
  [ "$?" -eq 2 ] || fail "a malformed deterministic mapping must exit 2"
  pass "the project-to-profile mapping pins bowling to Pi/Qwen and every other project to OpenCode, exact-match only"
}

test_correct_spawn_succeeds_on_the_pinned_profile() {
  local rec id out status
  id=pp-correct-ship-z1
  rec=$(make_pin_case pin-correct swing-trader "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness opencode --model "$PIN_OPENCODE_MODEL")
  status=$?
  expect_code 0 "$status" "a normal project spawn on the pinned OpenCode profile should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=opencode" "spawn did not report the pinned harness"
  assert_grep "model=$PIN_OPENCODE_MODEL" "$HOME_DIR/state/$id.meta" "meta did not record the pinned model"

  id=pp-correct-bowling-z2
  rec=$(make_pin_case pin-correct-bowling expo-bowling-journal "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model "$PIN_QWEN_MODEL")
  status=$?
  expect_code 0 "$status" "a bowling spawn on the pinned Pi/Qwen profile should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=pi" "bowling spawn did not report pi"
  pass "a correct spawn succeeds on the pinned profile for normal and bowling projects"
}

test_wrong_harness_for_a_pinned_project_is_refused_at_spawn() {
  local rec id out status
  id=pp-wrong-harness-z3
  rec=$(make_pin_case pin-wrong-harness swing-trader "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model "$PIN_QWEN_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a normal project spawn on Pi should be refused"$'\n'"$out"
  assert_contains "$out" "pinned to --harness opencode" "the refusal did not name the pinned profile"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must send no launch"
  pass "a wrong harness for a pinned project is refused at spawn with no substitution"
}

test_relaunch_naming_the_wrong_harness_is_refused_before_stop() {
  local dir home out rc
  dir="$TMP_ROOT/pin-relaunch-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  home="$dir/home"
  fm_test_spawn_home "$home"
  write_pin_config "$home"
  proj="$dir/swing-trader"
  wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "wt-pin-relaunch"
  mkdir -p "$home/data/t1"
  printf '# brief for t1\n' > "$home/data/t1/brief.md"
  {
    echo "window=fmses:fm-t1"
    echo "endpoint_task_id=t1"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=opencode"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=$PIN_OPENCODE_MODEL"
    echo "effort=default"
  } > "$home/state/t1.meta"
  fb="$dir/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then printf '%s\n' "$payload" >> "$D/literal"; else printf '%s\n' "$payload" >> "$D/keys"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf 'opencode\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'box\n'; exit 0 ;;
  list-windows) if [ -f "$D/windows" ]; then cat "$D/windows"; fi; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'opencode' > "$dir/fake/command"
  printf 'fm-t1' > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  out=$(env PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" t1 relaunch --harness pi --model "$PIN_QWEN_MODEL" --note "try the other worker" 2>&1)
  rc=$?
  expect_code 1 "$rc" "a relaunch onto the wrong harness should be refused"$'\n'"$out"
  assert_contains "$out" "pinned to --harness opencode" "the relaunch refusal did not name the pinned profile"
  [ ! -s "$dir/fake/keys" ] || fail "a refused relaunch must send no control key before stopping the agent: $(cat "$dir/fake/keys")"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must type no exit command: $(cat "$dir/fake/literal")"
  assert_grep "harness=opencode" "$home/state/t1.meta" "a refused relaunch must leave the durable record untouched"
  pass "a relaunch naming the wrong harness is refused before the running agent stops"
}

test_raw_launch_command_cannot_bypass_the_project_profile() {
  local rec id out status
  id=pp-raw-bypass-z5
  rec=$(make_pin_case pin-raw-bypass swing-trader "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "custom-agent --flag" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a raw launch command should not satisfy a pinned project"$'\n'"$out"
  assert_contains "$out" "a raw launch command cannot satisfy that pin" "the refusal did not close the raw-launch escape hatch"
  assert_absent "$HOME_DIR/state/$id.meta" "a raw-bypass refusal must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a raw-bypass refusal must send no launch"
  pass "a raw launch command cannot bypass the project profile"
}

test_bowling_specifically_cannot_move_to_opencode() {
  local rec id out status
  id=pp-bowling-opencode-z6
  rec=$(make_pin_case pin-bowling-opencode expo-bowling-journal "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness opencode --model "$PIN_OPENCODE_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "bowling on OpenCode should be refused"$'\n'"$out"
  assert_contains "$out" "pinned to --harness pi" "the bowling refusal did not name the Pi pin"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused bowling move must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused bowling move must send no launch"
  pass "bowling specifically cannot be moved to OpenCode"
}

test_normal_project_specifically_cannot_move_to_pi() {
  local rec id out status
  id=pp-normal-pi-z7
  rec=$(make_pin_case pin-normal-pi swing-trader "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness pi --model "$PIN_QWEN_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a normal project on Pi should be refused"$'\n'"$out"
  assert_contains "$out" "pinned to --harness opencode" "the normal-project refusal did not name the OpenCode pin"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused normal-project move must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused normal-project move must send no launch"
  pass "a normal project specifically cannot be moved to Pi"
}

test_no_fallback_to_firstmate_on_worker_startup_or_dependency_failure() {
  local rec id out status base_sans_pi
  id=pp-no-fallback-backend-z8a
  rec=$(make_pin_case pin-no-fallback-backend swing-trader "$id")
  read_pin_record "$rec"
  out=$(run_pin_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness opencode --model "$PIN_OPENCODE_MODEL" --backend bogus-backend-xyz 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown backend should refuse, not fall back"$'\n'"$out"
  assert_absent "$HOME_DIR/state/$id.meta" "a backend refusal must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a backend refusal must send no launch"

  id=pp-no-fallback-missing-tool-z8b
  rec=$(make_pin_case pin-no-fallback-missing-tool expo-bowling-journal "$id")
  read_pin_record "$rec"
  rm -f "$FAKEBIN_DIR/pi" "$FAKEBIN_DIR/pi-signed"
  base_sans_pi=$(fm_test_base_path_sans "$PATH" pi pi-signed)
  out=$(env PATH="$FAKEBIN_DIR:$base_sans_pi" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" GROK_HOME="$HOME_DIR/grok-home" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness pi --model "$PIN_QWEN_MODEL" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing worker executable should refuse, not fall back"$'\n'"$out"
  assert_contains "$out" "not found on PATH" "the refusal did not name the missing dependency"
  assert_absent "$HOME_DIR/state/$id.meta" "a dependency refusal must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a dependency refusal must send no launch"
  pass "no fallback to firstmate or self-execution on worker startup or dependency failure"
}

test_typed_classifier_receives_only_intent_and_spec_sections() {
  local tdir body rc out
  tdir="$TMP_ROOT/pin-classifier-$RANDOM"
  mkdir -p "$tdir/config" "$tdir/log" "$tdir/fakebin"
  cat > "$tdir/brief.md" <<'MD'
# Task

## Captain's intent
Fix the pager off-by-one for the test project.

## Firstmate spec
Keep the change small and covered by a test.

## Setup
SECRET-SETUP-TEXT the classifier must never see.

# Rules
SECRET-RULES-TEXT the classifier must never see.

# Definition of done
SECRET-DOD-TEXT the classifier must never see.
MD
  cat > "$tdir/config/crew-dispatch.json" <<'JSON'
{
  "rules": [{ "when": "Pager work.", "use": { "harness": "claude", "model": "sonnet" } }],
  "default": { "harness": "claude", "model": "sonnet" }
}
JSON
  cat > "$tdir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "${FAKE_CURL_LOG:?}/body"
cat /dev/fd/3 > "${FAKE_CURL_LOG:?}/header" 2>/dev/null || true
exit 7
SH
  chmod +x "$tdir/fakebin/curl"
  out=$(PATH="$tdir/fakebin:$PATH" FM_HOME="$tdir" TYPESAFE_API_KEY="test-key-classifier" \
    FAKE_CURL_LOG="$tdir/log" "$ROOT/bin/fm-dispatch-resolve.sh" "$tdir/brief.md" --project pager 2>&1)
  rc=$?
  expect_code 0 "$rc" "a curl failure is a structured error outcome, not a usage error"$'\n'"$out"
  assert_contains "$out" "status: error" "the failed request should surface as an error outcome"
  body=$(cat "$tdir/log/body")
  assert_contains "$body" "Fix the pager off-by-one for the test project." "the classifier request must carry the intent section"
  assert_contains "$body" "Keep the change small and covered by a test." "the classifier request must carry the spec section"
  assert_not_contains "$body" "SECRET-SETUP-TEXT" "the classifier request must never carry non-task brief content"
  assert_not_contains "$body" "SECRET-RULES-TEXT" "the classifier request must never carry non-task brief content"
  assert_not_contains "$body" "SECRET-DOD-TEXT" "the classifier request must never carry non-task brief content"
  pass "the optional typed classifier receives only the brief intent and spec sections"
}

test_supervision_prompt_stays_project_free() {
  local prompt instructions
  prompt=$("$ROOT/bin/fm-branch-prompt.sh")
  for harness in opencode pi claude; do
    instructions=$(FM_HOME="$TMP_ROOT/pin-sup-home-$harness" "$ROOT/bin/fm-supervision-instructions.sh" --harness "$harness")
    for needle in expo-bowling-journal swing-trader bag-tag-league expo-trading-journal qwen-local muse-spark opencode-go; do
      assert_not_contains "$instructions" "$needle" "the $harness supervision prompt must stay project-free (found $needle)"
    done
  done
  for needle in expo-bowling-journal swing-trader bag-tag-league expo-trading-journal qwen-local muse-spark opencode-go; do
    assert_not_contains "$prompt" "$needle" "the supervision branch prompt must stay project-free (found $needle)"
  done
  pass "the supervision prompt stays project-free"
}

test_project_profile_mapping_is_exact_match
test_correct_spawn_succeeds_on_the_pinned_profile
test_wrong_harness_for_a_pinned_project_is_refused_at_spawn
test_relaunch_naming_the_wrong_harness_is_refused_before_stop
test_raw_launch_command_cannot_bypass_the_project_profile
test_bowling_specifically_cannot_move_to_opencode
test_normal_project_specifically_cannot_move_to_pi
test_no_fallback_to_firstmate_on_worker_startup_or_dependency_failure
test_typed_classifier_receives_only_intent_and_spec_sections
test_supervision_prompt_stays_project_free
