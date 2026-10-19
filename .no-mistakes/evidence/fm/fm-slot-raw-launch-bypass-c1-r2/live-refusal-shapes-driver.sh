#!/usr/bin/env bash
# Live driver for the hand-typed-launch refusal: drives the real
# bin/fm-spawn.sh on a disposable marked lab home (bin/fm-lab-home.sh) and
# checks that every spelling of a hand-typed launch is refused with the same
# single diagnostic before any engine process starts.
#
# A fake `pi` adapter records whenever its engine is actually executed, so
# "no engine start" is observed, not assumed. Everything is removed at the end.
set -u
WT=${WT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M58QGVJWZC2NGY9E47P611XW}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { chmod -R u+w "$LAB" 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT

"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/scratch/bin" "$LAB/scratch/home" "$LAB/project"
TRAP="$LAB/scratch/engine-trap.log"
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
git -C "$LAB/project" init -q -b main
git -C "$LAB/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
touch "$LAB/state/.last-watcher-beat"
printf 'pi\n' > "$LAB/config/crew-harness"
SLOT='strata-local/qwen3.8-flash-next-coder-iq1_m'
PASS=0; FAIL=0

seed_task() { # <id>
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nlive refusal check\n\n## Firstmate spec\nnone\n' > "$LAB/data/$1/brief.md"
  jq -n --arg t "$1" '{task_id:$t,phase:"audit-dispatch",audit_prompt:"seeded",prompt:"seeded",plan:"seeded",updated_at:"2026-01-01T00:00:00Z"}' > "$LAB/data/$1/chatgpt-loop.json"
}

i=0
run_raw() { # <label> <raw>
  local label=$1 raw=$2 id out rc msg_ok starts_before starts_after meta
  i=$((i+1)); id="raw-$i"
  seed_task "$id"
  starts_before=$(grep -c '^ENGINE-STARTED$' "$TRAP" 2>/dev/null || true)
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PATH="$LAB/scratch/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$LAB/scratch/home" \
    "$WT/bin/fm-spawn.sh" "$id" "$LAB/project" --mode no-mistakes --yolo off "$raw" 2>&1)
  rc=$?
  starts_after=$(grep -c '^ENGINE-STARTED$' "$TRAP" 2>/dev/null || true)
  msg_ok=$(printf '%s' "$out" | grep -c 'hand-typed launch commands are unsupported for every adapter')
  [ -e "$LAB/state/$id.meta" ] && meta=yes || meta=no
  if [ "$rc" = 1 ] && [ "$msg_ok" = 1 ] && [ "$meta" = no ] && [ "$starts_after" = "$starts_before" ]; then
    PASS=$((PASS+1)); verdict=PASS
  else
    FAIL=$((FAIL+1)); verdict=FAIL
  fi
  printf '%-4s %-16s rc=%s refusal-names-supported-path=%s meta=%s engine-starts=%s\n' \
    "$verdict" "$label" "$rc" "$msg_ok" "$meta" "$((starts_after-starts_before))"
  printf '      raw: %s\n' "$raw"
  printf '%s\n' "$out" | grep -E '^error: ' | sed 's/^/      /'
}

echo "=== hand-typed shapes: each must be refused with the same single diagnostic, no engine, no record ==="
run_raw plain           "pi --model $SLOT"
run_raw single-quoted   "pi --model '$SLOT'"
run_raw double-quoted   "pi --model=\"$SLOT\""
run_raw quoted-launcher "'pi' --model $SLOT"
run_raw env-prefix      "env FOO=1 pi --model $SLOT"
run_raw abspath-env     "/usr/bin/env pi --model $SLOT"
run_raw exec            "exec pi --model $SLOT"
run_raw command         "command pi --model $SLOT"
run_raw nohup           "nohup pi --model $SLOT"
run_raw sh-c-wrapper    "sh -c 'pi --model $SLOT'"
run_raw command-subst   "\$(command -v pi) --model $SLOT"
run_raw chaining        "cd . && pi --model $SLOT"
run_raw backgrounded    "pi --model $SLOT &"
run_raw pi-no-model     "pi --tui-mode regular"
run_raw pi-other-engine "pi --model some/other-model"
run_raw claude-raw      "claude --model sonnet"
run_raw custom-agent    "custom-agent --flag pi"
run_raw other-tool      "other --prompt 'use pi here'"

echo
echo "=== operator-facing guidance (intent requirement 3) ==="
help_out=$(env -u NO_MISTAKES_GATE FM_HOME="$LAB" HOME="$LAB/scratch/home" PATH="$LAB/scratch/bin:$PATH" \
  "$WT/bin/fm-spawn.sh" --help 2>&1 || true)
printf '%s\n' "$help_out" | grep -nE 'hand-typed|--harness|launch-command' | sed 's/^/  /'
printf '  usage line still advertises a raw launch-command form: '
printf '%s\n' "$help_out" | grep -cE 'launch-command' || true
printf '  usage names the supported --harness path: '
printf '%s\n' "$help_out" | grep -c 'Hand-typed launch commands are refused before any engine starts' || true

echo
echo "=== unknown-harness diagnostic no longer offers a raw command ==="
seed_task raw-none
err_out=$(env -u NO_MISTAKES_GATE FM_HOME="$LAB" HOME="$LAB/scratch/home" PATH="$LAB/scratch/bin:$PATH" \
  "$WT/bin/fm-spawn.sh" raw-none "$LAB/project" --mode no-mistakes --yolo off --harness definitely-not-an-adapter 2>&1 || true)
printf '%s\n' "$err_out" | grep -E '^error: ' | sed 's/^/  /'

echo
echo "=== summary: $PASS refused as required, $FAIL unexpected ==="
