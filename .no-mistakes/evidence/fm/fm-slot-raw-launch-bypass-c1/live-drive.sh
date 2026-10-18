#!/usr/bin/env bash
# Live product drive for the hand-typed Strata launch bypass fix.
#
# Drives the REAL bin/fm-spawn.sh against a disposable marked lab home, a REAL
# private tmux server, and a REAL agent stand-in process (the same construction
# tests/fm-tmux-agent-liveness.test.sh uses), so the single-slot gate and the
# backend liveness reader both run for real. Every launched process is a
# harmless `echo`/`pi --help` or the stand-in; the guarded Strata engine is
# never started, and TREEHOUSE_ROOT is pinned inside the lab so no pool entry
# lands in the operator's home.
set -u

ROOT=/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M57PCKRD7EF0M0HVF8KVD5NZ
EVID=/Users/cortezashley/.no-mistakes/evidence/01M57PCKRD7EF0M0HVF8KVD5NZ
RUN="$EVID/live-run"
mkdir -p "$RUN"
SOCKET=fm-lab

SLOT='strata-local/qwen3.8-flash-next-coder-iq1_m'
OVERRIDE='single-slot-test/guarded-model'

PASS=0
FAIL=0
declare -a RESULTS=()

say() { printf '%s\n' "$*"; }
hr() { printf '%s\n' "------------------------------------------------------------------------"; }

