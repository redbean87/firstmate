// The progress-stall seam of the fork progress-guard adapter
// (process-event-adapter/1).
//
// This module is the WHOLE of the adapter's judgment: the stall predicate over
// three local evidence sources, the per-(task, latest status line) latch with
// its one-wake-per-task-per-hour cap, the wake body, and the self-conclusion of
// an already-captured advisory. No other part of the package can acquire an
// opinion about whether a worker is stuck.
//
// decideWake(entry, ctx)
//   entry  one task that already passed the adapter's eligibility gate:
//          {id, meta, incarnation, statusFile, statusLine, statusHash,
//          worktree, dataDir}. The gate already refused secondmate records,
//          tasks whose last status line does not carry the `working` verb,
//          records without a usable spawn_gen= incarnation, and tasks whose
//          worktree cannot be attributed, so a change to this module cannot
//          widen which tasks can wake firstmate.
//   ctx    {home, stateDir, configDir, now, requestId, log, scanBudgetMs}:
//          absolute paths resolved from the registration's config_ref, the
//          poll's clock in epoch milliseconds, the host's own request id for
//          this poll (see THE LATCH), a stderr logger the host captures and
//          discards, and the one scan budget this poll shares across the
//          entries it evaluates.
//   returns null, which is silence, or {advisory: "<wake body>"}.
//
// stallsConcluded(content, ctx)
//   the self-conclusion verdict behind the adapter's result.silent for a
//   progress-stall capture: true only when every advisory already captured is
//   concluded by the time the capture is read - its task record gone, or its
//   last status line a terminal done/failed declaration - so the runner records
//   the capture handled instead of presenting a moot wake. It reads only,
//   proves a conclusion positively, and answers false for every doubt; the
//   comment at its definition owns the full contract.
//
// THE STALL PATTERN. A task that passed the gate is a candidate for a stall
// wake only while three things have all been silent for the threshold window:
//   status     no new line in state/<id>.status (the file's own mtime),
//   worktree   no new or modified file or directory under the recorded
//              worktree, through a git status-free mtime walk that never opens
//              .git and prunes the same generated trees bin/fm-classify-lib.sh
//              prunes, bounded to six levels of depth and to its share of one
//              wall-clock budget, and
//   data       no new file or directory under data/<id>/ (absent is fine).
// The newest mtime across those sources is the task's newest evidence; when
// now minus that newest evidence reaches the threshold, the task is stalled.
// Directories count as evidence because a file created and deleted between two
// polls still moves its parent directory's mtime. The threshold is
// state/progress-guard/stall-threshold-secs, 25 minutes by default, and is the
// one place a home tunes the stall window.
//
// bin/fm-classify-lib.sh owns the status verb vocabulary, and this seam reads
// the LAST status line's verb with a re-expression of its status_line_verb
// (text before the first colon, cut at the first bracket, trimmed, correlation
// tokens dropped). Only an exact `working` verb is ever a candidate, so a
// declared `paused:` wait with a resume condition, a `blocked:` line, a
// terminal line, and continuation prose that does not itself parse as `working`
// are all silence. The re-expression is strictly conservative against the
// library's own last-event read: the library may skip a trailing line this
// seam treats as the last line (a missed wake, the safe direction), never the
// reverse, because a trailing line that parses as `working` is always an event
// for the library too. Silence is the answer to every other doubt: an
// unreadable status file, an unattributable worktree, a walk that fails or
// runs out of its budget, a posture that changes between gate and delivery, or
// any throw answers null, never a wake.
//
// THE LATCH. One marker per task, <home>/state/<id>.progress-guard-latch,
// written as one fixed-arity line record and published by temp-file rename
// (0600, same directory, fsynced), in the shape upstream's own markers use.
// It remembers what has already been announced:
//   marker    version line fm-fork-progress-guard-v1, then task id, the task
//             record's spawn_gen= incarnation, the sha256 of the latest status
//             line the wake was about, the host request id that produced the
//             wake, and the epoch second it was published.
//   latches   a marker suppresses when its incarnation and status-line hash
//             equal the ones the gate just read: the same task, worker, and
//             latest status line is the same stall, so it wakes once. A new
//             status line or a new spawn_gen is a new question and re-arms.
//   caps      a re-armed question is still suppressed while
//             now - marker epoch is under state/progress-guard/
//             min-wake-interval-secs (3600 by default), so no task ever gets
//             more than one wake per hour no matter how the threshold, a
//             changed status line, or a relaunch interact.
//   repeat    two things make the latch fail toward one possible duplicate
//             wake and never toward suppression. (1) A marker write that fails,
//             is interrupted, or is unreadable afterwards leaves no valid
//             marker, so the next poll simply answers again. (2) The marker
//             records the HOST request id that produced its wake: core derives
//             that id from the next uncaptured result sequence, so it is
//             unchanged while a wake has not been captured and changes once it
//             has. A retry after a crash between answering and capture arrives
//             with the SAME id as the marker and is answered again instead of
//             being suppressed, while an ordinary later poll arrives with a
//             different id and is silent.
// The marker is written before the wake is returned, never after: a crash in
// between is repaired by the request-id rule above, whereas writing after
// would leave a delivered wake unrecorded and repeat it on every poll. A
// marker whose identity no longer matches still serves the hourly cap, because
// the cap is the hard bound; pruning drops a marker only when the task record
// itself is gone or the marker file is malformed, so a relaunch or a changed
// status line never resets the hour.
//
// Nothing in this module may steer a worker, answer a finding, write a task
// record, or change any lifecycle or merge authority; the latch marker is the
// only state this capability is ever meant to write, and it records a wake,
// not a verdict about the worker.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// Upstream's per-spawn incarnation token (bin/fm-spawn.sh spawn_gen=), the same
// token durable consumers use to tell a replacement worker from the task id it
// reused.
const INCARNATION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// Core derives a source.poll request id from the registration generation and
// the next uncaptured result sequence, so this id is the seam's delivery
// witness.
const REQUEST_ID = /^sha256:[0-9a-f]{64}$/;
const STATUS_HASH = /^[0-9a-f]{64}$/;
const MARKER_VERSION = "fm-fork-progress-guard-v1";
const MARKER_SUFFIX = ".progress-guard-latch";
const MARKER_FIELDS = 6;
const MAX_MARKER_BYTES = 4096;
const MAX_RECORD_BYTES = 65536;
const STATUS_TAIL_BYTES = 512 * 1024;
const STATUS_LINE_MAX = 300;

