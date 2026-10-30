// The readiness seam of the fork PR readiness adapter (process-event-adapter/1).
//
// This module is the WHOLE of the adapter's judgment. Slice T1 shipped it empty;
// it now holds the conservative GitHub readiness predicate and the readiness
// latch that keeps one wake per head, so no other part of the package can
// quietly acquire an opinion about a pull request.
//
// decideWake(entry, ctx)
//   entry  one armed task that already passed the adapter's eligibility gate:
//          {id, pr, host, owner, repo, number, head, mode, yolo, kind, meta}.
//          Only GitHub pull requests reach this function; GitLab,
//          Forgejo, Gerrit, local-only, yolo=off, and secondmate records are
//          refused before the call, so a change to this module cannot widen
//          which tasks can wake firstmate.
//          head is the recorded state/<id>.meta pr_head= that the gate already
//          validated, so it is the recorded head this module compares against.
//          meta must be exactly <stateDir>/<id>.meta: the seam re-reads that one
//          record itself (see "THE LATCH" below) and refuses to read any other
//          path. The gate reads state/<id>.meta and the armed merge poll's
//          state/<id>.check.sh sidecar; both are owned by upstream tasks and are
//          never written here.
//   ctx    {home, stateDir, configDir, evaluateCount, now, requestId, log}:
//          absolute paths resolved from the registration's config_ref, how many
//          entries this poll offers the seam, the current epoch milliseconds, the
//          host's own request id for this poll (see "The latch"), and a stderr
//          logger the host captures and discards. One ctx per poll, shared by
//          every entry that poll evaluates, so the read budget below is one
//          total for the poll and is split across those entries.
//   returns null, which is silence, or {advisory: "<wake body>"}.
//
// The predicate. A wake is produced only when every one of these holds:
//
//   open       the live pull request state is OPEN and isDraft is exactly false;
//   mergeable  the live mergeability is exactly MERGEABLE. A CONFLICTING head,
//              an UNKNOWN (GitHub has not computed it), and a missing or
//              malformed field are all silence: GitHub skips required and CI
//              checks on a head that conflicts with its base, so an all-green
//              or empty rollup there is the artifact of checks that never ran,
//              never evidence that they passed.
//   head       the live headRefOid is a valid commit id and equals the recorded
//              head (entry.head). A head the record does not carry is never
//              inferred, and a disagreement is silence rather than a guess.
//   green      every reported check is green at that head, judged with the merge
//              gate's own semantics (see checksNotGreen below): a check run
//              counts only through its current run, with supersession, unnamed
//              runs grouped alone, status contexts never grouped, and SUCCESS,
//              NEUTRAL, and SKIPPED completions green while anything pending,
//              queued, failed, cancelled, timed out, or malformed stays red. A
//              reported SKIPPED or NEUTRAL conclusion is green exactly as the
//              merge gate reads it; a required context that never reported at
//              all is not green and keeps the whole read silent.
//   required   the applicable classic branch protection and active rulesets are
//              both read completely, and every required context they name has
//              reported at that live head, with a producer-app match for a
//              bound requirement reported as a check run.
//   reported   a rollup that reports no check at all is missing evidence, not
//              green: it is silence while this repository has at least one
//              ACTIVE workflow that triggers on pull_request. The workflow
//              list carries state and path but never triggers, so every active
//              workflow's own file is read and scanned (pullRequestWorkflows
//              below); an unreadable workflow list, file, or trigger block is
//              silence too. Only a repository with no active pull-request
//              workflow can report zero checks and keep looking green.
//
// Silence is the answer to every other outcome: a lookup failure, a timeout, an
// incomplete or malformed response, an unparsable document, an unreadable
// required-context source, an unreadable workflow input, a partially successful
// read, an unknown __typename, or any doubt at all. A green-looking rollup
// beside an unreadable
// required-context source is silence, never green: no input can be partly
// missing and still be green. This predicate re-expresses only what an advisory
// verdict needs, from bin/fm-pr-merge.sh's documented semantics; it never calls
// the merge command, so a divergence can cost a wasted wake or a missed one and
// never a bad merge.
//
// Cost. The common not-ready case costs exactly one forge read (the initial
// pull request view). The required-context reads, and the check-run producer
// read a bound requirement needs, happen only after the initial read already
// looks fully green and at the recorded head; the workflow-list read and the
// one read per active workflow file a zero-check rollup needs happen only after
// those too, so a pull request with reported checks never pays for them. One
// poll has one bounded read
// budget (READ_BUDGET_MS, well inside the binding's 300-second default invoke
// timeout) and that budget is split evenly across the entries the poll
// evaluates, with a per-read timeout inside each share. A hanging or very slow
// pull request therefore spends only its own share instead of the share of every
// entry that sorts after it, and the shares still add up to the one total; a
// share that runs out is silence for that entry, never a green verdict.
// state/pr-green/read-budget-ms may shorten the total for tests or a slow host;
// it can never lengthen it.
//
// Naming the forge binary. The extension host invokes this process with a
// minimal environment whose PATH holds only the interpreter's own directory and
// the system directories, so the `gh` upstream's own scripts find on the
// operator's PATH is usually not resolvable here. This module therefore resolves
// gh explicitly and predicts nothing: an absolute path in this home's
// config/pr-green-gh wins when that file exists (and an unusable file is
// silence rather than a fallback), otherwise the standard install locations are
// probed in one fixed order. No gh means silence, never a wake. Authentication
// is gh's own: the binding requires the credential-store consent so the
// operator's gh configuration is visible, and no credential is read or written
// here.
//
// The contract this seam keeps:
//
//   Latch        at most one wake per task, pull request, and live head in
//                normal operation; re-armed by a changed head. See "The latch"
//                below, which composes that with the guarantee that a genuinely
//                ready head is never silently suppressed.
//   Body         the advisory text firstmate reads. This seam produces it,
//                and it names the task, the pull request URL, and the head it
//                is talking about, and it says plainly that it is advisory
//                evidence - never an approval, a merge, or authority to merge.
//   Errors       returning null is silence and is always safe. The adapter
//                treats an empty, non-string, or oversized body as silence, so
//                every body must be a bounded string that survives JSON
//                encoding. A throw is NOT silence: the adapter answers with an
//                unavailable error, which core captures as an actionable
//                adapter-failure record. Either way no failure path can ever be
//                read as green.
//
// THE LATCH. Readiness has memory: one marker per task, <home>/state/<id>.pr-
// green-ready, written as one fixed-arity line record and published by
// temp-file rename (0600, same directory, fsynced), in the shape upstream's own
// <state>/<id>.pr-poll-merge-notified marker already uses. It is a SEPARATE file
// from that merge-notification marker and from every merge record, so readiness
// suppression and merge notification can never stand in for each other in either
// direction.
//
//   marker    version line fm-fork-pr-green-ready-v1, then task id, the task
//             record's spawn_gen= incarnation, provider, host, owner/repo, pull
//             number, head, the host request id that produced the wake, and the
//             epoch second it was published.
//   matches   a marker suppresses only when every identity field above equals
//             this task's own canonical identity (task id, provider, host,
//             owner/repo, number, head) and its incarnation equals the CURRENT
//             state/<id>.meta spawn_gen=. A changed head, a changed pull request,
//             and a replaced worker (upstream mints a new spawn_gen= for every
//             spawn and relaunch) therefore re-arm rather than suppress.
//   duplicate two things make the latch fail toward one possible duplicate wake
//             and never toward suppression. (1) A marker write that fails, is
//             interrupted, or is unreadable afterwards leaves no valid marker, so
//             the next poll simply answers again. (2) A marker records the HOST
//             request id that produced its wake: core derives that id from the
//             next uncaptured result sequence, so it is unchanged while a wake has
//             not yet been captured and changes once it has. A retry after a crash
//             between answering and capture therefore arrives with the SAME id as
//             the marker and is answered again instead of being suppressed, while
//             an ordinary later poll arrives with a different id and is silent.
//             Both directions are exercised by fork/tests/fm-fork-pr-green-latch.
//
// The marker is written before the wake is returned, never after: a crash in
// between is repaired by the request-id rule above, whereas writing after would
// leave a delivered wake unrecorded and repeat it on every poll.
//
// Nothing in this module may merge, arm a merge, rewrite a task record, or record
// approval or merge authority; the latch is the only state this capability is
// ever meant to write, and it records a wake, not a merge. It is otherwise a pure
// reader of the forge and this home's task records. bin/fm-pr-merge.sh remains
// the only merge authority and re-validates every required check at merge time.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// One poll's whole readiness evaluation stays well inside the binding's default
// 300-second invoke timeout, with room for the adapter's own bookkeeping.
const READ_BUDGET_MS = 25000;
const MIN_BUDGET_MS = 200;
const PER_READ_MS = 8000;
const MAX_READ_BYTES = 8 * 1024 * 1024;
const MAX_CONFIG_BYTES = 4096;
const MAX_ROLLUP_ENTRIES = 2000;
const MAX_REQUIREMENTS = 500;
const MAX_WORKFLOW_FILES = 40;
const MAX_WORKFLOW_BYTES = 256 * 1024;

