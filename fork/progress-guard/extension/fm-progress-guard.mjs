#!/usr/bin/env node
// Firstmate fork progress-stall adapter (process-event-adapter/1).
//
// Registers the fork-owned source that wakes Firstmate when a worker is busy
// but has stopped producing anything: a task whose record still exists, whose
// last status line carries the `working` verb, and whose status file, recorded
// worktree, and data directory have all been silent past the stall threshold.
// That wake closes the gap where a pane stays legitimately active while the
// run behind it goes nowhere - a loop over a worker's own inputs that no
// existing supervision alarmed on, because the pane was never idle.
//
// ADVISORY BY CONSTRUCTION. This package steers nothing, stops nothing,
// answers nothing, and never rewrites a task record. A wake only ever says
// "look at this worker"; every lifecycle, steering, and merge authority stays
// exactly where upstream put it.
//
// This file owns four things and nothing else:
//   config_ref     home:/absolute/firstmate-home. Both the task records and the
//                  fork's own state are resolved from it. A malformed or
//                  unusable reference is an error response, never a wake.
//   Scope gate     the only tasks offered to the seam are records of this home
//                  whose last status line carries the `working` verb, with a
//                  usable spawn_gen= incarnation, an attributable worktree, and
//                  no secondmate shape. A declared `paused:` wait, a terminal
//                  line, a task without a worktree to attribute evidence to,
//                  and a secondmate home never reach the seam, so firstmate is
//                  never woken about a worker that is correctly waiting or
//                  about work this source cannot observe.
//   Poll shape     re-scan inside one bounded long poll and return no-result
//                  before the host's own invocation bound, so the source keeps
//                  its ordinary long-poll cadence instead of hot-looping.
//   Result label   what a captured result of this source is called. Core
//                  captures this source's own host failure evidence under the
//                  same adapter, so only a body that is not that evidence is
//                  labelled stall-advisory; failure evidence is labelled
//                  stall-error and never presented as a stalled worker. The
//                  silent seam accepts exactly two contents: the host's own
//                  timed-out poll - its invoke timer counts machine-sleep
//                  time, so a sleep longer than the binding bound ends a
//                  healthy poll - and a progress-stall capture whose every
//                  advisory is already concluded by the time the capture is
//                  read, so a task that finishes between capture and read
//                  never resurrects a moot wake (see decideSilent below, and
//                  stallsConcluded in ./stall.mjs); every other result keeps
//                  its wake.
//
// The judgment - the stall predicate over the three evidence sources, the
// per-(task, latest status line) latch and its hourly cap, the wake body, and
// the self-conclusion of an already-captured advisory - lives entirely in
// ./stall.mjs, the documented seam. One result carries every task that poll
// finds stalled, never only the one that sorts first, and a poll that finds
// only latched or fresh tasks returns no-result.
//
// Adapter state. The latch marker is the only state this capability writes,
// and it belongs to that seam: <home>/state/<id>.progress-guard-latch, one per
// task, published by rename. This file only hands the seam what it needs - the
// poll's request id as the delivery witness and the one shared scan budget -
// and asks it to prune markers whose task record is gone on each poll, so no
// marker outlives the task it was written for.
//
// Diagnostics go to stderr as bounded one-line records. The host captures and
// discards extension stderr, so nothing here reaches a wake or an authority
// record; the fork tests read it to prove the scope gate.

import fs from "node:fs";
import path from "node:path";
import { decideWake, pruneStallMarkers, stallsConcluded, statusTail } from "./stall.mjs";

const EXTENSION_ID = "org.firstmate.fork.progress-guard";
const EXTENSION_VERSION = "0.1.0";
const MAX_INPUT_BYTES = 65536;
const MAX_OUTPUT_BYTES = 30000;
const MAX_RECORD_BYTES = 65536;
const ERROR_EVIDENCE_SCHEMA = "firstmate.process-event-extension-error.v1";
const DEFAULT_WAIT_MS = 50000;
const RESCAN_MS = 5000;
// One poll's shared evidence-scan budget; ./stall.mjs splits it across the
// entries the poll evaluates so one large worktree spends only its own share.
const SCAN_POLL_BUDGET_MS = 20000;
const CONFIG_REF_PREFIX = "home:";
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const META_NAME = /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.meta$/;
const INCARNATION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function log(line) {
  try {
    process.stderr.write(`${line}\n`);
  } catch {
    // A closed stderr must never change a verdict.
  }
}

class RequestError extends Error {
  constructor(code, retryable, message) {
    super(message);
    this.code = code;
    this.retryable = retryable;
  }
}

