// The readiness seam of the fork PR readiness adapter (process-event-adapter/1).
//
// This module is the WHOLE of the adapter's judgment. Slice T1 shipped it empty;
// this slice installs the conservative GitHub readiness predicate in it, so no
// other part of the package can quietly acquire an opinion about a pull request.
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
//          The gate reads state/<id>.meta and the armed merge poll's
//          state/<id>.check.sh sidecar; both are owned by upstream tasks and
//          are never written here.
//   ctx    {home, stateDir, configDir, now, log}: absolute paths resolved from
//          the registration's config_ref, the current epoch milliseconds, and
//          a stderr logger the host captures and discards. One ctx per poll,
//          shared by every entry that poll evaluates, so the read budget below
//          bounds the whole poll rather than each pull request in it.
//   returns null, which is silence, or {advisory: "<wake body>"}.
//
// The predicate. A wake is produced only when every one of these holds:
//
//   open       the live pull request state is OPEN and isDraft is exactly false;
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
//
// Silence is the answer to every other outcome: a lookup failure, a timeout, an
// incomplete or malformed response, an unparsable document, an unreadable
// required-context source, a partially successful read, an unknown
// __typename, or any doubt at all. A green-looking rollup beside an unreadable
// required-context source is silence, never green: no input can be partly
// missing and still be green. This predicate re-expresses only what an advisory
// verdict needs, from bin/fm-pr-merge.sh's documented semantics; it never calls
// the merge command, so a divergence can cost a wasted wake or a missed one and
// never a bad merge.
//
// Cost. The common not-ready case costs exactly one forge read (the initial
// pull request view). The required-context reads, and the check-run producer
// read a bound requirement needs, happen only after the initial read already
// looks fully green and at the recorded head. Every read of one poll shares one
// bounded budget (READ_BUDGET_MS, well inside the binding's 300-second default
// invoke timeout) and one per-read timeout, so a slow forge produces silence
// inside that budget rather than outliving it no matter how many tasks the poll
// has to evaluate. state/pr-green/read-budget-ms may shorten the budget for
// tests or a slow host; it can never lengthen it.
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
// The contract this seam keeps, plus the one obligation a later slice fills in:
//
//   Latch        owed by a later slice: at most one wake per pull request per
//                head. The marker is durable state under <home>/state/pr-green/.
//                An interrupted or failed marker write must fail toward one
//                possible duplicate wake, never toward a permanently suppressed
//                one, because a duplicate wake costs an extra merge-time re-read
//                while a lost wake costs the whole capability.
//   Body         the advisory text firstmate reads. This slice produces it,
//                and it names the task, the pull request URL, and the head it
//                is talking about, and it says plainly that it is advisory
//                evidence - never an approval, a merge, or authority to merge.
//   Errors       this slice keeps this too: returning null is silence and is
//                always safe. The adapter treats an empty, non-string, or
//                oversized body as silence, so every body must be a bounded
//                string that survives JSON encoding. A throw is NOT silence:
//                the adapter answers with an unavailable error, which core
//                captures as an actionable adapter-failure record. Either way
//                no failure path can ever be read as green.
//
// Nothing in this module may merge, arm a merge, write a task record, or record
// approval or merge authority. It is a pure reader of the forge and this home's
// task records. bin/fm-pr-merge.sh remains the only merge authority and
// re-validates every required check at merge time.

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

const HEAD = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
// The merge gate accepts a supersession timestamp only when it is a whole-second
// UTC instant, so a timestamp of any other shape can never make a stale run
// disappear.
const SETTLED_AT = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;
const GREEN_CONCLUSIONS = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);
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

// The deadline belongs to the poll, not to the pull request: every decideWake
// call that shares one ctx shares one budget, so N eligible tasks cost at most
// READ_BUDGET_MS in total instead of N times it.
const readDeadlines = new WeakMap();

// readDeadline <ctx> -> epoch milliseconds
function readDeadline(ctx) {
  let deadline = readDeadlines.get(ctx);
  if (deadline === undefined) {
    deadline = Date.now() + readBudgetMs(ctx);
    readDeadlines.set(ctx, deadline);
  }
  return deadline;
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
  const deadline = readDeadline(ctx);
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
        "state,isDraft,headRefOid,baseRefName,statusCheckRollup",
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
  return { head, base, required: required.length };
}

// advisoryBody <entry> <verdict> -> bounded advisory text
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
    const verdict = evaluate(entry, ctx);
    return verdict === null ? null : { advisory: advisoryBody(entry, verdict) };
  } catch (error) {
    try {
      ctx.log(`pr-green: not-ready ${entry.id} evaluation-failed`);
    } catch {
      // A logger that fails must not change the verdict either.
    }
    return null;
  }
}