const HEAD = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
// The delivery modes this fork may merge on its own authority. Re-checked here
// from the task record rather than trusted from the caller's entry.
const READINESS_MODES = new Set(["no-mistakes", "direct-PR"]);
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// Upstream's per-spawn incarnation token (bin/fm-spawn.sh spawn_gen=), the same
// token durable consumers use to tell a replacement worker from the task id it
// reused.
const INCARNATION = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
// Core derives a source.poll request id from the registration generation and the
// next uncaptured result sequence, so this id is the seam's delivery witness.
const REQUEST_ID = /^sha256:[0-9a-f]{64}$/;
const PROVIDER = "github";
const MARKER_VERSION = "fm-fork-pr-green-ready-v1";
const MARKER_SUFFIX = ".pr-green-ready";
const MARKER_FIELDS = 10;
const MAX_MARKER_BYTES = 4096;
const MAX_RECORD_BYTES = 65536;
// The merge gate accepts a supersession timestamp only when it is a whole-second
// UTC instant, so a timestamp of any other shape can never make a stale run
// disappear.
const SETTLED_AT = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
const GREEN_CONCLUSIONS = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);
// GitHub's own mergeability enum: only MERGEABLE is evidence, while CONFLICTING
// and UNKNOWN (not yet computed) are missing evidence.
const MERGEABLE = "MERGEABLE";
const DEFAULT_GH = "/opt/homebrew/bin/gh";
const STANDARD_GH = ["/usr/local/bin/gh", "/usr/bin/gh", "/bin/gh"];

// A configured or probed gh candidate must be an executable regular file.
function usableExecutable(candidate) {
  let info;
  try {
    info = fs.statSync(candidate);
    fs.accessSync(candidate, fs.constants.X_OK);
  } catch {
    return false;
  }
  return info.isFile();
}

