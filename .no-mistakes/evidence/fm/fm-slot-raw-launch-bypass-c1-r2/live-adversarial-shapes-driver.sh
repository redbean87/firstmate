#!/usr/bin/env bash
# Live adversarial driver: try to smuggle a hand-typed launch through shapes
# that the old recognition-based gate used to miss (a whitespace-bearing
# --harness value, tab/newline separators, a shell wrapper, a single-token
# path). Every one must be refused with no engine process and no task record.
set -u
WT=${WT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M58QGVJWZC2NGY9E47P611XW}
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX); trap 'chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/scratch/bin" "$LAB/scratch/home" "$LAB/project"
TRAP="$LAB/scratch/trap.log"
cat > "$LAB/scratch/bin/pi" <<PI
#!/usr/bin/env bash
set -u
case "\${1:-}" in --help|--version) printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode> --approve'; exit 0;; esac
printf 'ENGINE-STARTED\n' >> "$TRAP"; exec -a pi sleep 3600
PI
chmod +x "$LAB/scratch/bin/pi"; : > "$TRAP"
git -C "$LAB/project" init -q -b main; git -C "$LAB/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
touch "$LAB/state/.last-watcher-beat"; printf 'pi\n' > "$LAB/config/crew-harness"
SLOT='strata-local/qwen3.8-flash-next-coder-iq1_m'
i=0
run() { # <label> <args...>
  local label=$1; shift; i=$((i+1)); local id="adv-$i"
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nadv\n\n## Firstmate spec\nnone\n' > "$LAB/data/$id/brief.md"
  jq -n --arg t "$id" '{task_id:$t,phase:"audit-dispatch",audit_prompt:"s",prompt:"s",plan:"s",updated_at:"2026-01-01T00:00:00Z"}' > "$LAB/data/$id/chatgpt-loop.json"
  local out rc
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PATH="$LAB/scratch/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$LAB/scratch/home" \
    "$WT/bin/fm-spawn.sh" "$id" "$LAB/project" --mode no-mistakes --yolo off "$@" 2>&1); rc=$?
  printf '%s | rc=%s refusal=%s meta=%s\n  msg: %s\n' "$label" "$rc" \
    "$(printf '%s' "$out" | grep -c 'hand-typed launch commands are unsupported for every adapter')" \
    "$([ -e "$LAB/state/$id.meta" ] && echo yes || echo no)" \
    "$(printf '%s' "$out" | grep -E '^error: ' | head -1)"
}
run 'harness-arg-space'   --harness "pi --model $SLOT"
run 'harness-arg-wrapper' --harness "sh -c 'pi --model $SLOT'"
run 'harness-eq-space'    --harness="pi --model $SLOT"
run 'newline-separated'   "pi
--model $SLOT"
run 'tab-separated'       "$(printf 'pi\t--model %s' "$SLOT")"
run 'single-token-path'   "/usr/bin/pi"
echo "engine starts across all adversarial shapes: $(grep -c '^ENGINE-STARTED$' "$TRAP")"
