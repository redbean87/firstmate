#!/usr/bin/env node
// Firstmate fork PR readiness adapter (process-event-adapter/1).
//
// Registers the fork-owned source that will wake Firstmate when a pull request
// it may merge on its own authority has finished: every required check reported
// green at the recorded head. This slice ships the adapter, its scope gate, and
// its registration; the readiness predicate and the wake it emits land at the
// seam in a later slice, so the registered source listens and stays silent. It
// is a fork-owned external package (docs/extension-bindings.md), so it edits no
// upstream file and plugs in through the same extension seam the fork's Discord
// bridge uses.
//
// ADVISORY BY CONSTRUCTION. This package merges nothing, arms nothing, records
// no approval or merge authority, and never rewrites a task record. A wake only
// ever tells Firstmate to look; bin/fm-pr-merge.sh remains the only thing that
// can merge and re-validates every required check at merge time. A divergence
// between this adapter and that gate can cost a wasted wake or a missed one,
// never a bad merge.
//
// This file owns four things and nothing else:
//   config_ref     home:/absolute/firstmate-home. Both the task records and the
//                  fork's own state are resolved from it. A malformed or
//                  unusable reference is an error response, never a wake.
//   Scope gate     the only tasks offered for evaluation are armed GitHub pull
//                  requests in this home whose record is mode=no-mistakes or
//                  mode=direct-PR, yolo=on, and not a secondmate. GitLab,
//                  Forgejo, Gerrit, local-only, yolo=off, and secondmate records
//                  never reach the readiness seam, so firstmate is never woken
//                  about work it may not merge itself.
//   Poll shape     re-scan inside one bounded long poll and return no-result
//                  before the host's own invocation bound, so the source keeps
//                  its ordinary long-poll cadence instead of hot-looping.
//   Result label   what a captured result of this source is called. Core
//                  captures this source's own host failure evidence under the
//                  same adapter, so only a body that is not that evidence is
//                  labelled pr-ready-advisory; failure evidence is labelled
//                  pr-ready-error and never presented as a green pull request.
//
// The judgment - the readiness predicate, the one-shot per-head latch, and the
// wake body - lives entirely in ./readiness.mjs, the documented seam later
// slices fill in. It returns silence today, so with no seam installed this
// adapter is registered, listening, and silent.
//
// Diagnostics go to stderr as bounded one-line records. The host captures and
// discards extension stderr, so nothing here reaches a wake or an authority
// record; the fork tests read it to prove the scope gate.

import fs from "node:fs";
import path from "node:path";
import { decideWake } from "./readiness.mjs";

const EXTENSION_ID = "org.firstmate.fork.pr-green";
const EXTENSION_VERSION = "0.1.0";
const MAX_INPUT_BYTES = 65536;
const MAX_OUTPUT_BYTES = 30000;
const MAX_RECORD_BYTES = 65536;
const ERROR_EVIDENCE_SCHEMA = "firstmate.process-event-extension-error.v1";
const DEFAULT_WAIT_MS = 50000;
const RESCAN_MS = 5000;
const CONFIG_REF_PREFIX = "home:";
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const META_NAME = /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.meta$/;
const HEAD = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const HOST = /^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$/;
// The pull request URL shape upstream accepts for GitHub, re-checked here so a
// record that names another provider never becomes a readiness candidate.
const PULL_URL = /^https:\/\/([a-z0-9.-]{1,253})\/([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])\/([A-Za-z0-9._-]{1,100})\/pull\/([1-9][0-9]*)$/;
// The delivery modes this fork may merge on its own authority.
const READINESS_MODES = new Set(["no-mistakes", "direct-PR"]);

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

// An optional <home>/state/pr-green/poll-wait-ms (100-50000) shortens the long
// poll, so tests and later slices never wait the full default.
function waitMs(dirs) {
  try {
    const value = Number(fs.readFileSync(path.join(dirs.stateDir, "pr-green", "poll-wait-ms"), "utf8").trim());
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

// githubHostAllowed <dirs> <host>
//
// github.com is the shape's default. Any other host must be listed in this
// home's config/github-hosts, exactly as upstream's own GitHub host rule
// requires, so a look-alike host never becomes a candidate.
function githubHostAllowed(dirs, host) {
  if (!HOST.test(host)) return false;
  if (host.includes("..")) return false;
  if (host === "github.com") return true;
  const file = path.join(dirs.configDir, "github-hosts");
  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    return false;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_RECORD_BYTES) return false;
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    return false;
  }
  return text.split("\n").some((line) => line.replace(/\r$/, "") === host);
}