// The stall window: 25 minutes by default, one knob to tune
// (state/progress-guard/stall-threshold-secs, seconds, 1..86400).
const DEFAULT_THRESHOLD_SECS = 1500;
const MIN_THRESHOLD_SECS = 1;
const MAX_THRESHOLD_SECS = 86400;
// The hard per-task wake ceiling: one wake per hour by default
// (state/progress-guard/min-wake-interval-secs, seconds, 0..86400; 0 disables
// the cap, which only a test or a deliberate operator choice asks for).
const DEFAULT_MIN_WAKE_INTERVAL_SECS = 3600;
const MAX_MIN_WAKE_INTERVAL_SECS = 86400;

// One poll's whole evidence scan stays well inside the binding's default
// 300-second invoke timeout: a shared poll budget split across the entries the
// poll evaluates, and one per-entry cap so a single large worktree spends only
// its own share.
const SCAN_POLL_BUDGET_MS = 20000;
const SCAN_ENTRY_BUDGET_MS = 10000;
// The worktree walk's shape mirrors bin/fm-classify-lib.sh's worktree write
// probe: the same prune set (led by .git, so a supervisor's own read-only git
// commands can never make the probe self-fulfilling, and the generated trees
// that would make the walk expensive), the same six-level depth bound, and the
// same class of wall-clock bound. A walk that hits its bound is inconclusive
// evidence, not silence proof: it answers no wake.
const WALK_MAX_DEPTH = 6;
const WALK_PRUNE = new Set([
  ".git", "node_modules", ".venv", "venv", "__pycache__", ".mypy_cache",
  ".pytest_cache", ".ruff_cache", ".tox", "target", "dist", "build", ".next",
  ".cache", "vendor",
]);
// The terminal status verbs that prove a task concluded while its record still
// exists (bin/fm-classify-lib.sh owns the vocabulary).
const TERMINAL_VERBS = new Set(["done", "failed"]);

