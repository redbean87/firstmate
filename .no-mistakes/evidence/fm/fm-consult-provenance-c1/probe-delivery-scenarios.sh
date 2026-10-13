#!/usr/bin/env bash
# Disposable live probe for the consultation-gate delivery provenance change
# (branch fm/fm-consult-provenance-c1). Drives the real
# bin/fm-chatgpt-loop.sh and bin/fm-consult-gate-lib.sh executables against a
# throwaway FM_HOME. The only stubbed externals are the worker spawn and the
# fm-send handoff (the machine's real tmux/agent launch is not needed to
# exercise the gate's file-level contract).
set -u
ROOT=${ROOT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M4SQCZ40RY5T5FST3V4MXFFD}
LOOP="$ROOT/bin/fm-chatgpt-loop.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export FM_HOME="$LAB/home"
export FM_DATA_OVERRIDE="$FM_HOME/data"
export FM_STATE_OVERRIDE="$FM_HOME/state"
mkdir -p "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE"
printf 'Fix the two failing CI checks.\n' > "$LAB/objective.txt"

cat > "$LAB/spawn.sh" <<'SH'
#!/usr/bin/env bash
meta="${FM_STATE_OVERRIDE:?}/$1.meta"
if [ "${STUB_SPAWN_PRESERVE:-0}" = 1 ] && [ -f "$meta" ]; then
  grep -v '^window=' "$meta" > "$meta.tmp" || true
  printf 'window=stub:fm-%s\n' "$1" >> "$meta.tmp"
  mv "$meta.tmp" "$meta"
else
  printf 'window=stub:fm-%s\nkind=ship\n' "$1" > "$meta"
fi
if [ "${STUB_SPAWN_EXIT:-0}" != 0 ]; then
  printf 'stub spawn: simulated failure\n' >&2
fi
exit "${STUB_SPAWN_EXIT:-0}"
SH
chmod +x "$LAB/spawn.sh"
cat > "$LAB/send.sh" <<'SH'
#!/usr/bin/env bash
# Records the handoff for the transcript; exits nonzero to simulate a failed
# fm-send handoff when STUB_SEND_EXIT is set.
printf 'send target=%s\n' "$1" >> "${PROBE_LOG:-/dev/null}"
if [ "${STUB_SEND_EXIT:-0}" != 0 ]; then
  printf 'stub send: simulated handoff failure\n' >&2
fi
exit "${STUB_SEND_EXIT:-0}"
SH
chmod +x "$LAB/send.sh"
export FM_CHATGPT_LOOP_SPAWN="$LAB/spawn.sh"
export FM_CHATGPT_LOOP_SEND="$LAB/send.sh"
export PROBE_LOG="$LAB/probe.log"

gate() { # <task-id>: run the real gate exactly as a ship launch would
  bash -c '. "$0"; fm_consult_gate_check "$1" "$2" "$3" ship 0 ""' \
    "$ROOT/bin/fm-consult-gate-lib.sh" "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE" "$1"
}

setphase() { # <task> <jq-filter>
  local f="$FM_DATA_OVERRIDE/$1/chatgpt-loop.json"
  jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

show_meta() { # <worker>
  if [ -f "$FM_STATE_OVERRIDE/$1.meta" ]; then
    sed -n 'p' "$FM_STATE_OVERRIDE/$1.meta"
  else
    echo "(no $1.meta)"
  fi
}

echo "############ S1: audit handoff confirmed -> delivery recorded, gate passes ############"
bash "$LOOP" init --task probe --objective-file "$LAB/objective.txt" >/dev/null
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT"'
bash "$LOOP" dispatch --stage audit --task probe -- w1 myproj --mode local-only --yolo off
echo "dispatch rc=$?"
echo "-- w1.meta --"; show_meta w1
echo "-- gate w1 --"; gate w1; echo "gate rc=$?"

echo
echo "############ S2: later plan handoff to the SAME worker fails at fm-send ############"
setphase probe '.phase="plan-dispatch" | .plan="PLAN PROMPT"'
STUB_SPAWN_PRESERVE=1 STUB_SEND_EXIT=1 bash "$LOOP" dispatch --stage plan --task probe -- w1 myproj --mode local-only --yolo off
echo "dispatch rc=$?"
echo "-- w1.meta (earlier audit delivery must be gone) --"; show_meta w1
echo "-- gate w1 --"; gate w1 >/dev/null 2>&1; echo "gate rc=$? (1 = refused, as required)"

echo
echo "############ S3 (ADVERSARIAL): later plan attempt fails at SPAWN, before clear ############"
setphase probe '.phase="audit-dispatch" | .plan="" | .worker_task=""'
STUB_SPAWN_EXIT=0 bash "$LOOP" dispatch --stage audit --task probe -- w2 myproj --mode local-only --yolo off >/dev/null
echo "audit dispatch rc=$? (confirmed audit delivery to w2)"
echo "-- w2.meta --"; show_meta w2
setphase probe '.phase="plan-dispatch" | .plan="PLAN PROMPT"'
STUB_SPAWN_PRESERVE=1 STUB_SPAWN_EXIT=1 bash "$LOOP" dispatch --stage plan --task probe -- w2 myproj --mode local-only --yolo off
echo "plan dispatch rc=$? (spawn failure)"
echo "loop phase: $(jq -r '.phase' "$FM_DATA_OVERRIDE/probe/chatgpt-loop.json")"
echo "-- w2.meta (stale audit delivery survives the failed plan attempt) --"; show_meta w2
echo "-- gate w2: the plan-stage launch this worker is awaiting --"
if gate w2 > "$LAB/s3.out" 2>&1; then echo "gate rc=0 -> PASSES on the stale audit delivery (BUG)"; else echo "gate rc=$? -> refused"; fi
sed -n '1,4p' "$LAB/s3.out"