record() { # <status> <name> <detail>
  RESULTS+=("$1 | $2 | $3")
  if [ "$1" = PASS ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  say "[$1] $2 -- $3"
}

check() { # <name> <condition-description> <0|1>
  local name=$1 desc=$2 ok=$3
  if [ "$ok" -eq 0 ]; then record PASS "$name" "$desc"; else record FAIL "$name" "$desc"; fi
}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
FIX="$LAB/fixture"
proj="$FIX/proj"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && { chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"; }
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { say "cannot mint lab home"; exit 2; }
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"

# --- disposable project fixture (real git repo + origin) --------------------
mkdir -p "$proj"
git -C "$proj" init -q -b main
printf 'hello\n' > "$proj/README.md"
git -C "$proj" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$proj" -c user.email=t@example.invalid -c user.name=t commit -qm init
git -C "$proj" init -q --bare "$proj.origin.git"
git -C "$proj" remote add origin "$proj.origin.git"
git -C "$proj" -c user.email=t@example.invalid -c user.name=t push -q origin main
touch "$LAB/state/.last-watcher-beat"

# --- real agent stand-in, symlinked as `pi` (harness liveness owner) --------
mkdir -p "$LAB/standin"
cat > "$LAB/standin/standin.c" <<'C'
#include <unistd.h>
int main(void){int i;for(i=0;i<600;i++)sleep(1);return 0;}
C
cc -o "$LAB/standin/standin" "$LAB/standin/standin.c" || { say "no C compiler"; exit 2; }
ln -s "$LAB/standin/standin" "$LAB/standin/pi"

# --- real private tmux server, pool kept inside the lab ---------------------
TREEHOUSE_ROOT="$LAB/treehouse" tmux -L "$SOCKET" new-session -d -s primary -c "$proj" -n shell
sock=$(tmux -L "$SOCKET" display-message -p '#{socket_path}')
pid=$(tmux -L "$SOCKET" display-message -p '#{pid}')
export TMUX="$sock,$pid,0"

windows() { tmux -L "$SOCKET" list-windows -t primary -F '#{window_name}' | sort; }
win_count() { windows | wc -l | tr -d ' '; }

brief() { # <id>
  mkdir -p "$LAB/data/$1"
  cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
live drive brief for $1

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

run_raw() { # <id> <raw command> [extra-fm-args...]
  local id=$1 raw=$2
  shift 2
  brief "$id"
  local out rc
  out=$(FM_HOME="$LAB" HOME="$LAB" TMUX="$TMUX" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$raw" --mode no-mistakes --yolo off --consult-waived live-drive "$@" 2>&1)
  rc=$?
  printf '%s\n' "$out" > "$RUN/raw-$id.log"
  printf '%s\n' "$rc" > "$RUN/raw-$id.rc"
}

run_ordinary() { # <id> <fm-args...>
  local id=$1
  shift
  brief "$id"
  local out rc
  out=$(FM_HOME="$LAB" HOME="$LAB" TMUX="$TMUX" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "$@" 2>&1)
  rc=$?
  printf '%s\n' "$out" > "$RUN/ordinary-$id.log"
  printf '%s\n' "$rc" > "$RUN/ordinary-$id.rc"
}

write_holder() { # <name> <window-command...>
  local name=$1
  shift
  tmux -L "$SOCKET" new-window -d -t primary: -n "fm-$name" -c "$proj" -- "$@"
  cat > "$LAB/state/$name.meta" <<EOF
harness=pi
model=$SLOT
window=primary:fm-$name
EOF
}

drop_holder() { # <name>
  tmux -L "$SOCKET" kill-window -t "primary:fm-$1" >/dev/null 2>&1 || true
  rm -f "$LAB/state/$1.meta"
}

hr
say "SCENARIO 1: a hand-typed Strata launch is refused before any engine starts"
say "  lab=$LAB  tmux=$SOCKET  socket=$sock"
before=$(win_count)
run_raw s1 "pi --model $SLOT"
rc=$(cat "$RUN/raw-s1.rc"); out=$(cat "$RUN/raw-s1.log"); after=$(win_count)
say "  exit=$rc"
say "$(printf '%s\n' "$out" | grep -E 'cannot launch|hand-typed' || true)"
check "s1-refused" "exit 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
check "s1-message" "output names hand-typed single-slot refusal" "$(printf '%s' "$out" | grep -q 'hand-typed launches of the single-slot engine' && echo 0 || echo 1)"
check "s1-supported-path-named" "output names --harness pi --model $SLOT" "$(printf '%s' "$out" | grep -q -- "--harness pi --model $SLOT" && echo 0 || echo 1)"
check "s1-no-record" "no state/s1.meta written" "$([ ! -e "$LAB/state/s1.meta" ] && echo 0 || echo 1)"
check "s1-no-window" "no new tmux window" "$([ "$before" = "$after" ] && echo 0 || echo 1)"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 2 (adversarial): quoting, wrappers, env prefixes, chaining, substitution and tabs cannot hide the engine"
i=0
for raw in "pi --model '$SLOT'" \
  'pi --model="'"$SLOT"'"' \
  "pi --model='$SLOT'" \
  "exec pi --model $SLOT" \
  "/usr/bin/env pi --model $SLOT" \
  "env FOO=1 pi --model $SLOT" \
  "env -i pi --model $SLOT" \
  "sh -c 'pi --model $SLOT'" \
  "bash -lc \"pi --model $SLOT\"" \
  "cd . && pi --model $SLOT" \
  "true; pi --model $SLOT" \
  "sudo pi --model $SLOT" \
  "command pi --model $SLOT" \
  "nice pi --model $SLOT" \
  '$(command -v pi) --model '"$SLOT" \
  "pi --model $SLOT"$'\t'"--tui-mode regular"; do
  i=$((i + 1))
  id="s2-$i"
  before=$(win_count)
  run_raw "$id" "$raw"
  rc=$(cat "$RUN/raw-$id.rc"); out=$(cat "$RUN/raw-$id.log"); after=$(win_count)
  okall=0
  [ "$rc" -eq 1 ] || okall=1
  printf '%s' "$out" | grep -q 'hand-typed launches of the single-slot engine' || okall=1
  [ ! -e "$LAB/state/$id.meta" ] || okall=1
  [ "$before" = "$after" ] || okall=1
  check "s2-$i" "spelling refused, no record, no window: $raw" "$okall"
done
hr

# ---------------------------------------------------------------------------
say "SCENARIO 3: raw launches naming no guarded engine still pass through the gate"
before=$(win_count)
run_raw s3a "echo raw-passthrough-ok"
rc=$(cat "$RUN/raw-s3a.rc"); out=$(cat "$RUN/raw-s3a.log"); after=$(win_count)
say "  exit=$rc :: $(printf '%s\n' "$out" | grep -E '^spawned' || true)"
check "s3a-allowed" "raw echo launch exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "s3a-window" "a tmux window fm-s3a was created" "$([ "$before" != "$after" ] && echo 0 || echo 1)"
check "s3a-meta" "record written with harness=echo" "$(grep -q '^harness=echo$' "$LAB/state/s3a.meta" 2>/dev/null && echo 0 || echo 1)"

run_raw s3b "custom-agent --flag pi"
rc=$(cat "$RUN/raw-s3b.rc"); out=$(cat "$RUN/raw-s3b.log")
check "s3b-other-adapter" "raw custom-agent mentioning pi exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "s3b-meta" "record written with harness=custom-agent" "$(grep -q '^harness=custom-agent$' "$LAB/state/s3b.meta" 2>/dev/null && echo 0 || echo 1)"

run_raw s3c "pi --model=openai-codex/gpt-5.6-sol --help"
rc=$(cat "$RUN/raw-s3c.rc"); out=$(cat "$RUN/raw-s3c.log")
check "s3c-unguarded-pi" "raw pi on an unguarded model is not gate-refused" "$([ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'hand-typed launches' && echo 0 || echo 1)"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 4: a live ordinary Strata worker (built-in default, no config file) refuses a second ordinary launch"
rm -f "$LAB/config/single-slot-profile"
write_holder holder-live "$LAB/standin/pi"
sleep 1
say "  holder window: $(tmux -L "$SOCKET" list-windows -t primary -F '#{window_name} #{pane_current_command}' | grep holder || true)"
run_ordinary s4 --harness pi --model "$SLOT" --mode no-mistakes --yolo off
rc=$(cat "$RUN/ordinary-s4.rc"); out=$(cat "$RUN/ordinary-s4.log")
say "  exit=$rc"
say "$(printf '%s\n' "$out" | grep -E 'cannot launch' || true)"
check "s4-refused" "second ordinary launch exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
check "s4-slot-message" "refusal is the single-slot refusal" "$(printf '%s' "$out" | grep -q 'runs a single slot' && echo 0 || echo 1)"
check "s4-names-holder" "refusal names the live holder-live" "$(printf '%s' "$out" | grep -q 'holder-live is live on that profile' && echo 0 || echo 1)"
check "s4-no-record" "refused launch wrote no state/s4.meta" "$([ ! -e "$LAB/state/s4.meta" ] && echo 0 || echo 1)"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 5: once the holding agent has exited, the same launch passes the gate"
drop_holder holder-live
# a window that survives with an idle shell = exited agent, record retained
tmux -L "$SOCKET" new-window -d -t primary: -n fm-holder-dead -c "$proj" -- /bin/sh
cat > "$LAB/state/holder-dead.meta" <<EOF
harness=pi
model=$SLOT
window=primary:fm-holder-dead
EOF
sleep 1
run_ordinary s5 --harness pi --model "$SLOT" --mode no-mistakes --yolo off
rc=$(cat "$RUN/ordinary-s5.rc"); out=$(cat "$RUN/ordinary-s5.log")
say "  exit=$rc"
say "$(printf '%s\n' "$out" | grep -E 'cannot launch' || true)"
check "s5-gate-open" "exited holder does not trigger the single-slot refusal" "$(! printf '%s' "$out" | grep -q 'runs a single slot' && echo 0 || echo 1)"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 6: every unusable config/single-slot-profile state keeps the built-in guard on"
drop_holder holder-dead
write_holder holder-live "$LAB/standin/pi"
sleep 1
: > "$LAB/config/single-slot-profile"
run_ordinary s6 --harness pi --model "$SLOT" --mode no-mistakes --yolo off
rc=$(cat "$RUN/ordinary-s6.rc"); out=$(cat "$RUN/ordinary-s6.log")
check "s6-empty-warns" "empty override warns and names the file" "$(printf '%s' "$out" | grep -q 'single-slot-profile' && echo 0 || echo 1)"
check "s6-default-still-guards" "empty override still refuses the second launch" "$(printf '%s' "$out" | grep -q 'runs a single slot' && echo 0 || echo 1)"
# a stale but well-formed value only ADDS coverage
printf '%s\n' 'single-slot-test/retired-model' > "$LAB/config/single-slot-profile"
run_ordinary s6b --harness pi --model "$SLOT" --mode no-mistakes --yolo off
rc=$(cat "$RUN/ordinary-s6b.rc"); out=$(cat "$RUN/ordinary-s6b.log")
check "s6b-stale-keeps-default" "stale override cannot disable the built-in default" "$(printf '%s' "$out" | grep -q 'runs a single slot' && echo 0 || echo 1)"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 7: the config-added guarded engine is refused hand-typed too"
printf '%s\n' "$OVERRIDE" > "$LAB/config/single-slot-profile"
before=$(win_count)
run_raw s7 "exec pi --model $OVERRIDE"
rc=$(cat "$RUN/raw-s7.rc"); out=$(cat "$RUN/raw-s7.log"); after=$(win_count)
say "  exit=$rc :: $(printf '%s\n' "$out" | grep -E 'cannot launch' || true)"
check "s7-refused" "hand-typed config-added engine refused" "$([ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "hand-typed launches of the single-slot engine $OVERRIDE" && echo 0 || echo 1)"
check "s7-no-window" "no window started" "$([ "$before" = "$after" ] && echo 0 || echo 1)"
rm -f "$LAB/config/single-slot-profile"
hr

# ---------------------------------------------------------------------------
say "SCENARIO 8: an ordinary non-pi harness naming the guarded model is not gated"
drop_holder holder-live
run_ordinary s8 --harness claude --model "$SLOT" --mode no-mistakes --yolo off
rc=$(cat "$RUN/ordinary-s8.rc"); out=$(cat "$RUN/ordinary-s8.log")
check "s8-not-slot-refused" "claude launch does not get the single-slot refusal" "$(! printf '%s' "$out" | grep -q 'runs a single slot' && echo 0 || echo 1)"
check "s8-not-raw-refused" "claude launch does not get the hand-typed refusal" "$(! printf '%s' "$out" | grep -q 'hand-typed launches' && echo 0 || echo 1)"
hr

say "SUMMARY: pass=$PASS fail=$FAIL"
for r in "${RESULTS[@]}"; do say "  $r"; done
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
