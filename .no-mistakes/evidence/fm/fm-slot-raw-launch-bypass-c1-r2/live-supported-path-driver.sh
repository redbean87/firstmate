#!/usr/bin/env bash
# Live end-to-end driver for the hand-typed-launch refusal change.
# Drives the real bin/fm-spawn.sh through a private tmux server on a
# disposable marked lab home (bin/fm-lab-home.sh), with a disposable git
# project, an isolated treehouse root, and a fake `pi` adapter that records
# when its engine actually starts. Everything is removed at the end.
set -u
WT=${WT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M58QGVJWZC2NGY9E47P611XW}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SOCK="$LAB/tmux"
LABHOME="$LAB/scratch/home"
THROOT="$LAB/scratch/treehouse"
TSPAWN=/opt/homebrew/bin/tmux
TMUXPATH="$LAB/scratch/bin:/Users/cortezashley/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cleanup() {
  HOME="$LABHOME" TMUX_TMPDIR="$SOCK" "$TSPAWN" -L fm-lab kill-server 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$SOCK" "$LAB/scratch/bin" "$LABHOME" "$LAB/project"
chmod 700 "$SOCK"

SLOT='strata-local/qwen3.8-flash-next-coder-iq1_m'
TRAP="$LAB/scratch/engine-trap.log"

# Fake pi: answers the version probe; when its engine actually starts it
# records one line and then execs a sleep whose argv0 is `pi`, so the backend
# liveness classifier sees a live pi-named agent exactly as it would for the
# real binary (verified: macOS `ps comm` carries argv0).
cat > "$LAB/scratch/bin/pi" <<PI
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --help|--version) printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode> --approve'; exit 0 ;;
esac
printf 'ENGINE-STARTED\n' >> "$TRAP"
exec -a pi sleep 3600
PI
chmod +x "$LAB/scratch/bin/pi"
: > "$TRAP"

# Disposable project repo.
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Minimal home state a ship spawn needs.
touch "$LAB/state/.last-watcher-beat"
printf 'pi\n' > "$LAB/config/crew-harness"
seed_task() { # <id> [intent]
  local id=$1 intent=${2:-live check}
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nnone\n' "$intent" > "$LAB/data/$id/brief.md"
  jq -n --arg t "$id" '{task_id:$t,phase:"audit-dispatch",audit_prompt:"seeded",prompt:"seeded",plan:"seeded",updated_at:"2026-01-01T00:00:00Z"}' > "$LAB/data/$id/chatgpt-loop.json"
}
count_starts() { grep -c '^ENGINE-STARTED$' "$TRAP" 2>/dev/null || true; }
tm() { HOME="$LABHOME" TREEHOUSE_ROOT="$THROOT" TMUX_TMPDIR="$SOCK" "$TSPAWN" -L fm-lab "$@"; }

# Private tmux server (never the default server). HOME and TREEHOUSE_ROOT are
# the lab's, so every pane and every treehouse worktree stays inside the lab.
tm new-session -d -s primary -c "$LAB/project"
echo "private tmux server started on $SOCK (session primary)"
echo "lab HOME=$LABHOME treehouse root=$THROOT"

run_spawn_window() { # <name> <outfile> <rcfile> <args...>
  local name=$1 out=$2 rc=$3; shift 3
  local cmd
  cmd=$(printf '%q ' "$WT/bin/fm-spawn.sh" "$@")
  tm new-window -d -t primary: -n "$name" -c "$LAB/project" \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' TREEHOUSE_ROOT='$THROOT' PATH='$TMUXPATH' HOME='$LABHOME' $cmd >'$out' 2>&1; echo \$? >'$rc'"
}

wait_rc() { # <rcfile> <timeout-seconds>
  local rc=$1 t=${2:-120} i=0
  while [ ! -f "$rc" ]; do
    i=$((i+1)); [ "$i" -lt $((t*2)) ] || { echo "TIMEOUT waiting for $rc"; return 1; }
    sleep 0.5
  done
  cat "$rc"
}

# Probe the backend liveness verdict from inside a pane of the private server,
# so the probe inherits the same $TMUX the product itself uses.
probe_liveness() { # <label> <target>
  local label=$1 target=$2 out pname
  out="$LAB/scratch/probe-$label.out"
  pname="probe-$label"
  cat > "$LAB/scratch/probe.sh" <<EOF
#!/usr/bin/env bash
. '$WT/bin/fm-backend.sh'
printf 'fm_backend_agent_alive(%s) = %s\n' '$target' "\$(fm_backend_agent_alive tmux '$target')"
EOF
  chmod +x "$LAB/scratch/probe.sh"
  rm -f "$out"
  tm new-window -d -t primary: -n "$pname" -c "$LAB/project" "bash '$LAB/scratch/probe.sh' >'$out' 2>&1"
  local i=0
  while [ ! -f "$out" ]; do i=$((i+1)); [ "$i" -lt 60 ] || { echo "probe $label TIMEOUT"; return 1; }; sleep 0.5; done
  cat "$out"
}

echo
echo "==================== SCENARIO C: supported path starts + records ===================="
seed_task live-supported
run_spawn_window spawn-supported "$LAB/out-supported" "$LAB/rc-supported" \
  live-supported "$LAB/project" --mode no-mistakes --yolo off --harness pi --model "$SLOT"
rc=$(wait_rc "$LAB/rc-supported" 180); echo "spawn rc=$rc"
grep -E '^spawned ' "$LAB/out-supported" | sed 's/^/  | /'
echo "--- recorded meta state/live-supported.meta ---"
cat "$LAB/state/live-supported.meta" 2>/dev/null | sed 's/^/  | /' || echo "  (no meta)"
echo "--- engine starts observed: $(count_starts) ---"
echo "--- tmux windows on the private server ---"
tm list-windows -t primary -F '  #{window_id} #{window_name} #{pane_current_command}' 2>&1
holder_window=$(sed -n 's/^window=//p' "$LAB/state/live-supported.meta" 2>/dev/null)
echo "recorded window: ${holder_window:-<none>}"

echo
echo "==================== SCENARIO E: recorded worker discoverable by a later check ===================="
probe_liveness e "$holder_window" | sed 's/^/  | /'

echo
echo "==================== SCENARIO D: second supported launch refused while first live ===================="
seed_task live-second
starts_before=$(count_starts)
run_spawn_window spawn-second "$LAB/out-second" "$LAB/rc-second" \
  live-second "$LAB/project" --mode no-mistakes --yolo off --harness pi --model "$SLOT"
rc2=$(wait_rc "$LAB/rc-second" 180); echo "second spawn rc=$rc2"
grep -E '^error: ' "$LAB/out-second" | sed 's/^/  | /'
echo "second task meta present: $([ -e "$LAB/state/live-second.meta" ] && echo yes || echo no)"
echo "engine starts added by second attempt: $(( $(count_starts) - starts_before ))"

echo
echo "==================== SCENARIO F: slot reopens after the holder exits ===================="
tm kill-window -t "$holder_window" 2>/dev/null || echo "kill-window failed"
sleep 2
probe_liveness f "$holder_window" | sed 's/^/  | /'
rm -f "$LAB/rc-third"
run_spawn_window spawn-third "$LAB/out-third" "$LAB/rc-third" \
  live-second "$LAB/project" --mode no-mistakes --yolo off --harness pi --model "$SLOT"
rc3=$(wait_rc "$LAB/rc-third" 180); echo "third spawn rc=$rc3"
grep -E '^spawned |^error: ' "$LAB/out-third" | sed 's/^/  | /'

echo
echo "==================== teardown ===================="
tm kill-server 2>/dev/null && echo "private tmux server killed"