// ghBinary <ctx> -> absolute path | null
//
// An explicit config/pr-green-gh is authoritative: when that file exists and is
// unusable, this returns null rather than silently probing another binary.
function ghBinary(ctx) {
  const configured = path.join(ctx.configDir, "pr-green-gh");
  let info;
  try {
    info = fs.lstatSync(configured);
  } catch (error) {
    if (error && error.code !== "ENOENT") return null;
    info = null;
  }
  if (info) {
    if (!info.isFile() || info.isSymbolicLink() || info.size > MAX_CONFIG_BYTES) return null;
    let text;
    try {
      text = fs.readFileSync(configured, "utf8");
    } catch {
      return null;
    }
    const lines = text.split("\n").map((line) => line.replace(/\r$/, "")).filter((line) => line !== "");
    if (lines.length !== 1) return null;
    const candidate = lines[0];
    if (!path.isAbsolute(candidate) || path.normalize(candidate) !== candidate) return null;
    return usableExecutable(candidate) ? candidate : null;
  }
  const candidates = [DEFAULT_GH, ...STANDARD_GH];
  // The interpreter's own directory is the one directory the sanitized PATH is
  // guaranteed to hold, so a gh installed beside node is found without guessing
  // beyond it.
  candidates.push(path.join(path.dirname(process.execPath), "gh"));
  for (const candidate of candidates) {
    if (usableExecutable(candidate)) return candidate;
  }
  return null;
}

// readBudgetMs <ctx> -> milliseconds
function readBudgetMs(ctx) {
  try {
    const value = Number(fs.readFileSync(path.join(ctx.stateDir, "pr-green", "read-budget-ms"), "utf8").trim());
    if (Number.isInteger(value) && value >= MIN_BUDGET_MS && value <= READ_BUDGET_MS) return value;
  } catch {
    // absent or unreadable: the full budget applies
  }
  return READ_BUDGET_MS;
}

// The poll's read budget is one total, split evenly across the entries that poll
// evaluates: a task that hangs or answers slowly spends only its own share, so
// it cannot consume the share of every task that sorts after it, and the shares
// still add up to that one total.
const readSchedules = new WeakMap();

// readSchedule <ctx> -> {deadline, sliceMs}
function readSchedule(ctx) {
  let schedule = readSchedules.get(ctx);
  if (schedule === undefined) {
    const total = readBudgetMs(ctx);
    const entries = Number.isInteger(ctx.evaluateCount) && ctx.evaluateCount > 0 ? ctx.evaluateCount : 1;
    schedule = { deadline: Date.now() + total, sliceMs: Math.max(1, Math.floor(total / entries)) };
    readSchedules.set(ctx, schedule);
  }
  return schedule;
}

// ForgeReader: the bounded, read-only view of one pull request on one host.
//
// Every read answers a parsed JSON document or null, and null always means "this
// input is unavailable" - never "there is nothing to check". A non-zero exit, a
// signal, a spent timeout, an oversized or empty body, and a body that is not
// JSON are all the same answer, so no caller can distinguish a failed read from
// an empty one and be tempted to treat either as green.
function forgeReader(entry, ctx) {
  const gh = ghBinary(ctx);
  if (!gh) return null;
  const schedule = readSchedule(ctx);
  const deadline = Math.min(Date.now() + schedule.sliceMs, schedule.deadline);
  const env = { ...process.env, GH_PAGER: "cat", GH_NO_UPDATE_NOTIFIER: "1", GH_PROMPT_DISABLED: "1" };
  if (entry.host === "github.com") delete env.GH_HOST;
  else env.GH_HOST = entry.host;

  function run(args) {
    const left = deadline - Date.now();
    if (left <= 0) return null;
    const timeout = Math.min(PER_READ_MS, left);
    const result = spawnSync(gh, args, {
      cwd: ctx.home,
      env,
      encoding: "utf8",
      timeout,
      killSignal: "SIGKILL",
      maxBuffer: MAX_READ_BYTES,
      stdio: ["ignore", "pipe", "ignore"],
    });
    if (result.error || result.signal || result.status !== 0) return null;
    const body = typeof result.stdout === "string" ? result.stdout.trim() : "";
    if (body === "") return null;
    try {
      return JSON.parse(body);
    } catch {
      return null;
    }
  }

  return {
    view() {
      return run([
        "pr", "view", entry.pr, "--json",
        "state,isDraft,mergeable,headRefOid,baseRefName,statusCheckRollup",
      ]);
    },
    api(resource, paginate = false) {
      return run(paginate ? ["api", "--paginate", "--slurp", resource] : ["api", resource]);
    },
  };
}

// checkEntries <rollup> -> entries | null
//
// The merge gate's own reading of one rollup, re-expressed for an advisory
// verdict: a check run is green only when it COMPLETED with SUCCESS, NEUTRAL, or
// SKIPPED, a status context is green only when its state is SUCCESS, and
// anything unrecognized - including a __typename that is neither of the two the
// rollup union carries - is unreadable, so the whole rollup is silence.
function checkEntries(rollup) {
  if (!Array.isArray(rollup) || rollup.length > MAX_ROLLUP_ENTRIES) return null;
  const entries = [];
  for (let index = 0; index < rollup.length; index += 1) {
    const raw = rollup[index];
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
    if (raw.__typename === "CheckRun") {
      const name = typeof raw.name === "string" ? raw.name : "";
      entries.push({
        kind: "check_run",
        name,
        // An unnamed run is grouped alone by its own position, so unrelated
        // unnamed checks can neither supersede nor be superseded by each other.
        group: name === "" ? `\u0000unnamed:${index}` : name,
        completed: raw.status === "COMPLETED",
        ok: raw.status === "COMPLETED" && GREEN_CONCLUSIONS.has(raw.conclusion),
        at: typeof raw.startedAt === "string" && SETTLED_AT.test(raw.startedAt) ? raw.startedAt : null,
      });
    } else if (raw.__typename === "StatusContext") {
      entries.push({
        kind: "status_context",
        name: typeof raw.context === "string" ? raw.context : "",
        ok: raw.state === "SUCCESS",
      });
    } else {
      return null;
    }
  }
  return entries;
}

