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
# <fakedir>/ps-fail.<pid> makes that process's start-time read fail.
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
        ;;
    esac
    # Anything but a liveness probe on that session goes to the upstream stub.
    ;;
esac
if [ -x "$0.upstream" ]; then exec "$0.upstream" "$@"; fi
exit 0
SH
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
FAKE='$fakedir'
SH
  cat >> "$fakebin/ps" <<'SH'
# A process whose start-time read must fail (an unconfirmable owner).
if [ "${1:-} ${2:-}" = "-o lstart=" ] && [ -f "$FAKE/ps-fail.${4:-}" ]; then exit 2; fi
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

# Herdr liveness fixture. A fake `herdr` client answers the four read-only
# calls upstream's recovery-grade Herdr classifier makes - `pane get`,
# `agent get`, `pane process-info --pane`, and `status --json`, each with
# `--session <s>` - from per-pane files under <fakedir>/herdr/<session>/<pane>
# (':' in a pane id becomes '_'):
#   pane    present | gone | garbage         (`pane get`)
#   agent   none | <agent_status> | garbage  (`agent get`; none = agent_not_found)
#   proc    ok | fail | malformed            (`pane process-info`)
#   fg      JSON array of foreground processes for process-info
#   shell   the pane's shell pid (a real live process, so upstream's
#           descendant walk over the real process table can find it)
# and <fakedir>/herdr/<session>/server: running | stopped | garbage.
# This exercises upstream's real classifier code; it is not a real Herdr.
fork_herdr_fake() {  # <fakebin> <fakedir>
  mkdir -p "$1" "$2/herdr"
  cat > "$1/herdr" <<SH
#!/usr/bin/env bash
FAKE='$2/herdr'
SH
  cat >> "$1/herdr" <<'SH'
session=
prev=
for a in "$@"; do [ "$prev" = --session ] && session=$a; prev=$a; done
dir="$FAKE/$session"
pane_dir() { printf '%s/%s' "$dir" "$(printf '%s' "$1" | tr ':' '_')"; }
case "$1 ${2:-}" in
  "status --json")
    case "$(cat "$dir/server" 2>/dev/null)" in
      running) echo '{"server":{"running":true}}' ;;
      stopped) echo '{"server":{"running":false}}' ;;
      *) echo 'not json' ;;
    esac ;;
  "pane get")
    p=$(pane_dir "$3")
    case "$(cat "$p/pane" 2>/dev/null)" in
      present) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
      gone) echo '{"error":{"code":"pane_not_found"}}' ;;
      *) echo 'not json' ;;
    esac ;;
  "agent get")
    p=$(pane_dir "$3")
    case "$(cat "$p/agent" 2>/dev/null)" in
      none) echo '{"error":{"code":"agent_not_found"}}' ;;
      garbage|'') echo 'not json' ;;
      *) printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$(cat "$p/agent")" ;;
    esac ;;
  "pane process-info")
    pane=; prev=; for a in "$@"; do [ "$prev" = --pane ] && pane=$a; prev=$a; done
    p=$(pane_dir "$pane")
    case "$(cat "$p/proc" 2>/dev/null)" in
      ok) ;;
      malformed) echo '{"result":{"type":"pane_process_info","process_info":'; exit 0 ;;
      *) exit 1 ;;
    esac
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_processes":%s}}}\n' \
      "$pane" "$(cat "$p/shell")" "$(cat "$p/fg")" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$1/herdr"
}

# fork_herdr_holder <home> <fakedir> <id> <model> <session> <pane> <state> <shell-pid>
# Record a herdr-backed task whose pane reads as <state>:
#   live         registered (idle) with a Pi process in the foreground
#   live-other   registered (working) with a non-shell, non-agent foreground
#   no-agent     pane exists, nothing registered, only a shell
#   no-agent-pi  pane exists, nothing registered, but a Pi process is running
#   no-agent-other      nothing registered, a non-shell non-agent foreground
#   no-agent-procfail   nothing registered, process-info fails
#   no-agent-malformed  nothing registered, process-info answers malformed JSON
#   stale-agent  registered (idle) but only a shell remains
#   proc-fail    registered, but process-info fails
#   gone         pane_not_found
#   garbage      pane get returns an unparseable answer
fork_herdr_holder() {
  local home=$1 fakedir=$2 id=$3 model=$4 session=$5 pane=$6 state=$7 shell=$8 p
  p="$fakedir/herdr/$session/$(printf '%s' "$pane" | tr ':' '_')"
  mkdir -p "$p" "$home/state"
  [ -e "$fakedir/herdr/$session/server" ] || printf 'running\n' > "$fakedir/herdr/$session/server"
  printf '%s\n' "kind=ship" "harness=pi" "model=$model" "backend=herdr" "window=$session:$pane" > "$home/state/$id.meta"
  printf '%s\n' "$shell" > "$p/shell"
  printf 'ok\n' > "$p/proc"
  printf 'present\n' > "$p/pane"
  local shellfg pifg
  shellfg="[{\"pid\":$shell,\"name\":\"zsh\",\"argv0\":\"zsh\"}]"
  pifg="[{\"pid\":$shell,\"name\":\"node\",\"argv0\":\"pi\",\"argv\":[\"pi\",\"--model\",\"$model\"]}]"
  case "$state" in
    live) printf 'idle\n' > "$p/agent"; printf '%s\n' "$pifg" > "$p/fg" ;;
    live-other) printf 'working\n' > "$p/agent"; printf '[{"pid":%s,"name":"vim","argv0":"vim"}]\n' "$shell" > "$p/fg" ;;
    no-agent) printf 'none\n' > "$p/agent"; printf '%s\n' "$shellfg" > "$p/fg" ;;
    no-agent-pi) printf 'none\n' > "$p/agent"; printf '%s\n' "$pifg" > "$p/fg" ;;
    no-agent-other) printf 'none\n' > "$p/agent"; printf '[{"pid":%s,"name":"vim","argv0":"vim"}]\n' "$shell" > "$p/fg" ;;
    no-agent-procfail) printf 'none\n' > "$p/agent"; printf 'fail\n' > "$p/proc"; printf '[]\n' > "$p/fg" ;;
    no-agent-malformed) printf 'none\n' > "$p/agent"; printf 'malformed\n' > "$p/proc"; printf '[]\n' > "$p/fg" ;;
    stale-agent) printf 'idle\n' > "$p/agent"; printf '%s\n' "$shellfg" > "$p/fg" ;;
    proc-fail) printf 'idle\n' > "$p/agent"; printf 'fail\n' > "$p/proc"; printf '[]\n' > "$p/fg" ;;
    gone) printf 'gone\n' > "$p/pane" ;;
    garbage) printf 'garbage\n' > "$p/pane" ;;
    *) fail "fork_herdr_holder: unknown state $state" ;;
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
