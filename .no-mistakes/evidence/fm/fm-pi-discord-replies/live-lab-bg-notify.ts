// Throwaway lab extension (evidence fixture, never committed): reproduces the
// upstream branch-supervision background delivery exactly as the fork relies
// on it - after the first settle it injects a custom_message with triggerTurn,
// i.e. `pi.sendMessage(..., { triggerTurn: true, deliverAs: "followUp" })`
// (.pi/extensions/fm-branch-supervision.ts:1131-1136).
import { writeFileSync } from "node:fs";

export default function (pi: any) {
  let fired = false;
  pi.on?.("agent_settled", (event: any) => {
    if (event?.aborted) return;
    if (fired) return;
    fired = true;
    writeFileSync(String(process.env.LAB_BG_MARKER), String(Date.now()));
    pi.sendMessage(
      {
        customType: "fm-branch-process",
        content: "<task-notification> task fm-x finished. Reply with exactly: BG-REPLY-2",
        display: true,
      },
      { triggerTurn: true, deliverAs: "followUp" },
    );
  });
}