// checksNotGreen <rollup> -> names[] | null
//
// Every check this rollup does not report green, one per entry, or null when the
// rollup itself cannot be read. Status contexts are never grouped or superseded;
// check runs are judged by their current run: a name is cleared only when every
// non-green run is COMPLETED, whole-second-dated, and started strictly before a
// green run of the same name. A still-running, queued, undated, or tied run
// stays red, and a name whose only runs are red stays red.
function checksNotGreen(rollup) {
  const entries = checkEntries(rollup);
  if (entries === null) return null;
  const red = [];
  const groups = new Map();
  for (const entry of entries) {
    if (entry.kind === "status_context") {
      if (!entry.ok) red.push(entry.name);
      continue;
    }
    const bucket = groups.get(entry.group);
    if (bucket) bucket.push(entry);
    else groups.set(entry.group, [entry]);
  }
  for (const bucket of groups.values()) {
    const reds = bucket.filter((entry) => !entry.ok);
    if (reds.length === 0) continue;
    const greens = bucket.filter((entry) => entry.ok && entry.at !== null).map((entry) => entry.at);
    const newestGreen = greens.length > 0 ? greens.sort().at(-1) : null;
    const superseded = newestGreen !== null
      && reds.every((entry) => entry.completed && entry.at !== null && entry.at < newestGreen);
    if (!superseded) red.push(bucket[0].name);
  }
  return red;
}

// requiredUnion <classic> <ruleset> -> requirements[]
//
// The merge gate's union of classic branch protection and active rulesets: exact
// duplicates collapse, and one context bound to a producer app keeps only its
// bound entries, so a name-only duplicate cannot weaken that binding.
function requiredUnion(classic, ruleset) {
  const seen = new Map();
  for (const item of [...classic, ...ruleset]) {
    seen.set(`${item.context}\u0000${item.app_id === null ? "" : item.app_id}`, item);
  }
  const byContext = new Map();
  for (const item of seen.values()) {
    const bucket = byContext.get(item.context);
    if (bucket) bucket.push(item);
    else byContext.set(item.context, [item]);
  }
  const union = [];
  for (const bucket of byContext.values()) {
    const bound = bucket.filter((item) => item.app_id !== null);
    union.push(...(bound.length > 0 ? bound : bucket));
  }
  return union;
}

// readClassic <reader> <base> -> requirements[] | null
function readClassic(reader, entry, base) {
  const branch = reader.api(`repos/${entry.owner}/${entry.repo}/branches/${encodeURIComponent(base)}`);
  if (branch === null || typeof branch !== "object" || Array.isArray(branch)) return null;
  if (typeof branch.protected !== "boolean") return null;
  if (!branch.protected) return [];
  const summary = branch.protection && typeof branch.protection === "object"
    ? branch.protection.required_status_checks
    : null;
  if (summary === null || typeof summary !== "object" || Array.isArray(summary)) return null;
  const checks = summary.checks === undefined ? [] : summary.checks;
  const contexts = summary.contexts === undefined ? [] : summary.contexts;
  if (!Array.isArray(checks) || !Array.isArray(contexts)) return null;
  const classic = [];
  for (const check of checks) {
    if (check === null || typeof check !== "object" || Array.isArray(check)) return null;
    if (typeof check.context !== "string" || check.context.length === 0) return null;
    let appId = check.app_id === undefined ? null : check.app_id;
    if (appId !== null && typeof appId !== "number") return null;
    if (appId === -1) appId = null;
    classic.push({ context: check.context, app_id: appId });
  }
  for (const context of contexts) {
    if (typeof context !== "string" || context.length === 0) return null;
    classic.push({ context, app_id: null });
  }
  return classic;
}

// readRuleset <reader> <base> -> requirements[] | null
//
// A rules source that this token cannot page, that answers with anything but JSON
// arrays of rules, or that names an unusable requirement is unreadable, and an
// unreadable required-context source is silence. The merge gate's narrow
// plan-unavailable exception is deliberately not mirrored: a pull request whose
// required set cannot be read completely is never called ready here.
function readRuleset(reader, entry, base) {
  const pages = reader.api(`repos/${entry.owner}/${entry.repo}/rules/branches/${encodeURIComponent(base)}`, true);
  if (!Array.isArray(pages)) return null;
  const ruleset = [];
  for (const page of pages) {
    if (!Array.isArray(page)) return null;
    for (const rule of page) {
      if (rule === null || typeof rule !== "object" || Array.isArray(rule)) return null;
      if (rule.type !== "required_status_checks") continue;
      const parameters = rule.parameters;
      const required = parameters && typeof parameters === "object" ? parameters.required_status_checks : undefined;
      if (!Array.isArray(required)) return null;
      for (const item of required) {
        if (item === null || typeof item !== "object" || Array.isArray(item)) return null;
        if (typeof item.context !== "string" || item.context.length === 0) return null;
        let appId = item.integration_id === undefined ? null : item.integration_id;
        if (appId !== null && typeof appId !== "number") return null;
        if (appId === -1) appId = null;
        ruleset.push({ context: item.context, app_id: appId });
      }
    }
  }
  return ruleset;
}

