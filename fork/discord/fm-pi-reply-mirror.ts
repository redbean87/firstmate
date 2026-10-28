// Firstmate fork: Pi settled-reply spool writer for the Discord bridge
// (fork/discord/README "Pi primary replies").
//
// When the primary Firstmate session runs on Pi, MAIN's chat replies must
// reach Discord exactly as they do on Claude Code (captain decision
// 2026-10-28: parity, no filtering - every settled MAIN reply, including
// replies to operational and background wakes). This extension records each
// settled reply as one spool event; the fork bridge polls the spool
// unconditionally (poll_pi_spool), so no DISCORD_REPLIES_SOURCE switch and no
// upstream file change is involved. It never writes state/.host-mirror.jsonl,
// never captures prompts, and adds no new event schema.
//
// Loading is EXPLICIT: the operator-owned ~/.local/bin/fm launcher passes
//   pi -e "$home/fork/discord/fm-pi-reply-mirror.ts"
// (docs/cli.md: explicit -e paths always load). Nothing here relies on the
// accidental ~/.pi/agent/extensions auto-discovery, and no file under the
// upstream-owned tracked .pi/extensions/ is added or changed.
//
// Interception is the public `agent_settled` event: the only run boundary
// after which no retry, compaction, or queued continuation remains
// (Pi docs/extensions.md; .pi/extensions/fm-branch-supervision.ts treats it
// the same way). The settled FINAL reply is the last assistant transcript
// entry carrying nonblank text and no toolCall part - intermediate streaming
// output and tool-loop turns fall behind it, and an aborted run is skipped
// outright.
//
// Gates, source-verified against the Claude reply hook
// (fork/discord/fm-discord-reply-hook.sh) and upstream's own in-process
// precedent (.pi/extensions/fm-branch-supervision.ts lockOwnershipSync):
//   - inert unless the bridge created state/discord-bridge/pi-replies/
//     (so a home without the fork bridge never accumulates spool files);
//   - a genuine primary checkout (fm_primary_scope_matches in
//     bin/fm-primary-scope-lib.sh: not a linked worktree, AGENTS.md and bin/
//     present, or a valid secondmate-home marker) whose state dir exists;
//   - the fleet session lock (state/.lock) names a pid in THIS process's
//     ancestry, re-evaluated at every settle, never latched.
// The hook's foreign-host payload check has no Pi analogue: these events come
// from the in-process Pi runtime, not from a delivered hook payload.
//
// Continuation semantics follow the hook where the mapping is sound: the hook
// marks a re-fired Stop for the same prompt; here a settle with NO new
// turn-starting entry since the previous settle is marked "(continued)". A
// turn starts with any entry that is neither the assistant's own message nor
// a tool result: a captain prompt, an operational injection, and also the
// custom_message entry Pi uses for background deliveries (which Claude
// receives as a user prompt), so both harnesses treat a wake reply the same
// way. The distinction lives in the exported settleReply helper so tests pin
// it. Remaining uncertainty (documented, non-blocking): whether a compaction
// summary can ever present as an assistant text entry.
//
// State is instance-scoped and re-derived per settle; session_start clears
// it, so /new, /resume, /fork, or reload never reuse stale turn state.
// The handler always succeeds silently: like the Claude hook it can never
// steer, block, or break a turn.
import { spawnSync } from "node:child_process";
import { lstatSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { AgentSettledEvent, ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const defaultRoot = resolve(extensionDir, "../..");

const EVENT_SCHEMA = "firstmate.discord-reply-event.v1";
const SPOOL_DIR_NAME = "pi-replies";
const TEXT_MAX = 100000;
const LOCK_ANCESTRY_DEPTH = 8;

// Same home resolution as fork/discord/fm-discord-reply-hook.sh, so the
// tests point the extension at a fixture home exactly like the hook.
function homeRoot(): string {
  return process.env.FM_ROOT_OVERRIDE || defaultRoot;
}

function homeDir(): string {
  return process.env.FM_HOME || homeRoot();
}

function stateDir(): string {
  return process.env.FM_STATE_OVERRIDE || join(homeDir(), "state");
}

function spoolDir(): string {
  return join(stateDir(), "discord-bridge", SPOOL_DIR_NAME);
}

type ContentPart = { type?: string; text?: string };
type TranscriptMessage = { role?: string; content?: unknown };
type TranscriptEntry = { type?: string; message?: TranscriptMessage };

// Join only text parts, the same extraction as the branch extension's
// textOfContent (.pi/extensions/fm-branch-supervision.ts).
export function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const p = part as ContentPart;
        return p && p.type === "text" && typeof p.text === "string" ? p.text : "";
      })
      .filter((piece) => piece.length > 0)
      .join("\n");
  }
  return "";
}

