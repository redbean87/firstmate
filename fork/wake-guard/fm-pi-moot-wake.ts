// Firstmate fork: moot-wake settlement for the Pi primary watcher
// (fork/wake-guard/README).
//
// The upstream watch extension (.pi/extensions/fm-primary-pi-watch.ts) never
// consults the wake queue before it delivers an actionable close, and replays
// an accepted-but-unconsumed close into a replacement session. A wake whose
// queue rows were drained in the meantime therefore reaches main again, and
// main's drain prints nothing: a full model turn spent on a moot doorbell.
//
// This extension closes that gap through the extension's own public seam and
// edits no upstream file. Before a close reaches main, the upstream extension
// emits one offer on the extension event bus (FM_BRANCH_DISPATCH_EVENT in
// .pi/extensions/lib/fm-branch-dispatch.ts) and, when a listener accepts it,
// treats the close as handled by that listener: the pending record finishes
// and nothing is sent. The offer is made only after the successor watcher is
// restored and the --handling-delivered handshake has run, and never when
// restoration failed, so continuity and every watcher-failure alarm are
// untouched. This listener accepts an offer only when the wake is provably
// moot:
//   - the close is a row-backed wake kind: the watcher appends a queue row
//     before it prints one of these (check: rearm-resurface, signal:, stale:,
//     heartbeat). Wakes that carry their own durable payload without a queue
//     row (check: inactive-outcome, contribution checks, process-event
//     results) are never settled here; and
//   - state/.wake-queue exists, reads cleanly, and holds zero bytes. A
//     missing, unreadable, or non-empty queue is not proof, so the wake is
//     delivered exactly as upstream would.
// A queue holding any row, including rows reserved for the supervision
// branch, is left to the upstream path. An offer another listener already
// accepted is never touched.
//
// Loading is EXPLICIT, like fork/discord/fm-pi-reply-mirror.ts: the
// operator-owned launcher passes
//   pi -e "$home/fork/wake-guard/fm-pi-moot-wake.ts"
// A new file under the upstream-owned .pi/extensions/ is refused by
// fork/bin/fm-fork-hook-check --base, so auto-discovery is not available and
// this repository change alone activates nothing.
//
// Observability: each settled wake appends one line to state/.moot-wake.log,
// bounded and best-effort. A logging failure never changes the outcome, and
// the handler can never throw into the upstream offer.
import { appendFileSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Pinned to FM_BRANCH_DISPATCH_EVENT by fork/tests/fm-fork-moot-wake.test.sh
// so an upstream rename fails the fork suite instead of silently disabling
// this guard. Hard-coded rather than imported so a moved upstream file can
// never stop this extension from loading.
export const DISPATCH_EVENT = "fm-branch-supervision:dispatch";

const LOG_MAX_BYTES = 32768;
const LOG_KEEP_LINES = 200;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const defaultRoot = resolve(extensionDir, "../..");

// Same home resolution as the upstream watch extension, read per call so a
// test or a relocated home is honored without a reload.
export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
  const home = env.FM_HOME || env.FM_ROOT_OVERRIDE || defaultRoot;
  return env.FM_STATE_OVERRIDE || `${home}/state`;
}

const ROW_BACKED_WAKE = /^(?:check: rearm-resurface$|signal:|stale:|heartbeat(?:$|:))/;

export function rowBackedWake(message: string): boolean {
  return ROW_BACKED_WAKE.test(message);
}

// True only when the queue file is readable and holds zero bytes. A blank
// line is not empty: the main-eligible count in bin/fm-wake-lib.sh counts a
// malformed row as pending, so the same reading is the safe one here.
export function queueProvablyEmpty(queuePath: string): boolean {
  try {
    return readFileSync(queuePath, "utf8").length === 0;
  } catch {
    return false;
  }
}

export function wakeIsMoot(message: unknown, state: string): boolean {
  return typeof message === "string" && rowBackedWake(message) && queueProvablyEmpty(`${state}/.wake-queue`);
}

function recordSettled(state: string, message: string): void {
  const log = `${state}/.moot-wake.log`;
  try {
    const line = `${new Date().toISOString()}\tsettled\t${message.replace(/[\r\n\t]+/g, " ").slice(0, 512)}\n`;
    appendFileSync(log, line, { mode: 0o600 });
    if (statSync(log).size <= LOG_MAX_BYTES) return;
    const kept = readFileSync(log, "utf8").split("\n").filter(Boolean).slice(-LOG_KEEP_LINES).join("\n");
    const temporary = `${log}.tmp-${process.pid}`;
    writeFileSync(temporary, `${kept}\n`, { mode: 0o600 });
    renameSync(temporary, log);
  } catch {
    // Diagnostic only: observability never changes a wake's outcome.
  }
}

type DispatchOffer = {
  message?: unknown;
  accepted?: unknown;
  accept?: (settlement?: Promise<void>) => void;
};

export default function (pi: ExtensionAPI) {
  pi.events?.on?.(DISPATCH_EVENT, (data: unknown) => {
    try {
      const offer = data as DispatchOffer | null;
      if (!offer || typeof offer.accept !== "function" || offer.accepted === true) return;
      const state = stateDir();
      if (!wakeIsMoot(offer.message, state)) return;
      // Synchronous by contract: the upstream extension reads offer.accepted
      // the moment emit returns. The default settlement resolves at once.
      offer.accept();
      recordSettled(state, String(offer.message));
    } catch {
      // Never throw into the upstream offer: an unhandled doubt delivers.
    }
  });
}
