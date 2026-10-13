#!/usr/bin/env bash
# Round-2 disposable live probe for the consultation-gate delivery provenance
# change (branch fm/fm-consult-provenance-c1, target a70b796c). Drives the
# real bin/fm-chatgpt-loop.sh and the real bin/fm-consult-gate-lib.sh against a
# throwaway FM_HOME. The only stubbed externals are the worker spawn and the
# fm-send handoff: the machine's real agent CLI/tmux is not needed to exercise
# the loop->gate file contract, and those stubs stand in for the environment,
# not for the product under test.
set -u
ROOT=${ROOT:-/Users/cortezashley/.no-mistakes/worktrees/26772a06f146/01M4SQCZ40RY5T5FST3V4MXFFD}
LOOP="$ROOT/bin/fm-chatgpt-loop.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe2.XXXXXX")
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

# Run the real gate exactly as a ship launch does, with the worker's own
# delivery field as the ONLY possible delivery evidence (no dispatch marker).
gate() { # <task-id>
  bash -c 'unset FM_CHATGPT_LOOP_DISPATCH_TASK; . "$0"; fm_consult_gate_check "$1" "$2" "$3" ship 0 ""' \
    "$ROOT/bin/fm-consult-gate-lib.sh" "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE" "$1"
}

setphase() { # <task> <jq-filter>
  local f="$FM_DATA_OVERRIDE/$1/chatgpt-loop.json"
  jq "$2" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

show_meta() { # <worker>
  if [ -f "$FM_STATE_OVERRIDE/$1.meta" ]; then sed -n 'p' "$FM_STATE_OVERRIDE/$1.meta"; else echo "(no $1.meta)"; fi
}

# write_loop_record <loop-task> <phase> <audit-prompt> <plan> [worker-task]
write_loop_record() {
  local d="$FM_DATA_OVERRIDE/$1" w=${5:-}
  mkdir -p "$d"
  jq -n --arg t "$1" --arg p "$2" --arg a "$3" --arg pl "$4" --arg w "$w" \
    '{task_id:$t, phase:$p, audit_prompt:$a, plan:$pl, worker_task:$w, iteration:1, updated_at:"2026-10-13T00:00:00Z"}' \
    > "$d/chatgpt-loop.json"
}

bash "$LOOP" init --task probe --objective-file "$LAB/objective.txt" >/dev/null

echo "############ S1: confirmed audit handoff records delivery on the worker; gate passes ############"
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT"'
bash "$LOOP" dispatch --stage audit --task probe -- w1 myproj --mode local-only --yolo off
echo "dispatch rc=$?"
echo "-- w1.meta --"; show_meta w1
echo "-- gate w1 --"; gate w1; echo "gate rc=$?"

echo
echo "############ S2: audit handoff fails at fm-send -> no delivery record; gate refuses ############"
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT" | .worker_task=""'
STUB_SEND_EXIT=1 bash "$LOOP" dispatch --stage audit --task probe -- w2 myproj --mode local-only --yolo off
echo "dispatch rc=$?"
echo "-- w2.meta (must hold no consult_delivered) --"; show_meta w2
echo "-- gate w2 --"; gate w2 >/dev/null 2>&1; echo "gate rc=$? (1 = refused)"

echo
echo "############ S3: stale audit, then a later PLAN handoff fails at fm-send ############"
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT" | .worker_task=""'
bash "$LOOP" dispatch --stage audit --task probe -- w3 myproj --mode local-only --yolo off >/dev/null
echo "audit dispatch rc=$? (confirmed audit delivery to w3)"
setphase probe '.phase="plan-dispatch" | .plan="PLAN PROMPT"'
STUB_SPAWN_PRESERVE=1 STUB_SEND_EXIT=1 bash "$LOOP" dispatch --stage plan --task probe -- w3 myproj --mode local-only --yolo off
echo "plan dispatch rc=$? (send failure)"
echo "-- w3.meta (earlier audit delivery must be gone) --"; show_meta w3
echo "-- gate w3 --"; gate w3 >/dev/null 2>&1; echo "gate rc=$? (1 = refused)"

echo
echo "############ S4 (ADVERSARIAL, the round-1 failure): later PLAN attempt fails at SPAWN ############"
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT" | .worker_task=""'
STUB_SPAWN_EXIT=0 bash "$LOOP" dispatch --stage audit --task probe -- w4 myproj --mode local-only --yolo off >/dev/null
echo "audit dispatch rc=$? (confirmed audit delivery to w4)"
echo "-- w4.meta before the failed plan attempt --"; show_meta w4
setphase probe '.phase="plan-dispatch" | .plan="PLAN PROMPT"'
STUB_SPAWN_PRESERVE=1 STUB_SPAWN_EXIT=1 bash "$LOOP" dispatch --stage plan --task probe -- w4 myproj --mode local-only --yolo off
echo "plan dispatch rc=$? (spawn failure)"
echo "loop phase: $(jq -r '.phase' "$FM_DATA_OVERRIDE/probe/chatgpt-loop.json")"
echo "-- w4.meta (stale audit delivery must NOT survive the failed plan attempt) --"; show_meta w4
echo "-- gate w4: the plan-stage launch this worker is awaiting --"
if gate w4 > "$LAB/s4.out" 2>&1; then echo "gate rc=0 -> PASSES (regression)"; else echo "gate rc=$? -> refused (required)"; fi
sed -n '1,3p' "$LAB/s4.out"

echo
echo "############ S5: a loop record's worker phase alone is NOT delivery evidence ############"
printf 'window=stub:fm-w5\nkind=ship\n' > "$FM_STATE_OVERRIDE/w5.meta"
write_loop_record legacy-loop audit-worker "the delivered audit prompt" "" w5
echo "-- w5.meta (no consult_delivered field) --"; show_meta w5
echo "-- gate w5 (loop record names w5 at audit-worker) --"
if gate w5 > "$LAB/s5.out" 2>&1; then echo "gate rc=0 -> PASSES (regression: removed inference)"; else echo "gate rc=$? -> refused (required)"; fi

echo
echo "############ S6: a consult_delivered value naming no delivered stage is not evidence ############"
printf 'window=stub:fm-w6\nkind=ship\nconsult_delivered=pending\n' > "$FM_STATE_OVERRIDE/w6.meta"
echo "-- gate w6 (value=pending) --"; gate w6 >/dev/null 2>&1; echo "gate rc=$? (1 = refused)"
printf 'window=stub:fm-w7\nkind=ship\nconsult_delivered=\n' > "$FM_STATE_OVERRIDE/w7.meta"
echo "-- gate w7 (value blank) --"; gate w7 >/dev/null 2>&1; echo "gate rc=$? (1 = refused)"
printf 'window=stub:fm-w8\nkind=ship\nconsult_delivered=audit\n' > "$FM_STATE_OVERRIDE/w8.meta"
echo "-- gate w8 (value=audit) --"; gate w8 >/dev/null 2>&1; echo "gate rc=$? (0 = passes)"

echo
echo "############ S7: the explicit recorded waiver still passes; unwaived still refuses ############"
printf 'window=stub:fm-w9\nkind=ship\n' > "$FM_STATE_OVERRIDE/w9.meta"
echo "-- gate w9 without a waiver --"; gate w9 >/dev/null 2>&1; echo "gate rc=$? (1 = refused)"
out=$(bash -c 'unset FM_CHATGPT_LOOP_DISPATCH_TASK; . "$0"; fm_consult_gate_check "$1" "$2" "$3" ship 1 "captain approved"; echo "reason=$FM_CONSULT_GATE_WAIVER_REASON"' \
  "$ROOT/bin/fm-consult-gate-lib.sh" "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE" w9 2>&1); rc=$?
echo "waived gate rc=$rc"; printf '%s\n' "$out"
bash -c 'unset FM_CHATGPT_LOOP_DISPATCH_TASK; . "$0"; fm_consult_gate_check "$1" "$2" "$3" ship 1 "   "' \
  "$ROOT/bin/fm-consult-gate-lib.sh" "$FM_DATA_OVERRIDE" "$FM_STATE_OVERRIDE" w9 >/dev/null 2>&1
echo "blank-reason waiver gate rc=$? (1 = refused, required)"

echo
echo "############ S8: next-round clears the finished round's delivery record ############"
setphase probe '.phase="audit-dispatch" | .audit_prompt="AUDIT PROMPT" | .worker_task=""'
bash "$LOOP" dispatch --stage audit --task probe -- w10 myproj --mode local-only --yolo off >/dev/null
echo "audit dispatch rc=$? (w10 delivery recorded)"
setphase probe '.phase="complete" | .worker_task="w10"'
bash "$LOOP" next-round --task probe >/dev/null; echo "next-round rc=$?"
echo "-- w10.meta (delivery must be cleared for the new round) --"; show_meta w10
echo "-- gate w10 after next-round --"; gate w10 >/dev/null 2>&1; echo "gate rc=$? (1 = refused, required)"

echo
echo "############ transcript complete ############"