// readProducers <reader> <head> -> [{name, app_id}] | null
//
// The check runs reported at the live head, which is how a producer-bound
// requirement is confirmed to have reported from the app that protects it. Any
// run that is not complete evidence for that head makes the whole read
// unreadable, so a partial page can never satisfy a binding.
function readProducers(reader, entry, head) {
  const pages = reader.api(`repos/${entry.owner}/${entry.repo}/commits/${encodeURIComponent(head)}/check-runs`, true);
  if (!Array.isArray(pages)) return null;
  const producers = [];
  for (const page of pages) {
    if (page === null || typeof page !== "object" || Array.isArray(page)) return null;
    if (!Array.isArray(page.check_runs)) return null;
    for (const run of page.check_runs) {
      if (run === null || typeof run !== "object" || Array.isArray(run)) return null;
      if (typeof run.name !== "string" || run.name === "") return null;
      if (!run.app || typeof run.app !== "object" || typeof run.app.id !== "number") return null;
      if (run.head_sha !== head) return null;
      producers.push({ name: run.name, app_id: run.app.id });
    }
  }
  return producers;
}

// unreportedRequired <requirements> <rollup> <producers> -> contexts[] | null
//
// A requirement counts as reported only when this rollup carries it: by name for
// an unbound requirement, by name plus a matching producer app when a bound
// requirement reported as a check run, and by name for a bound requirement
// reported as a commit status, which carries no app id to compare. A required
// context that never reported is never green.
function unreportedRequired(requirements, rollup, producers) {
  const entries = checkEntries(rollup);
  if (entries === null) return null;
  const unreported = [];
  for (const requirement of requirements) {
    const reported = entries.some((entry) => {
      const name = entry.name;
      if (requirement.app_id === null) return name === requirement.context;
      if (entry.kind !== "check_run") return name === requirement.context;
      return name === requirement.context
        && producers.some((producer) => producer.name === requirement.context && producer.app_id === requirement.app_id);
    });
    if (!reported) unreported.push(requirement.context);
  }
  return unreported;
}

// --- the zero-check guard ---------------------------------------------------
//
// A rollup that reports no check at all is missing evidence, not green: GitHub
// starts required and CI checks when it can, so an empty rollup beside a
// repository whose workflows run on pull requests means the checks never ran -
// the shape a conflicting head used to produce - rather than that they passed.
// The functions below own that question; evaluate asks it only after every
// other input already looks green.

// workflowFilePath <listed> -> the path's URL form | null
//
// A workflow file path the repository listed, segment-by-segment validated and
// percent-encoded for the contents read. Anything else makes the whole workflow
// list unreadable, and unreadable is silence - never "no such workflow".
function workflowFilePath(listed) {
  if (typeof listed !== "string" || listed === "" || listed.length > 512) return null;
  const segments = listed.split("/");
  for (const segment of segments) {
    if (segment === "" || segment === "." || segment === "..") return null;
    if (!/^[A-Za-z0-9._-]+$/.test(segment)) return null;
  }
  return segments.map(encodeURIComponent).join("/");
}

// scalarToken <text> -> the unquoted token | null
function scalarToken(text) {
  const value = text.trim();
  if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'"))) {
    if (value.at(-1) !== value[0]) return null;
    return value.slice(1, -1);
  }
  return value;
}

// flowTriggersPullRequest <text> -> boolean | null
//
// The flow forms of a trigger block: [push, pull_request] lists and
// {pull_request: {...}} mappings. A mapping scan can only ever over-report - a
// nested key literally named pull_request counts - which costs a missed wake,
// never a false one.
function flowTriggersPullRequest(text) {
  if (text.startsWith("[")) {
    if (!text.endsWith("]")) return null;
    const inner = text.slice(1, -1);
    for (const item of inner.split(",")) {
      const token = scalarToken(item);
      if (token === null) return null;
      if (token === "pull_request") return true;
    }
    return false;
  }
  if (!text.endsWith("}")) return null;
  const mappingKey = /[{,]\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z0-9_-]+))\s*:/g;
  let found = false;
  for (let match = mappingKey.exec(text); match !== null; match = mappingKey.exec(text)) {
    if ((match[1] ?? match[2] ?? match[3]) === "pull_request") found = true;
  }
  return found;
}

// workflowTriggersPullRequest <source> -> boolean | null
//
// Whether one workflow file's own trigger block names pull_request - and only
// pull_request: pull_request_target is a different trigger. The scan is
// deliberately literal: a trigger block it cannot read with confidence (no
// top-level on:, a merge key, an empty block, a flow form that does not close)
// is null, and null keeps the whole readiness read silent. A file the scan
// cannot place on: inside is unreadable, never "does not trigger".
function workflowTriggersPullRequest(source) {
  const lines = source.split("\n");
  let start = -1;
  for (let index = 0; index < lines.length; index += 1) {
    if (/^(?:"on"|'on'|on):/.test(lines[index])) {
      start = index;
      break;
    }
  }
  if (start === -1) return null;
  const rest = lines[start].slice(lines[start].indexOf(":") + 1).replace(/\s+#.*$/, "").trim();
  if (rest !== "") {
    if (rest.startsWith("[") || rest.startsWith("{")) return flowTriggersPullRequest(rest);
    return scalarToken(rest) === "pull_request";
  }
  let expect = -1;
  let entries = 0;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index].replace(/\s+#.*$/, "");
    if (line.trim() === "") continue;
    const indent = line.length - line.trimStart().length;
    if (indent === 0) break;
    if (expect === -1) expect = indent;
    else if (indent !== expect) continue;
    entries += 1;
    const content = line.trim();
    if (content.startsWith("- ")) {
      if (scalarToken(content.slice(2)) === "pull_request") return true;
      continue;
    }
    const colon = content.indexOf(":");
    if (colon <= 0) return null;
    const key = scalarToken(content.slice(0, colon));
    if (key === null || key === "") return null;
    if (key === "pull_request") return true;
    if (key === "<<") return null;
  }
  return entries > 0 ? false : null;
}