// statusLineVerb <line> -> leading verb word
//
// A re-expression of bin/fm-classify-lib.sh's status_line_verb: the text before
// the first colon (the whole line when there is no colon), cut at the first
// bracket, trimmed, with unrecognised correlation tokens dropped after the
// first word. Its header there owns the vocabulary; this owns only the read.
function statusLineVerb(line) {
  const colon = line.indexOf(":");
  let verb = colon === -1 ? line : line.slice(0, colon);
  const bracket = verb.indexOf("[");
  if (bracket !== -1) verb = verb.slice(0, bracket);
  verb = verb.trim();
  if (!verb.includes("corr=")) return verb;
  const words = verb.split(/\s+/).filter((word) => word !== "");
  if (words.length === 0) return "";
  let out = words[0];
  for (let index = 1; index < words.length; index += 1) {
    if (/^corr=[0-9A-Fa-f]{16}$/.test(words[index])) continue;
    out += ` ${words[index]}`;
  }
  return out;
}

// statusTail <file> -> {line, verb, hash} | null
//
// The last non-blank line of a status file, its verb, and the sha256 of its
// exact bytes (trailing carriage return stripped), or null when the file is
// not a plain readable file or holds no line at all. The tail read is bounded
// so a very long status history cannot cost a poll unbounded memory; the last
// line is always inside any window that large. Exported because the adapter's
// gate and this seam's own delivery re-check and self-conclusion must all
// classify the verb through this one implementation.
export function statusTail(file) {
  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    return null;
  }
  if (!info.isFile() || info.isSymbolicLink()) return null;
  let handle;
  try {
    handle = fs.openSync(file, "r");
    const length = Math.min(info.size, STATUS_TAIL_BYTES);
    const offset = info.size - length;
    const buffer = Buffer.allocUnsafe(length);
    const read = fs.readSync(handle, buffer, 0, length, offset);
    if (read !== length) return null;
    const text = buffer.toString("utf8");
    const lines = text.split("\n");
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      const line = lines[index].replace(/\r$/, "");
      if (line.trim() === "") continue;
      return {
        line,
        verb: statusLineVerb(line),
        hash: crypto.createHash("sha256").update(line, "utf8").digest("hex"),
      };
    }
    return null;
  } catch {
    return null;
  } finally {
    if (handle !== undefined) {
      try {
        fs.closeSync(handle);
      } catch {
        // The read already finished or failed; closing cannot change the verdict.
      }
    }
  }
}

// ageText <seconds> -> compact human age: "45s", "27m", "1h12m", "3d".
function ageText(seconds) {
  const total = Math.max(0, Math.round(seconds));
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return minutes % 60 === 0 ? `${hours}h` : `${hours}h${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d`;
}

function truncate(text, max) {
  return text.length <= max ? text : `${text.slice(0, max - 3)}...`;
}

// intKnob <stateDir> <name> <default> <min> <max> -> integer
//
// One optional knob file under <state>/progress-guard/: an absent, unreadable,
// non-integer, or out-of-range answer is the default, so a malformed knob can
// never lengthen the stall window past its bound or silence the cap by
// accident in the wrong direction.
function intKnob(stateDir, name, fallback, min, max) {
  try {
    const raw = fs.readFileSync(path.join(stateDir, "progress-guard", name), "utf8").trim();
    if (/^\d+$/.test(raw)) {
      const value = Number(raw);
      if (value >= min && value <= max) return value;
    }
  } catch {
    // absent or unreadable: the default applies
  }
  return fallback;
}