// The settled final reply: the LAST assistant message after sinceIndex that
// carries nonblank text and no toolCall part (a message with a call is a
// loop step, never a final reply - the same rule the branch's message_end
// handler applies). Role "custom" branch-processing entries can never match.
export function lastReplyFrom(
  entries: readonly unknown[],
  sinceIndex: number,
): { index: number; text: string } | null {
  for (let index = entries.length - 1; index > sinceIndex; index -= 1) {
    const entry = entries[index] as TranscriptEntry | undefined;
    if (entry?.type !== "message") continue;
    const message = entry.message;
    if (message?.role !== "assistant") continue;
    const parts = Array.isArray(message.content) ? message.content : [];
    if (parts.some((part) => (part as ContentPart)?.type === "toolCall")) continue;
    const text = textOfContent(message.content);
    if (!text.trim()) continue;
    return { index, text };
  }
  return null;
}

// Whether a new turn started between the previous settle and this reply: any
// entry that is neither the assistant's own message nor a tool result, so a
// user prompt, a custom_message background delivery, or any other transcript
// event all count. A re-fired settle of the SAME turn adds only assistant and
// toolResult entries, which is the hook's stop_hook_active case.
export function newTurnSince(
  entries: readonly unknown[],
  sinceIndex: number,
  beforeIndex: number,
): boolean {
  for (let index = sinceIndex + 1; index < beforeIndex; index += 1) {
    const entry = entries[index] as TranscriptEntry | undefined;
    const role = entry?.type === "message" ? entry.message?.role : undefined;
    if (role === "assistant" || role === "toolResult") continue;
    return true;
  }
  return false;
}

// One settle's decision, pure for testability. previousSettled is false before
// the generation's first settle, so a first reply is never a continuation.
export function settleReply(
  entries: readonly unknown[],
  sinceIndex: number,
  previousSettled: boolean,
): { index: number; text: string; continuation: boolean } | null {
  const reply = lastReplyFrom(entries, sinceIndex);
  if (!reply) return null;
  return {
    index: reply.index,
    text: reply.text,
    continuation: previousSettled && !newTurnSince(entries, sinceIndex, reply.index),
  };
}