// readWorkflowSource <reader> <entry> <file> -> source | null
//
// One workflow file's source from the contents read its path names. A body that
// is not one small base64 text file is unreadable, and unreadable is silence.
function readWorkflowSource(reader, entry, file) {
  const body = reader.api(`repos/${entry.owner}/${entry.repo}/contents/${file}`);
  if (body === null || typeof body !== "object" || Array.isArray(body)) return null;
  if (body.type !== "file" || body.encoding !== "base64" || typeof body.content !== "string") return null;
  if (Number.isInteger(body.size) && body.size > MAX_WORKFLOW_BYTES) return null;
  const source = Buffer.from(body.content, "base64").toString("utf8");
  if (Buffer.byteLength(source, "utf8") > MAX_WORKFLOW_BYTES) return null;
  return source;
}

// pullRequestWorkflows <reader> <entry> -> boolean | null
//
// Whether this repository has at least one ACTIVE workflow that triggers on
// pull_request. The workflow list carries each workflow's state and file path
// but never its triggers, so every active workflow's own file is read and
// scanned. An unreadable list, an unusable path, an unscannable trigger block,
// or an unreadable file makes the whole question unreadable - silence, never
// "no such workflow". The file reads are bounded by MAX_WORKFLOW_FILES; a
// longer list is unreadable rather than sampled.
function pullRequestWorkflows(reader, entry) {
  const pages = reader.api(`repos/${entry.owner}/${entry.repo}/actions/workflows`, true);
  if (!Array.isArray(pages)) return null;
  const active = [];
  for (const page of pages) {
    if (page === null || typeof page !== "object" || Array.isArray(page)) return null;
    if (!Array.isArray(page.workflows)) return null;
    for (const workflow of page.workflows) {
      if (workflow === null || typeof workflow !== "object" || Array.isArray(workflow)) return null;
      if (typeof workflow.state !== "string") return null;
      if (workflow.state !== "active") continue;
      const file = workflowFilePath(workflow.path);
      if (file === null) return null;
      active.push(file);
      if (active.length > MAX_WORKFLOW_FILES) return null;
    }
  }
  for (const file of active) {
    const source = readWorkflowSource(reader, entry, file);
    if (source === null) return null;
    const triggers = workflowTriggersPullRequest(source);
    if (triggers === null) return null;
    if (triggers) return true;
  }
  return false;
}

// evaluate <entry> <ctx> -> {head, base, required} | null
function evaluate(entry, ctx) {
  const reader = forgeReader(entry, ctx);
  if (reader === null) {
    ctx.log(`pr-green: not-ready ${entry.id} no-github-cli`);
    return null;
  }
  const view = reader.view();
  if (view === null || typeof view !== "object" || Array.isArray(view)) {
    ctx.log(`pr-green: not-ready ${entry.id} pull-unreadable`);
    return null;
  }
  if (view.state !== "OPEN") {
    ctx.log(`pr-green: not-ready ${entry.id} not-open`);
    return null;
  }
  if (view.isDraft !== false) {
    ctx.log(`pr-green: not-ready ${entry.id} draft-unconfirmed`);
    return null;
  }
  // A pull request that is not provably mergeable is missing evidence, never
  // green: GitHub skips required and CI checks on a head that conflicts with
  // its base (or while mergeability is still UNKNOWN), so a fully green or
  // empty rollup there is the artifact of checks that never ran.
  if (view.mergeable !== MERGEABLE) {
    ctx.log(`pr-green: not-ready ${entry.id} not-mergeable`);
    return null;
  }
  const head = view.headRefOid;
  if (typeof head !== "string" || !HEAD.test(head)) {
    ctx.log(`pr-green: not-ready ${entry.id} head-unreadable`);
    return null;
  }
  if (head !== entry.head) {
    ctx.log(`pr-green: not-ready ${entry.id} head-mismatch`);
    return null;
  }
  const base = view.baseRefName;
  if (typeof base !== "string" || base === "") {
    ctx.log(`pr-green: not-ready ${entry.id} base-unreadable`);
    return null;
  }
  const red = checksNotGreen(view.statusCheckRollup);
  if (red === null) {
    ctx.log(`pr-green: not-ready ${entry.id} rollup-unreadable`);
    return null;
  }
  if (red.length > 0) {
    ctx.log(`pr-green: not-ready ${entry.id} checks-not-green`);
    return null;
  }
  // Only a rollup that already looks fully green at the recorded head costs the
  // required-context reads.
  const classic = readClassic(reader, entry, base);
  if (classic === null) {
    ctx.log(`pr-green: not-ready ${entry.id} required-protection-unreadable`);
    return null;
  }
  const ruleset = readRuleset(reader, entry, base);
  if (ruleset === null) {
    ctx.log(`pr-green: not-ready ${entry.id} required-rules-unreadable`);
    return null;
  }
  const required = requiredUnion(classic, ruleset);
  if (required.length > MAX_REQUIREMENTS) {
    ctx.log(`pr-green: not-ready ${entry.id} required-oversized`);
    return null;
  }
  let producers = [];
  if (required.some((requirement) => requirement.app_id !== null)) {
    producers = readProducers(reader, entry, head);
    if (producers === null) {
      ctx.log(`pr-green: not-ready ${entry.id} producers-unreadable`);
      return null;
    }
  }
  const unreported = unreportedRequired(required, view.statusCheckRollup, producers);
  if (unreported === null) {
    ctx.log(`pr-green: not-ready ${entry.id} rollup-unreadable`);
    return null;
  }
  if (unreported.length > 0) {
    ctx.log(`pr-green: not-ready ${entry.id} required-unreported`);
    return null;
  }
  // Every reported check is green and every requirement has reported - but a
  // rollup that reports NOTHING at all is still missing evidence while this
  // repository has an active workflow that triggers on pull_request. This is
  // the last guard, so a rollup with reported checks never pays for the
  // workflow reads, and a non-empty required set already silenced an empty
  // rollup above.
  if (view.statusCheckRollup.length === 0) {
    const workflows = pullRequestWorkflows(reader, entry);
    if (workflows === null) {
      ctx.log(`pr-green: not-ready ${entry.id} workflows-unreadable`);
      return null;
    }
    if (workflows) {
      ctx.log(`pr-green: not-ready ${entry.id} checks-missing`);
      return null;
    }
  }
  return { head, base, required: required.length };
}