// The stall threshold, in seconds. This is the one place the window is tuned.
export function stallThresholdSecs(ctx) {
  return intKnob(ctx.stateDir, "stall-threshold-secs", DEFAULT_THRESHOLD_SECS, MIN_THRESHOLD_SECS, MAX_THRESHOLD_SECS);
}

// The per-task wake ceiling, in seconds. A wake never lands closer to the
// previous wake of the same task than this, whatever re-armed it.
export function minWakeIntervalSecs(ctx) {
  return intKnob(ctx.stateDir, "min-wake-interval-secs", DEFAULT_MIN_WAKE_INTERVAL_SECS, 0, MAX_MIN_WAKE_INTERVAL_SECS);
}

// --- evidence ---------------------------------------------------------------

// walkNewest <root> <deadlineMs> -> {mtimeMs, path} | null
//
// The newest counted node under root - a regular file, a symlink, or a
// directory, since a created-and-deleted file still moves its parent's mtime -
// through a bounded depth-first walk that never follows symlinks out and never
// opens a pruned name (led by .git). null is inconclusive: the root vanished,
// a node other than a mid-walk deletion failed to read, or the wall-clock
// deadline passed. A node deleted between readdir and lstat is skipped, not
// inconclusive, because that deletion is itself recent activity its parent
// already counted.
function walkNewest(root, deadlineMs) {
  let best = null;
  const stack = [{ dir: root, depth: 0, isRoot: true }];
  while (stack.length > 0) {
    if (Date.now() > deadlineMs) return null;
    const frame = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(frame.dir, { withFileTypes: true });
    } catch (error) {
      if (frame.isRoot) return null;
      if (error && error.code === "ENOENT") continue;
      return null;
    }
    for (const entry of entries) {
      if (Date.now() > deadlineMs) return null;
      if (WALK_PRUNE.has(entry.name)) continue;
      const target = path.join(frame.dir, entry.name);
      let info;
      try {
        info = fs.lstatSync(target);
      } catch (error) {
        if (error && error.code === "ENOENT") continue;
        return null;
      }
      if (best === null || info.mtimeMs > best.mtimeMs) best = { mtimeMs: info.mtimeMs, path: target };
      if (entry.isDirectory() && frame.depth + 1 <= WALK_MAX_DEPTH) {
        stack.push({ dir: target, depth: frame.depth + 1, isRoot: false });
      }
    }
  }
  return best;
}

// scanEvidence <entry> <ctx> -> {sources, newest} | {inconclusive: "<why>"}
//
// The three evidence sources in one bounded read: the status file's mtime, the
// newest node under the worktree, and (when the task has a data directory) the
// newest node under it. Every failure answers inconclusive, which decideWake
// turns into silence: a walk that cannot finish is not proof that nothing
// happened. The elapsed time is charged back to the poll's shared budget in
// either direction.
function scanEvidence(entry, ctx) {
  const start = Date.now();
  try {
    const allowed = Math.max(
      0,
      Math.min(SCAN_ENTRY_BUDGET_MS, typeof ctx.scanBudgetMs === "number" ? ctx.scanBudgetMs : SCAN_ENTRY_BUDGET_MS),
    );
    if (allowed === 0) return { inconclusive: "budget" };
    const deadline = start + allowed;
    let statusInfo;
    try {
      statusInfo = fs.lstatSync(entry.statusFile);
    } catch {
      return { inconclusive: "status" };
    }
    if (!statusInfo.isFile() || statusInfo.isSymbolicLink()) return { inconclusive: "status" };
    const sources = [{ kind: "status", path: entry.statusFile, mtimeMs: statusInfo.mtimeMs }];
    let worktreeInfo;
    try {
      worktreeInfo = fs.statSync(entry.worktree);
    } catch {
      return { inconclusive: "worktree" };
    }
    if (!worktreeInfo.isDirectory()) return { inconclusive: "worktree" };
    const walked = walkNewest(entry.worktree, deadline);
    if (walked === null) return { inconclusive: "worktree-walk" };
    const worktree = walked.mtimeMs > worktreeInfo.mtimeMs
      ? walked
      : { mtimeMs: worktreeInfo.mtimeMs, path: entry.worktree };
    sources.push({ kind: "worktree", ...worktree });
    let dataExists = false;
    try {
      dataExists = fs.statSync(entry.dataDir).isDirectory();
      if (!dataExists) return { inconclusive: "data" };
    } catch (error) {
      if (!error || error.code !== "ENOENT") return { inconclusive: "data" };
    }
    if (dataExists) {
      const data = walkNewest(entry.dataDir, deadline);
      if (data === null) return { inconclusive: "data-walk" };
      sources.push({ kind: "data", ...data });
    }
    let newest = sources[0];
    for (const source of sources) {
      if (source.mtimeMs > newest.mtimeMs) newest = source;
    }
    return { sources, newest };
  } finally {
    if (typeof ctx.scanBudgetMs === "number") {
      ctx.scanBudgetMs = Math.max(0, ctx.scanBudgetMs - (Date.now() - start));
    }
  }
}