async function readRequest() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > MAX_INPUT_BYTES) throw new RequestError("invalid-request", false, "request is oversized");
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function respond(requestId, result) {
  process.stdout.write(`${JSON.stringify({
    schema: "firstmate.extension-response.v1", request_id: requestId, ok: true, result, error: null,
  })}\n`);
}

function respondError(requestId, code, retryable, diagnostic) {
  process.stdout.write(`${JSON.stringify({
    schema: "firstmate.extension-response.v1", request_id: requestId, ok: false, result: null,
    error: { code, retryable, diagnostic: String(diagnostic).slice(0, 200) },
  })}\n`);
}

function requireDirectory(target, what) {
  let info;
  try {
    info = fs.lstatSync(target);
  } catch {
    throw new RequestError("unavailable", true, `${what} is unavailable`);
  }
  if (!info.isDirectory() || info.isSymbolicLink()) {
    throw new RequestError("unavailable", true, `${what} is not a plain directory`);
  }
}

// homeDirs <config_ref> -> {home, stateDir, configDir}
//
// The reference is the registration's private, non-secret statement of which
// home this source belongs to. It is validated rather than trusted, and both
// directories it names must be plain directories of that home.
function homeDirs(reference) {
  if (typeof reference !== "string" || !reference.startsWith(CONFIG_REF_PREFIX)) {
    throw new RequestError("invalid-request", false, "config_ref must have the form home:/absolute/firstmate-home");
  }
  const home = reference.slice(CONFIG_REF_PREFIX.length);
  if (!path.isAbsolute(home) || home === "/" || path.normalize(home) !== home) {
    throw new RequestError("invalid-request", false, "config_ref home must be normalized and absolute");
  }
  requireDirectory(home, "the registered home");
  const stateDir = path.join(home, "state");
  requireDirectory(stateDir, "the registered home's state directory");
  return { home, stateDir, configDir: path.join(home, "config") };
}

// isQuietPollTimeout <content> -> boolean
//
// A host-produced source.poll timeout for THIS extension is an empty
// quiet-period poll: the runner captured the host's failure evidence instead
// of a stall advisory, so there is no stall content to wake anyone about. The
// check is exact - this schema, this code, this operation, and this
// extension's id - so a stall advisory, a non-timeout host failure, a timeout
// naming another operation or another extension, and every malformed capture
// still announce as before. This mirrors the fork PR-readiness adapter's
// absorb of the same host evidence.
function isQuietPollTimeout(content) {
  if (typeof content !== "string") return false;
  let record;
  try {
    record = JSON.parse(content);
  } catch {
    return false;
  }
  return record !== null && typeof record === "object"
    && record.schema === ERROR_EVIDENCE_SCHEMA
    && record.code === "timeout"
    && record.operation === "source.poll"
    && record.extension_id === EXTENSION_ID;
}

// decideSilent <input> -> boolean (never throws)
//
// The verdict the runner records instead of a wake for one captured result.
// true needs positive proof, so every doubt keeps the ordinary wake - a wrong
// silence could swallow a live advisory, while a wrong wake only costs a
// wasted look (see the silent contract in fork/progress-guard/README).
//
// Two contents are silent: the host's own timed-out poll (isQuietPollTimeout),
// and a progress-stall capture whose every advisory is already concluded when
// the capture is read - its task record gone, or its last status line a
// terminal done/failed declaration - proven only as ./stall.mjs's
// stallsConcluded proves it. The home that check needs comes from the
// config_ref the host attaches to captured-result operations (the fork's HK7
// block in bin/fm-extension.mjs); without a usable reference, or from a seam
// revision that does not provide the verdict (a delivery fixture's stub seam),
// this answers false, which is the pre-existing wake behaviour and never a
// suppression.
async function decideSilent(input) {
  const content = input?.content;
  if (isQuietPollTimeout(content)) return true;
  if (typeof content !== "string" || content === "") return false;
  let dirs;
  try {
    dirs = homeDirs(input?.config_ref);
  } catch {
    return false;
  }
  try {
    const seam = await import("./stall.mjs");
    if (typeof seam.stallsConcluded !== "function") return false;
    const ctx = { ...dirs, now: Date.now(), log };
    return seam.stallsConcluded(content, ctx) === true;
  } catch {
    return false;
  }
}

// An optional <home>/state/progress-guard/poll-wait-ms (100-50000) shortens
// the long poll, so tests and later slices never wait the full default.
function waitMs(dirs) {
  try {
    const value = Number(fs.readFileSync(path.join(dirs.stateDir, "progress-guard", "poll-wait-ms"), "utf8").trim());
    if (Number.isInteger(value) && value >= 100 && value <= DEFAULT_WAIT_MS) return value;
  } catch {
    // absent or unreadable: the default applies
  }
  return DEFAULT_WAIT_MS;
}