// --- the readiness latch ---------------------------------------------------
//
// Everything below owns the one piece of durable state this capability writes.
// It is written only for a pull request this seam is about to answer ready, and
// it can only ever cause a wake to be skipped for the exact identity it names.

// privateText <file> <max-bytes> -> string | null
//
// One small regular, non-link, non-oversized file's text, or null. null means
// "unavailable", and no caller may read it as "empty".
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

// recordFields <text> -> Map | null
//
// One task record as its own plain key=value lines. A duplicate key, a line
// without a key, or a key outside the record's own alphabet makes the record
// ambiguous, so it is refused rather than resolved in either direction.
function recordFields(text) {
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

// markerFields <text> -> string[] | null
//
// The marker is fixed-arity: exactly MARKER_FIELDS lines, each one field, and a
// version line first. A short, long, or reordered marker is unusable, which is
// the safe direction - an unusable marker never suppresses a wake.
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

// identityOf <fields> -> the marker's canonical pull request identity
//
// The marker splits the identity into the parts a reader can check one at a
// time: provider, host, owner/repo, and pull number. Its pull request URL is
// derived from those parts, never parsed back out of a stored string.
function identityOf(fields) {
  return {
    id: fields[1],
    incarnation: fields[2],
    provider: fields[3],
    host: fields[4],
    repoPath: fields[5],
    number: fields[6],
    head: fields[7],
    request: fields[8],
    pr: `https://${fields[4]}/${fields[5]}/pull/${fields[6]}`,
  };
}

// readMarker <ctx> <entry> <incarnation> -> identity | null
//
// The marker that names this task's own canonical pull request identity, its
// live head, and its current incarnation, or null when there is no such marker.
// Every mismatch - a changed head, a changed pull request, a replaced worker, a
// malformed or foreign marker - is null, which is the re-arm direction.
function readMarker(ctx, entry, incarnation) {
  const file = markerPath(ctx, entry.id);
  if (file === null) return null;
  const text = privateText(file, MAX_MARKER_BYTES);
  if (text === null) return null;
  const fields = markerFields(text);
  if (fields === null) return null;
  const identity = identityOf(fields);
  if (identity.id !== entry.id) return null;
  if (identity.provider !== PROVIDER) return null;
  if (identity.host !== entry.host) return null;
  if (identity.repoPath !== `${entry.owner}/${entry.repo}`) return null;
  if (identity.number !== entry.number) return null;
  if (identity.head !== entry.head) return null;
  if (identity.incarnation !== incarnation) return null;
  if (!REQUEST_ID.test(identity.request)) return null;
  return identity;
}

// armedIdentity <fields> <entry> <expected-meta> -> {incarnation} | null
//
// The one eligibility test for a task record, shared by the latch, the delivery
// re-check, and marker pruning, so all three read the record the same way. It is
// deliberately independent of the adapter's gate: this is the posture the WAKE is
// delivered under, read from the record as it is now. A record that is not a
// ship of mode no-mistakes/direct-PR, is yolo=off, has been re-pointed at another
// pull request or head, or cannot prove its own incarnation never authorizes a
// wake.
function armedIdentity(fields, entry, expectedMeta) {
  if (entry.meta !== expectedMeta) return null;
  const kind = fields.get("kind") ?? "";
  const mode = fields.get("mode") ?? "";
  if (kind === "secondmate" || mode === "secondmate") return null;
  if (!READINESS_MODES.has(mode)) return null;
  if ((fields.get("yolo") ?? "") !== "on") return null;
  if ((fields.get("pr") ?? "") !== entry.pr) return null;
  if ((fields.get("pr_head") ?? "") !== entry.head) return null;
  const incarnation = fields.get("spawn_gen") ?? "";
  if (!INCARNATION.test(incarnation)) return null;
  return { incarnation };
}

// currentArmed <ctx> <entry> -> {incarnation} | null
//
// This task's current posture, from its own record under this home's state
// directory. Anything other than exactly <stateDir>/<id>.meta is refused, so the
// seam can never be pointed at another path by its caller.
function currentArmed(ctx, entry) {
  if (typeof entry.id !== "string" || !TASK_ID.test(entry.id)) return null;
  if (typeof ctx.stateDir !== "string" || !path.isAbsolute(ctx.stateDir)) return null;
  const expectedMeta = path.join(ctx.stateDir, `${entry.id}.meta`);
  if (entry.meta !== expectedMeta) return null;
  const text = privateText(expectedMeta, MAX_RECORD_BYTES);
  if (text === null) return null;
  const fields = recordFields(text);
  if (fields === null) return null;
  return armedIdentity(fields, entry, expectedMeta);
}

// witnessOf <ctx> -> request id | null
//
// A consult with no usable host request id cannot prove anything about delivery,
// so it neither reads nor writes a marker and every answer it gives is a possible
// duplicate. In a real host the id is always present.
function witnessOf(ctx) {
  return typeof ctx.requestId === "string" && REQUEST_ID.test(ctx.requestId) ? ctx.requestId : null;
}

// publishMarker <ctx> <entry> <incarnation> <request> -> boolean
//
// Atomic publication: one 0600 temp file in the same directory, fsynced, then
// renamed over the marker, then the directory fsynced, then the marker read back
// through the same reader the next poll uses. Every failure returns false and
// leaves no partial marker, and the caller answers anyway: a marker that cannot
// be published costs one duplicate wake, never a suppressed one.
function publishMarker(ctx, entry, incarnation, request) {
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
      incarnation,
      PROVIDER,
      entry.host,
      `${entry.owner}/${entry.repo}`,
      entry.number,
      entry.head,
      request,
      String(Math.floor(Date.now() / 1000)),
    ].join("\n") + "\n";
    tmp = path.join(ctx.stateDir, `.fm-fork-pr-green-ready.${process.pid}.${Date.now()}`);
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

// pruneReadinessMarkers <ctx> -> number removed
//
// Fork-owned cleanup, run by the adapter on every poll it makes: a marker is
// dropped unless the task record under this home still names the same canonical
// pull request, head, and incarnation. A task that was torn down, re-pointed at
// another pull request, or replaced by a new incarnation therefore never leaves a
// marker that could suppress a future task or pull request identity. A record
// that is merely unreadable right now is left alone, because a transient read
// failure is not evidence the task is gone, and a reader that cannot confirm the
// identity does not suppress anyway.
//
// The marker filename is the task id, so this only ever touches a file this fork
// wrote. bin/fm-teardown.sh (upstream-owned, and never edited by the fork) drops
// its own per-task artifacts; a marker left behind by a teardown is pruned here on
// the next poll, and fork/bin/fm-pr-green-teardown is the explicit path.
export function pruneReadinessMarkers(ctx) {
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
    let marker = null;
    try {
      const info = fs.lstatSync(file);
      if (!info.isFile() || info.isSymbolicLink()) continue;
      const fields = markerFields(fs.readFileSync(file, "utf8"));
      if (fields !== null) marker = identityOf(fields);
    } catch {
      continue;
    }
    if (marker === null) {
      // An unreadable marker cannot suppress anything; dropping it just keeps the
      // state directory to the shapes this fork understands.
      if (unlinkMarker(file)) removed += 1;
      continue;
    }
    if (markerStale(ctx, marker)) {
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

// markerStale <ctx> <marker> -> boolean
//
// True only when this home's own record proves the marker no longer names a live
// identity: the record is gone, is no longer a readable task record, or no longer
// carries this marker's pull request, head, and incarnation. An unreadable record
// keeps its marker.
function markerStale(ctx, marker) {
  const record = path.join(ctx.stateDir, `${marker.id}.meta`);
  let info;
  try {
    info = fs.lstatSync(record);
  } catch (error) {
    return Boolean(error) && error.code === "ENOENT";
  }
  if (!info.isFile() || info.isSymbolicLink()) return true;
  const text = privateText(record, MAX_RECORD_BYTES);
  if (text === null) return false;
  const fields = recordFields(text);
  if (fields === null) return true;
  const entry = {
    id: marker.id,
    host: marker.host,
    owner: marker.repoPath.slice(0, marker.repoPath.lastIndexOf("/")),
    repo: marker.repoPath.slice(marker.repoPath.lastIndexOf("/") + 1),
    number: marker.number,
    head: marker.head,
    pr: marker.pr,
    meta: record,
  };
  return armedIdentity(fields, entry, record) === null;
}


function advisoryBody(entry, verdict) {
  const scope = verdict.required === 0
    ? "No branch rule requires a check at this base branch."
    : verdict.required === 1
      ? "The single required check has reported at that head."
      : `All ${verdict.required} required checks have reported at that head.`;
  return `PR READINESS (advisory): ${entry.id} ${entry.pr} at head ${verdict.head}. `
    + `Every reported check is green at that head. ${scope} `
    + "This is advisory evidence to look at the pull request, not an approval, a merge, or authority to merge; "
    + "the merge step re-reads every requirement itself.";
}

export function decideWake(entry, ctx) {
  // Silence is the answer to every doubt, including a bug in this module: a
  // throw would be captured as actionable adapter-failure evidence, so the
  // predicate answers null instead of ever leaving that record behind.
  try {
    const witness = witnessOf(ctx);
    // The latch is consulted BEFORE any forge read, and only against the record's
    // own current incarnation: an already-announced head costs one local read and
    // no network, and a marker left by another incarnation of the same task id
    // cannot suppress this one.
    if (witness !== null) {
      const armed = currentArmed(ctx, entry);
      if (armed !== null) {
        const marker = readMarker(ctx, entry, armed.incarnation);
        if (marker !== null && marker.request !== witness) {
          ctx.log(`pr-green: latched ${entry.id}`);
          return null;
        }
      }
    }
    const verdict = evaluate(entry, ctx);
    if (verdict === null) return null;
    // Posture, re-read from the record AFTER the forge reads and immediately
    // before delivery: a yolo=off edit, a re-pointed pull request, a changed
    // head, or a replaced worker during those reads never authorizes a wake.
    const confirmed = currentArmed(ctx, entry);
    if (confirmed === null) {
      ctx.log(`pr-green: not-ready ${entry.id} posture-changed`);
      return null;
    }
    if (witness !== null && !publishMarker(ctx, entry, confirmed.incarnation, witness)) {
      // Duplicate direction on purpose: no marker means the next poll answers
      // again, which is the only failure this capability may ever make.
      ctx.log(`pr-green: latch-unpublished ${entry.id}`);
    }
    return { advisory: advisoryBody(entry, verdict) };
  } catch (error) {
    try {
      ctx.log(`pr-green: not-ready ${entry.id} evaluation-failed`);
    } catch {
      // A logger that fails must not change the verdict either.
    }
    return null;
  }
}