// --- latch ------------------------------------------------------------------

// privateText <file> <maxBytes> -> string | null
function privateText(file, maxBytes) {
  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    return null;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size > maxBytes) return null;
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

// markerFields <text> -> string[] | null
//
// The marker is fixed-arity: exactly MARKER_FIELDS lines, each one field, and
// a version line first. A short, long, or reordered marker is unusable, which
// is the safe direction - an unusable marker never suppresses a wake.
function markerFields(text) {
  const lines = text.split("\n").map((line) => line.replace(/\r$/, ""));
  if (lines.length !== MARKER_FIELDS + 1 || lines[MARKER_FIELDS] !== "") return null;
  const fields = lines.slice(0, MARKER_FIELDS);
  if (fields[0] !== MARKER_VERSION) return null;
  return fields;
}

// markerPath <ctx> <id> -> absolute path | null
function markerPath(ctx, id) {
  if (typeof id !== "string" || !TASK_ID.test(id)) return null;
  if (typeof ctx.stateDir !== "string" || !path.isAbsolute(ctx.stateDir)) return null;
  return path.join(ctx.stateDir, `${id}${MARKER_SUFFIX}`);
}

// readMarker <ctx> <id> -> {incarnation, statusHash, request, epoch} | null
//
// This task's own marker with every field in its own shape, or null when there
// is no such marker. A malformed or foreign file is null, the re-arm and
// duplicate direction; note this read does NOT compare identity - decideWake
// applies the latch and the hourly cap separately, because a marker whose
// identity no longer matches still holds the hour.
function readMarker(ctx, id) {
  const file = markerPath(ctx, id);
  if (file === null) return null;
  const text = privateText(file, MAX_MARKER_BYTES);
  if (text === null) return null;
  const fields = markerFields(text);
  if (fields === null) return null;
  if (fields[1] !== id) return null;
  const incarnation = fields[2];
  const statusHash = fields[3];
  const request = fields[4];
  const epoch = fields[5];
  if (!INCARNATION.test(incarnation)) return null;
  if (!STATUS_HASH.test(statusHash)) return null;
  if (!REQUEST_ID.test(request)) return null;
  if (!/^\d{1,15}$/.test(epoch)) return null;
  return { incarnation, statusHash, request, epoch: Number(epoch) };
}

