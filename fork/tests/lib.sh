#!/usr/bin/env bash
# Shared helpers for the fork's own test suite (fork/tests/*.test.sh).
#
# Fork tests drive the REAL upstream bin/fm-spawn.sh and bin/fm-control.sh so
# they prove the hook wiring, not a copy of it. They reuse upstream's shared
# test libraries (tests/lib.sh, tests/fixtures.sh), which CONTRIBUTING.md
# documents as the helpers suites source, and never edit upstream tests.
# Relaunch tests additionally lift four fixture functions from upstream's
# relaunch suite (fork_lift_relaunch_fixture); a renamed or removed function
# stops the suite with FIXTURE-DRIFT instead of silently testing less.

FORK_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/fixtures.sh
. "$FORK_TESTS_DIR/../../tests/fixtures.sh"
# shellcheck disable=SC2034 # read by the test files that source this library
POLICY="$ROOT/fork/bin/fm-launch-policy"

# fork_run_tests: run every test_* function in its own subshell so one failure
# reports and the rest still run; exit non-zero if any failed.
fork_run_tests() {
  local t rc=0
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    ( "$t" ) || rc=1
  done
  return "$rc"
}

# fork_policies <home> <policy...>: activate fork policy in a fixture home.
fork_policies() {
  local home=$1
  shift
  mkdir -p "$home/config"
  printf '%s\n' "$@" > "$home/config/fork-policies"
}

# fork_loop_record <home> <id> <phase> <field> <text>: a ChatGPT loop record.
fork_loop_record() {
  mkdir -p "$1/data/$2"
  jq -n --arg phase "$3" --arg field "$4" --arg text "$5" '{phase: $phase} + {($field): $text}' \
    > "$1/data/$2/chatgpt-loop.json"
}

# fork_waiver <home> <id> <origin> [reason]
fork_waiver() {
  mkdir -p "$1/data/$2"
  jq -n --arg origin "$3" --arg reason "${4-bridge unavailable, captain approved proceeding}" \
    '{origin: $origin, reason: $reason}' > "$1/data/$2/fork-consult-waiver.json"
}

# Liveness fixture for resource holders. Holders live in tmux session
# FORK_HOLDER_SESSION; a fake tmux answers that session's inventory and pane
# reads, and a fake ps answers their foreground process, so upstream's own
# fm_backend_agent_state classifies each holder from real code paths. Every
# other tmux call is handed to <fakebin>/tmux.upstream when present (the
# upstream spawn stub), and every other ps call to the system ps.
FORK_HOLDER_SESSION=fmholders

# fork_liveness_fakes <fakebin> <fakedir>: install the fake tmux/ps. If
# <fakebin>/tmux already exists it is kept as tmux.upstream for delegation.
fork_liveness_fakes() {
  local fakebin=$1 fakedir=$2
  mkdir -p "$fakebin" "$fakedir"
  : > "$fakedir/windows"
  [ ! -e "$fakebin/tmux" ] || mv "$fakebin/tmux" "$fakebin/tmux.upstream"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
FAKE='$fakedir'
SESSION='$FORK_HOLDER_SESSION'
SH
  cat >> "$fakebin/tmux" <<'SH'
target=
prev=
for a in "$@"; do [ "$prev" = -t ] && target=${a#=}; prev=$a; done
case "$target" in
  "$SESSION"|"$SESSION":*)
    case "$1" in
      list-windows)
        if [ -f "$FAKE/inventory-broken" ]; then echo 'lost server' >&2; exit 1; fi
        cat "$FAKE/windows"; exit 0 ;;
      display-message)
        win=${target#*:}
        for a in "$@"; do
          case "$a" in
            *pane_tty*) printf '/dev/fk-%s\n' "$win"; exit 0 ;;
            *pane_current_command*) cat "$FAKE/comm.$win" 2>/dev/null || echo zsh; exit 0 ;;
          esac
        done
        exit 0 ;;
    esac
    exit 0 ;;
esac
if [ -x "$0.upstream" ]; then exec "$0.upstream" "$@"; fi
exit 0
SH
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
FAKE='$fakedir'
SH
  cat >> "$fakebin/ps" <<'SH'
case "${1:-} ${2:-}" in
  "-t fk-"*)
    win=${2#fk-}
    [ -f "$FAKE/comm.$win" ] || exit 0
    printf '%s %s %s %s\n' "$(cat "$FAKE/pid.$win")" "$(cat "$FAKE/pid.$win")" "$(cat "$FAKE/pid.$win")" "$(cat "$FAKE/comm.$win")"
    exit 0 ;;
  "-p "*)
    for f in "$FAKE"/pid.*; do
      [ -f "$f" ] && [ "$(cat "$f")" = "$2" ] && { cat "$FAKE/comm.${f##*/pid.}"; exit 0; }
    done ;;
esac
exec /bin/ps "$@"
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps"
}

# fork_holder <home> <fakedir> <id> <model> <alive|dead|ambiguous|missing|unverified>
# Record a task on <model> whose endpoint reads as the given liveness state.
FORK_HOLDER_PID=41000
fork_holder() {
  local home=$1 fakedir=$2 id=$3 model=$4 state=$5 win
  win="fm-$id"
  mkdir -p "$home/state"
  printf '%s\n' "kind=ship" "harness=pi" "model=$model" "window=$FORK_HOLDER_SESSION:$win" > "$home/state/$id.meta"
  FORK_HOLDER_PID=$((FORK_HOLDER_PID + 1))
  printf '%s\n' "$FORK_HOLDER_PID" > "$fakedir/pid.$win"
  case "$state" in
    alive) printf '%s\n' "$win" >> "$fakedir/windows"; printf 'pi\n' > "$fakedir/comm.$win" ;;
    dead) printf '%s\n' "$win" >> "$fakedir/windows"; printf 'zsh\n' > "$fakedir/comm.$win" ;;
    ambiguous) printf '%s\n' "$win" >> "$fakedir/windows"; printf 'vim\n' > "$fakedir/comm.$win" ;;
    missing) rm -f "$fakedir/pid.$win" ;;
    unverified) printf '%s\n' "backend=zellij" >> "$home/state/$id.meta" ;;
    *) fail "fork_holder: unknown state $state" ;;
  esac
}

# fork_lift_relaunch_fixture: define upstream's relaunch-suite fixture
# functions (tmux lifecycle stub, case builder, live ship task, control runner).
fork_lift_relaunch_fixture() {
  local suite="$ROOT/tests/fm-control-relaunch.test.sh" fn body
  for fn in make_tmux_stub new_case add_ship_task run_control; do
    body=$(sed -n "/^$fn() {/,/^}/p" "$suite")
    if [ -z "$body" ]; then
      printf 'not ok - FIXTURE-DRIFT: %s no longer defines %s(); update fork/tests/lib.sh\n' "${suite#"$ROOT"/}" "$fn" >&2
      exit 3
    fi
    eval "$body"
  done
}