function isFile(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

// Follows symlinks, matching upstream's test -d / [ -d ] checks (the
// fixture primary checkout links bin/ rather than copying it).
function isDirectory(path: string): boolean {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

// A valid secondmate-home marker force-includes that home, exactly like
// fm_root_is_secondmate_home (bin/fm-primary-scope-lib.sh): a symlink, an
// empty id, or an unsafe character refuses the marker instead of widening.
export function secondmateHomeMarkerValid(root: string): boolean {
  const marker = join(root, ".fm-secondmate-home");
  let id: string;
  try {
    if (lstatSync(marker).isSymbolicLink()) return false;
    id = readFileSync(marker, "utf8").split("\n", 1)[0].replace(/\s/g, "");
  } catch {
    return false;
  }
  return id.length > 0 && !/[^A-Za-z0-9._-]/.test(id);
}

function gitRevParse(root: string, flag: string): string | null {
  const result = spawnSync("git", ["-C", root, "rev-parse", flag], { encoding: "utf8" });
  if (result.status !== 0) return null;
  const out = (result.stdout || "").trim();
  return out.length > 0 ? out : null;
}

// fm_primary_root_matches in bin/fm-primary-scope-lib.sh, source-verified: a
// linked task worktree (git-dir differs from git-common-dir) is never
// primary, a valid secondmate marker force-includes its home, and every
// primary root still needs AGENTS.md and bin/.
export function primaryRootMatches(root: string): boolean {
  if (!secondmateHomeMarkerValid(root)) {
    const gitDir = gitRevParse(root, "--git-dir");
    const commonDir = gitRevParse(root, "--git-common-dir");
    if (gitDir === null || commonDir === null) return false;
    if (resolve(root, gitDir) !== resolve(root, commonDir)) return false;
  }
  return isFile(join(root, "AGENTS.md")) && isDirectory(join(root, "bin"));
}

function lockHolderPid(lockPid: string): string {
  const tagged = process.platform === "win32" ? /^win:([0-9]+)$/.exec(lockPid) : null;
  const pid = tagged ? tagged[1] : lockPid;
  return /^[0-9]+$/.test(pid) && pid !== "1" ? pid : "";
}

function parentPidSync(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return (result.stdout || "").trim();
}

// The same ownership walk as the branch and watcher extensions: state/.lock
// names the harness pid, and this process owns it when that pid appears in
// its own ancestry. The ancestry is walked in full at every settle and never
// cached, because it is an ownership AUTHORITY, not a hint.
export function lockOwnedBySelf(state: string): boolean {
  let lockPid: string;
  try {
    lockPid = readFileSync(join(state, ".lock"), "utf8").trim();
  } catch {
    return false;
  }
  const holderPid = lockHolderPid(lockPid);
  if (!holderPid) return false;
  let pid = String(process.pid);
  for (let i = 0; i < LOCK_ANCESTRY_DEPTH; i += 1) {
    if (pid === holderPid) return true;
    pid = parentPidSync(pid);
    if (!pid || pid === "1") break;
  }
  return false;
}

function capReplyText(text: string): string {
  if (text.length <= TEXT_MAX) return text;
  const headLength = Math.ceil(TEXT_MAX / 2);
  const tailLength = TEXT_MAX - headLength;
  const omitted = text.length - TEXT_MAX;
  return `${text.slice(0, headLength)}\n\n[Shortened by the Pi reply extension: ${omitted} characters not shown.]${text.slice(-tailLength)}`;
}

// One event per settled reply, in the hook spool's exact schema and naming
// (NNNNNNNNNNNN.json beside a monotonic .seq), written by tmp+rename so a
// crash can never leave a torn event. The gate order mirrors the hook:
// spool present, primary scope, state dir, lock ownership - a failure at any
// point writes nothing.
function recordReply(text: string, sessionId: string, continuation: boolean): void {
  const spool = spoolDir();
  let spoolStat;
  try {
    spoolStat = lstatSync(spool);
  } catch {
    return;
  }
  if (!spoolStat.isDirectory()) return;
  const state = stateDir();
  const root = homeRoot();
  if (!primaryRootMatches(root) || !isDirectory(state)) return;
  if (!lockOwnedBySelf(state)) return;
  const capped = capReplyText(text);
  let seq: number;
  try {
    const stored = readFileSync(join(spool, ".seq"), "utf8").trim();
    seq = /^\d+$/.test(stored) ? Number(stored) + 1 : 1;
  } catch {
    seq = 1;
  }
  const tmp = join(spool, `.tmp-${process.pid}`);
  const final = join(spool, `${String(seq).padStart(12, "0")}.json`);
  const event = {
    schema: EVENT_SCHEMA,
    seq,
    captured_at: Math.floor(Date.now() / 1000),
    session_id: sessionId,
    prompt_id: "",
    continuation,
    // Like the Claude hook, text_length is the ORIGINAL length, so a cap
    // note cannot be mistaken for the reply's true size.
    text_length: text.length,
    text: capped,
  };
  try {
    writeFileSync(tmp, JSON.stringify(event), { mode: 0o600 });
    writeFileSync(join(spool, ".seq"), String(seq), { mode: 0o600 });
    renameSync(tmp, final);
  } catch {
    rmSync(tmp, { force: true });
  }
}

export default function (pi: ExtensionAPI) {
  // Instance-scoped per settle; session_start re-derives the recorded
  // boundary from the session the new generation actually has, so a
  // replaced session (/new, /resume, /fork, reload) never reuses the
  // previous generation's turn state: a restored /resume transcript treats
  // every already-present entry as recorded (no replay of old replies after
  // a restart), and a fresh /new transcript starts empty. The settle flag is
  // cleared, not restored, because no settle has yet happened in this
  // generation: a prompt persisted before a reply existed must not make the
  // first reply a continuation.
  let lastRecordedIndex = -1;
  let settledInGeneration = false;

  pi.on?.("session_start", (_event, ctx) => {
    const entries = ctx?.sessionManager?.getEntries() ?? [];
    lastRecordedIndex = entries.length - 1;
    settledInGeneration = false;
  });

  pi.on?.("agent_settled", (event: AgentSettledEvent, ctx: ExtensionContext) => {
    try {
      if (event.aborted) return;
      const sessionManager = ctx?.sessionManager;
      if (!sessionManager) return;
      const entries = sessionManager.getEntries();
      const decision = settleReply(entries, lastRecordedIndex, settledInGeneration);
      if (!decision) return;
      recordReply(
        decision.text,
        basename(sessionManager.getSessionFile() ?? ""),
        decision.continuation,
      );
      lastRecordedIndex = decision.index;
      settledInGeneration = true;
    } catch {
      // Never surface an error into the session: a lost Discord reply is
      // degraded delivery, a broken turn is not.
    }
  });
}