// publishMarker <ctx> <entry> <request> -> boolean
//
// Atomic publication: one 0600 temp file in the same directory, fsynced, then
// renamed over the marker, then the directory fsynced, then the marker read
// back through the same reader the next poll uses. Every failure returns false
// and leaves no partial marker, and the caller answers anyway: a marker that
// cannot be published costs one duplicate wake, never a suppressed one.
function publishMarker(ctx, entry, request) {
  const file = markerPath(ctx, entry.id);
  if (file === null) return false;
  let tmp = null;
  try {
    const stateInfo = fs.lstatSync(ctx.stateDir);
    if (!stateInfo.isDirectory() || stateInfo.isSymbolicLink()) return false;
    let existing;
    try {
      existing = fs.lstatSync(file);
    } catch (error) {
      if (!error || error.code !== "ENOENT") return false;
      existing = null;
    }
    if (existing !== null && (!existing.isFile() || existing.isSymbolicLink())) return false;
    const body = [
      MARKER_VERSION,
      entry.id,
      entry.incarnation,
      entry.statusHash,
      request,
      String(Math.floor(Date.now() / 1000)),
    ].join("\n") + "\n";
    tmp = path.join(ctx.stateDir, `.fm-fork-progress-guard-latch.${process.pid}.${Date.now()}`);
    const handle = fs.openSync(tmp, "wx", 0o600);
    try {
      fs.writeFileSync(handle, body);
      fs.fsyncSync(handle);
    } finally {
      fs.closeSync(handle);
    }
    if (privateText(tmp, MAX_MARKER_BYTES) !== body) return false;
    fs.renameSync(tmp, file);
    tmp = null;
    const directory = fs.openSync(ctx.stateDir, "r");
    try {
      fs.fsyncSync(directory);
    } catch {
      // A directory that cannot be fsynced still holds the rename; the marker is
      // readable right now, which is what the next poll consults.
    } finally {
      fs.closeSync(directory);
    }
    return privateText(file, MAX_MARKER_BYTES) === body;
  } catch {
    return false;
  } finally {
    if (tmp !== null) {
      try {
        fs.unlinkSync(tmp);
      } catch {
        // Nothing was published under the marker's own name either way.
      }
    }
  }
}

// pruneStallMarkers <ctx> -> number removed
//
// Fork-owned cleanup, run by the adapter on every poll it makes: a marker is
// dropped when this home's own record for its task is gone, and a marker file
// that is malformed is dropped because it can never suppress anything anyway.
// A record that exists is kept even when the marker's identity no longer
// matches it, because that marker still holds the hourly cap for its task id,
// and a record that is merely unreadable right now is never evidence that the
// task is gone. The marker filename is the task id, so this only ever touches
// a file this fork wrote; upstream's task teardown does not know this file, and
// the next poll after a teardown prunes it.
export function pruneStallMarkers(ctx) {
  let removed = 0;
  let names;
  try {
    if (typeof ctx.stateDir !== "string" || !path.isAbsolute(ctx.stateDir)) return 0;
    names = fs.readdirSync(ctx.stateDir);
  } catch {
    return 0;
  }
  for (const name of names) {
    if (!name.endsWith(MARKER_SUFFIX)) continue;
    const id = name.slice(0, -MARKER_SUFFIX.length);
    if (!TASK_ID.test(id)) continue;
    const file = path.join(ctx.stateDir, name);
    let info;
    try {
      info = fs.lstatSync(file);
    } catch {
      continue;
    }
    if (!info.isFile() || info.isSymbolicLink()) continue;
    const fields = markerFields(privateText(file, MAX_MARKER_BYTES) ?? "");
    if (fields === null || fields[1] !== id) {
      if (unlinkMarker(file)) removed += 1;
      continue;
    }
    let record;
    try {
      record = fs.lstatSync(path.join(ctx.stateDir, `${id}.meta`));
    } catch (error) {
      if (error && error.code === "ENOENT" && unlinkMarker(file)) removed += 1;
      continue;
    }
    if (!record.isFile() || record.isSymbolicLink()) {
      if (unlinkMarker(file)) removed += 1;
    }
  }
  return removed;
}

function unlinkMarker(file) {
  try {
    fs.unlinkSync(file);
    return true;
  } catch {
    return false;
  }
}

// --- the stall decision -----------------------------------------------------