function armedSidecar(dirs, id) {
  const sidecar = path.join(dirs.stateDir, `${id}.check.sh`);
  try {
    const info = fs.lstatSync(sidecar);
    return info.isFile() && !info.isSymbolicLink();
  } catch {
    return false;
  }
}

// gate <dirs> <id> <fields> -> {entry}|{reason}
//
// The scope gate. Every refusal is silent and named, so a record outside this
// fork's authority can never be woken about even when a later readiness seam
// is installed.
function gate(dirs, id, fields) {
  const kind = fields.get("kind") ?? "";
  const mode = fields.get("mode") ?? "";
  const yolo = fields.get("yolo") ?? "";
  if (kind === "secondmate" || mode === "secondmate") return { reason: "secondmate" };
  if (!READINESS_MODES.has(mode)) return { reason: mode === "" ? "no-mode" : `mode-${mode}` };
  if (yolo !== "on") return { reason: "yolo-off" };
  const raw = fields.get("pr") ?? "";
  if (raw === "") return { reason: "no-pr" };
  const match = PULL_URL.exec(raw);
  if (!match) return { reason: "unsupported-provider" };
  const host = match[1];
  if (!githubHostAllowed(dirs, host)) return { reason: "host-not-listed" };
  if (match[2].includes("--") || match[3] === "." || match[3] === "..") return { reason: "pull-identity-invalid" };
  const head = fields.get("pr_head") ?? "";
  if (head === "") return { reason: "no-pr-head" };
  if (!HEAD.test(head)) return { reason: "pr-head-invalid" };
  if (!armedSidecar(dirs, id)) return { reason: "not-armed" };
  return {
    entry: {
      id,
      mode,
      yolo,
      kind,
      pr: raw,
      host,
      owner: match[2],
      repo: match[3],
      number: match[4],
      head,
      meta: path.join(dirs.stateDir, `${id}.meta`),
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

// classifyResult <content> -> "pr-ready-advisory" | "pr-ready-error"
//
// Core captures this source's host failure evidence under the same adapter, so
// only a body that is not that evidence may be labelled readiness advice.
function classifyResult(content) {
  if (typeof content !== "string") return "pr-ready-error";
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch {
    return "pr-ready-advisory";
  }
  const failure = parsed !== null && typeof parsed === "object" && parsed.schema === ERROR_EVIDENCE_SCHEMA;
  return failure ? "pr-ready-error" : "pr-ready-advisory";
}

async function poll(request) {
  const dirs = homeDirs(request.input?.config_ref);
  const deadline = Date.now() + waitMs(dirs);
  let announced = false;
  for (;;) {
    const scan = scanHome(dirs);
    if (!announced) {
      for (const entry of scan.entries) log(`pr-green: eligible ${entry.id}`);
      for (const refused of scan.refused) log(`pr-green: skipped ${refused.id} ${refused.reason}`);
      log(`pr-green: poll ${scan.entries.length} eligible, ${scan.refused.length} refused`);
      announced = true;
    }
    const ctx = { ...dirs, now: Date.now(), log };
    for (const entry of scan.entries) {
      const decided = decideWake(entry, ctx);
      if (decided === null || decided === undefined) continue;
      const advisory = decided && typeof decided.advisory === "string" ? decided.advisory : "";
      if (advisory.trim() === "") {
        log(`pr-green: seam-invalid ${entry.id} no advisory body`);
        continue;
      }
      if (Buffer.byteLength(advisory) > MAX_OUTPUT_BYTES) {
        log(`pr-green: seam-invalid ${entry.id} advisory body is oversized`);
        continue;
      }
      log(`pr-green: ready ${entry.id}`);
      return { status: "result", output: advisory.endsWith("\n") ? advisory : `${advisory}\n` };
    }
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
      respondError(request.request_id, "unavailable", true, "the readiness source could not be read");
      log(`pr-green: poll failed ${String(error && error.message || error).slice(0, 200)}`);
    }
  }
} else if (verb === "invoke" && request.operation === "result.classify") {
  respond(request.request_id, { classification: classifyResult(request.input?.content) });
} else if (verb === "invoke" && request.operation === "result.terminal") {
  // The source never concludes itself: it keeps listening for the next pull
  // request, and a wake is acknowledged with `fm-procevent.sh handled`.
  respond(request.request_id, { value: false });
} else if (verb === "invoke" && request.operation === "result.silent") {
  // A readiness wake is re-announced until Firstmate acknowledges it.
  respond(request.request_id, { value: false });
} else {
  throw new Error("unsupported extension verb or operation");
}