// readRecord <file> -> {fields}|null
//
// One task record, read as its own plain key=value lines. A duplicate key makes
// the record ambiguous, so it is refused rather than resolved in either
// direction: an unreadable record must never become a candidate.
function readRecord(file) {
  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    return null;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_RECORD_BYTES) return null;
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
  const fields = new Map();
  for (const line of text.split("\n")) {
    const value = line.replace(/\r$/, "");
    if (value === "") continue;
    const split = value.indexOf("=");
    if (split <= 0) return null;
    const key = value.slice(0, split);
    if (!/^[a-z][a-z0-9_]*$/.test(key)) return null;
    if (fields.has(key)) return null;
    fields.set(key, value.slice(split + 1));
  }
  return fields;
}

// verbReason <verb> -> log-safe reason token
//
// A last line that is continuation prose parses as itself, spaces and all;
// the log keeps only its first token so every `skipped <id> <reason>` line
// stays two tokens after the id.
function verbReason(verb) {
  if (verb === "") return "verb-none";
  const token = verb.split(/\s+/)[0].replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 32);
  return token === "" ? "verb-none" : `verb-${token}`;
}

// gate <dirs> <id> <fields> -> {entry}|{reason}
//
// The scope gate. Every refusal is silent and named, so a record outside this
// source's observation - a secondmate, a worker that is not declaring
// `working`, a record without a usable incarnation, or a task whose worktree
// cannot be attributed - can never be woken about even when a later seam is
// installed. statusTail is the seam's own bounded read of the last status
// line, so the gate and the delivery re-check classify the verb through one
// implementation.
function gate(dirs, id, fields) {
  const kind = fields.get("kind") ?? "";
  const mode = fields.get("mode") ?? "";
  if (kind === "secondmate" || mode === "secondmate") return { reason: "secondmate" };
  const statusFile = path.join(dirs.stateDir, `${id}.status`);
  const tail = statusTail(statusFile);
  if (tail === null) return { reason: "status-unreadable" };
  if (tail.verb !== "working") return { reason: verbReason(tail.verb) };
  const incarnation = fields.get("spawn_gen") ?? "";
  if (!INCARNATION.test(incarnation)) return { reason: "incarnation-unusable" };
  // Attribution: without a recorded, existing worktree this source cannot say
  // where the worker's evidence would be, and a guard that guesses cries wolf.
  const worktree = fields.get("worktree") ?? "";
  if (worktree === "" || !path.isAbsolute(worktree)) return { reason: "worktree-unattributed" };
  let info;
  try {
    info = fs.statSync(worktree);
  } catch {
    return { reason: "worktree-gone" };
  }
  if (!info.isDirectory()) return { reason: "worktree-gone" };
  try {
    fs.lstatSync(path.join(worktree, ".fm-secondmate-home"));
    return { reason: "secondmate-home" };
  } catch {
    // no secondmate-home marker: an ordinary worktree
  }
  return {
    entry: {
      id,
      meta: path.join(dirs.stateDir, `${id}.meta`),
      incarnation,
      statusFile,
      statusLine: tail.line,
      statusHash: tail.hash,
      worktree,
      dataDir: path.join(dirs.home, "data", id),
    },
  };
}

// scanHome <dirs> -> {entries, refused}
//
// Every task record in this home, sorted by id so the scan order is stable.
function scanHome(dirs) {
  const entries = [];
  const refused = [];
  let names;
  try {
    names = fs.readdirSync(dirs.stateDir).sort();
  } catch {
    throw new RequestError("unavailable", true, "the registered home's state directory is unreadable");
  }
  for (const name of names) {
    const match = META_NAME.exec(name);
    if (!match) continue;
    const id = match[1];
    if (!TASK_ID.test(id)) {
      refused.push({ id, reason: "task-id-invalid" });
      continue;
    }
    const fields = readRecord(path.join(dirs.stateDir, name));
    if (!fields) {
      refused.push({ id, reason: "record-unreadable" });
      continue;
    }
    const verdict = gate(dirs, id, fields);
    if (verdict.entry) entries.push(verdict.entry);
    else refused.push({ id, reason: verdict.reason });
  }
  return { entries, refused };
}

// classifyResult <content> -> "stall-advisory" | "stall-error"
//
// Core captures this source's host failure evidence under the same adapter, so
// only a body that is not that evidence may be labelled stall advice.
function classifyResult(content) {
  if (typeof content !== "string") return "stall-error";
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch {
    return "stall-advisory";
  }
  const failure = parsed !== null && typeof parsed === "object" && parsed.schema === ERROR_EVIDENCE_SCHEMA;
  return failure ? "stall-error" : "stall-advisory";
}