function advisoryBody(entry, evidence, silenceSecs, threshold, now) {
  const statusSource = evidence.sources.find((source) => source.kind === "status");
  const worktreeSource = evidence.sources.find((source) => source.kind === "worktree");
  const dataSource = evidence.sources.find((source) => source.kind === "data");
  const since = (source) => ageText((now - source.mtimeMs) / 1000);
  const dataText = dataSource === undefined ? "absent" : `${dataSource.path} (${since(dataSource)} ago)`;
  const lines = [
    `PROGRESS STALL (advisory): task ${entry.id} has produced no new evidence for ${ageText(silenceSecs)} (threshold ${ageText(threshold)}).`,
    `last status line: ${truncate(entry.statusLine, STATUS_LINE_MAX)} (${since(statusSource)} ago)`,
    `newest evidence: ${evidence.newest.path} (${since(evidence.newest)} ago)`,
    `sources: status ${statusSource.path} (${since(statusSource)} ago); worktree ${worktreeSource.path} (${since(worktreeSource)} ago); data ${dataText}`,
    "Advisory evidence that this worker may be stuck; not a decision, an instruction, or authority to steer, stop, or answer anything.",
  ];
  return `${lines.join("\n")}\n`;
}

// currentIncarnation <ctx> <entry> -> string | null
//
// The record's spawn_gen= as it is right now, re-read immediately before
// delivery so a relaunch landing between gate and wake never authorizes a wake
// under the old worker's identity. Anything unreadable is null.
function currentIncarnation(ctx, entry) {
  if (typeof ctx.stateDir !== "string" || !path.isAbsolute(ctx.stateDir)) return null;
  const expected = path.join(ctx.stateDir, `${entry.id}.meta`);
  if (entry.meta !== expected) return null;
  const text = privateText(expected, MAX_RECORD_BYTES);
  if (text === null) return null;
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
  const incarnation = fields.get("spawn_gen") ?? "";
  return INCARNATION.test(incarnation) ? incarnation : null;
}

export function decideWake(entry, ctx) {
  // Silence is the answer to every doubt, including a bug in this module: a
  // throw would be captured as actionable adapter-failure evidence, so the
  // seam answers null instead of ever leaving that record behind.
  try {
    const witness = typeof ctx.requestId === "string" && REQUEST_ID.test(ctx.requestId) ? ctx.requestId : null;
    // The latch is consulted BEFORE any evidence walk, and the request-id rule
    // outranks it: an answer whose capture never landed is repeated instead of
    // suppressed, while an ordinary later poll of the same stall is silent.
    if (witness !== null) {
      const marker = readMarker(ctx, entry.id);
      if (marker !== null && marker.request !== witness) {
        if (marker.incarnation === entry.incarnation && marker.statusHash === entry.statusHash) {
          ctx.log(`progress-guard: latched ${entry.id}`);
          return null;
        }
        // A re-armed question (a new status line or a new worker) still has to
        // clear the hourly cap; the marker's epoch is the last wake's time, so
        // no task ever wakes twice inside one hour whatever re-armed it.
        const interval = minWakeIntervalSecs(ctx);
        const elapsed = Math.floor(ctx.now / 1000) - marker.epoch;
        if (elapsed < interval) {
          ctx.log(`progress-guard: capped ${entry.id}`);
          return null;
        }
      }
    }
    const evidence = scanEvidence(entry, ctx);
    if ("inconclusive" in evidence) {
      ctx.log(`progress-guard: evidence-inconclusive ${entry.id} ${evidence.inconclusive}`);
      return null;
    }
    const threshold = stallThresholdSecs(ctx);
    const silenceSecs = (ctx.now - evidence.newest.mtimeMs) / 1000;
    if (silenceSecs < threshold) return null;
    // Posture re-read immediately before delivery: the status line and the
    // incarnation the wake would name must still be the ones the gate read, so
    // a worker that spoke or was replaced during the walk never gets a stale
    // wake or a marker written under the wrong identity.
    const current = statusTail(entry.statusFile);
    if (current === null || current.line !== entry.statusLine || current.verb !== "working") {
      ctx.log(`progress-guard: not-stalled ${entry.id} status-changed`);
      return null;
    }
    if (currentIncarnation(ctx, entry) !== entry.incarnation) {
      ctx.log(`progress-guard: not-stalled ${entry.id} incarnation-changed`);
      return null;
    }
    if (witness !== null && !publishMarker(ctx, entry, witness)) {
      // Duplicate direction on purpose: no marker means the next poll answers
      // again, which is the only failure this capability may ever make.
      ctx.log(`progress-guard: latch-unpublished ${entry.id}`);
    }
    return { advisory: advisoryBody(entry, evidence, silenceSecs, threshold, ctx.now) };
  } catch (error) {
    try {
      ctx.log(`progress-guard: evaluation-failed ${entry.id}`);
    } catch {
      // A logger that fails must not change the verdict either.
    }
    return null;
  }
}

// --- capture self-conclusion ------------------------------------------------

// advisoryBody's first sentence, parsed back: task id. The shape mirrors the
// adapter's own wake, so a body this line cannot parse is never a conclusion.
const ADVISORY_LINE = /^PROGRESS STALL \(advisory\): task ([A-Za-z0-9][A-Za-z0-9._-]{0,63}) has produced no new evidence for /;

// entryConcluded <ctx> <id> -> boolean
//
// Positive proof only, in this order:
//   record    the task record state/<id>.meta is gone (ENOENT). An existing
//             record falls through to the status proof; an unreadable record is
//             doubt, never a conclusion.
//   terminal  the task's own last status line carries a terminal `done` or
//             `failed` verb, which bin/fm-classify-lib.sh owns and which only a
//             finished task appends while its record still exists.
// A live task, an unreadable status file, and any other verb keep the wake.
function entryConcluded(ctx, id) {
  try {
    fs.lstatSync(path.join(ctx.stateDir, `${id}.meta`));
  } catch (error) {
    return Boolean(error && error.code === "ENOENT");
  }
  const tail = statusTail(path.join(ctx.stateDir, `${id}.status`));
  return tail !== null && TERMINAL_VERBS.has(tail.verb);
}

// stallsConcluded <content> <ctx> -> boolean (never throws)
//
// The judgment behind the adapter's result.silent verdict for a PROGRESS-STALL
// capture: true only when the capture carries at least one advisory and every
// advisory in it is already concluded at the moment the capture is read, so
// the runner records the capture handled instead of presenting a wake that is
// moot by then. The question is asked at read time, never cached at capture
// time, so a task torn down between capture and read concludes the capture
// too.
//
// The content is read line by line: it must open with a full advisory header
// this seam produces, and every later non-empty line belongs to that block (the
// body is multi-line). A capture with no advisory header - a host failure
// record, an empty body, or any foreign content - is never concluded, and keeps
// its wake exactly as before.
//
// One advisory concludes only with the positive proof entryConcluded demands;
// a capture with several advisories concludes only when EVERY one of them
// does, so a live task keeps the whole capture announced. The failure
// direction of this verdict is therefore always the ordinary wake - doubt
// never suppresses, because the latch can only repeat a wake while a wrong
// silence here could swallow one.
//
// ctx is the shape decideWake takes ({home, stateDir, configDir, now, log}).
// This function reads only: it writes no latch marker, records nothing
// handled, and changes no task record - the runner owns recording the capture
// handled when this answers true.
export function stallsConcluded(content, ctx) {
  try {
    if (typeof content !== "string" || content.trim() === "") return false;
    const ids = [];
    let opened = false;
    for (const line of content.split("\n")) {
      if (line.trim() === "") continue;
      const match = ADVISORY_LINE.exec(line);
      if (match !== null) {
        opened = true;
        ids.push(match[1]);
        continue;
      }
      if (!opened) return false;
    }
    if (ids.length === 0) return false;
    for (const id of ids) {
      if (!entryConcluded(ctx, id)) return false;
    }
    try {
      ctx.log(`progress-guard: self-concluded ${ids.join(" ")}`);
    } catch {
      // A logger that fails must not change the verdict either.
    }
    return true;
  } catch {
    // A throw is not proof: any doubt keeps the ordinary wake.
    return false;
  }
}