async function poll(request) {
  const dirs = homeDirs(request.input?.config_ref);
  const deadline = Date.now() + waitMs(dirs);
  // One ctx for the whole poll: the seam prices its evidence walks against the
  // one shared scan budget and receives the host's own request id, which is the
  // delivery witness its latch compares.
  const ctx = {
    ...dirs,
    now: Date.now(),
    requestId: request.request_id,
    log,
    scanBudgetMs: SCAN_POLL_BUDGET_MS,
  };
  let announced = false;
  // One evaluation per task per latest status line per invocation, so a status
  // change inside the same poll is a new question while an unchanged one is not
  // re-walked on every rescan.
  const evaluated = new Set();
  for (;;) {
    const scan = scanHome(dirs);
    if (!announced) {
      for (const entry of scan.entries) log(`progress-guard: eligible ${entry.id}`);
      for (const refused of scan.refused) log(`progress-guard: skipped ${refused.id} ${refused.reason}`);
      log(`progress-guard: poll ${scan.entries.length} eligible, ${scan.refused.length} refused`);
      // Fork-owned cleanup on the ordinary poll: a latch marker whose task
      // record is gone is dropped, so no marker outlives the task.
      const pruned = pruneStallMarkers(ctx);
      if (pruned > 0) log(`progress-guard: marker-pruned ${pruned}`);
      announced = true;
    }
    const pending = scan.entries.filter((entry) => !evaluated.has(`${entry.id}\u0000${entry.statusHash}`));
    const advisories = [];
    let bytes = 0;
    for (const entry of pending) {
      evaluated.add(`${entry.id}\u0000${entry.statusHash}`);
      const decided = decideWake(entry, ctx);
      if (decided === null || decided === undefined) continue;
      const advisory = decided && typeof decided.advisory === "string" ? decided.advisory : "";
      if (advisory.trim() === "") {
        log(`progress-guard: seam-invalid ${entry.id} no advisory body`);
        continue;
      }
      const body = advisory.endsWith("\n") ? advisory : `${advisory}\n`;
      const size = Buffer.byteLength(body);
      if (size > MAX_OUTPUT_BYTES) {
        log(`progress-guard: seam-invalid ${entry.id} advisory body is oversized`);
        continue;
      }
      if (bytes + size > MAX_OUTPUT_BYTES) {
        log(`progress-guard: seam-invalid ${entry.id} result body is full`);
        continue;
      }
      bytes += size;
      advisories.push(body);
      log(`progress-guard: stalled ${entry.id}`);
    }
    if (advisories.length > 0) return { status: "result", output: advisories.join("") };
    const left = deadline - Date.now();
    if (left <= 0) return { status: "no-result", output: "" };
    await sleep(Math.min(RESCAN_MS, left));
  }
}

const verb = process.argv[2] || "";
const request = await readRequest();
if (verb === "handshake") {
  process.stdout.write(`${JSON.stringify({
    schema: "firstmate.extension-handshake-response.v1",
    request_id: request.request_id,
    extension_id: EXTENSION_ID,
    extension_version: EXTENSION_VERSION,
    host_protocol: 1,
    capability: "process-event-adapter",
    capability_version: 1,
    adapter_names: request.capability.adapter_names,
  })}\n`);
} else if (verb === "invoke" && request.operation === "source.poll") {
  try {
    respond(request.request_id, await poll(request));
  } catch (error) {
    if (error instanceof RequestError) {
      respondError(request.request_id, error.code, error.retryable, error.message);
    } else {
      respondError(request.request_id, "unavailable", true, "the progress-stall source could not be read");
      log(`progress-guard: poll failed ${String(error && error.message || error).slice(0, 200)}`);
    }
  }
} else if (verb === "invoke" && request.operation === "result.classify") {
  respond(request.request_id, { classification: classifyResult(request.input?.content) });
} else if (verb === "invoke" && request.operation === "result.terminal") {
  // The source never concludes itself: it keeps listening for the next stall,
  // and a wake is acknowledged with `fm-procevent.sh handled`.
  respond(request.request_id, { value: false });
} else if (verb === "invoke" && request.operation === "result.silent") {
  // A stall wake has no channel of its own: the runner publishes the ordinary
  // wake for that result sequence and re-announces it until Firstmate
  // acknowledges that sequence. A later poll is a new sequence. Exactly two
  // contents record handled without a wake: the host's own timeout evidence
  // for this source - a poll the host stopped waiting for carried no stall
  // content, so the next launch re-runs it - and a progress-stall capture
  // whose task is already concluded by the time the capture is read, so a
  // task torn down between capture and read never resurrects a moot advisory
  // (see decideSilent above).
  respond(request.request_id, { value: await decideSilent(request.input) });
} else {
  throw new Error("unsupported extension verb or operation");
}
