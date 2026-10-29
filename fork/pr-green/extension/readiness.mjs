// The readiness seam of the fork PR readiness adapter (process-event-adapter/1).
//
// This module is the WHOLE of the adapter's judgment, and it is deliberately
// empty in slice T1. It is the one place later slices fill in, so that no part
// of the readiness test, the per-head latch, or the wake body can appear
// anywhere else in the package.
//
// decideWake(entry, ctx)
//   entry  one armed task that already passed the adapter's eligibility gate:
//          {id, pr, host, owner, repo, number, head, mode, yolo, kind, meta}.
//          Only GitHub pull requests reach this function; GitLab,
//          Forgejo, Gerrit, local-only, yolo=off, and secondmate records are
//          refused before the call, so a change to this module cannot widen
//          which tasks can wake firstmate.
//          The gate reads state/<id>.meta and the armed merge poll's
//          state/<id>.check.sh sidecar; both are owned by upstream tasks and
//          are never written here.
//   ctx    {home, stateDir, configDir, now, log}: absolute paths resolved from
//          the registration's config_ref, the current epoch milliseconds, and
//          a stderr logger the host captures and discards.
//   returns null, which is silence, or {advisory: "<wake body>"}.
//
// The contract a later slice must satisfy here, stated once:
//
//   Predicate    return a wake only when every required check for that pull
//                request has reported a passing conclusion at exactly the
//                recorded head (entry.head), read from the provider's own
//                answer. A missing required check, an unreadable or failed
//                read, a stale or inconsistent head, an unclear or unknown
//                conclusion, or any doubt at all returns null. Silence is the
//                default, never a claim of green.
//   Latch        at most one wake per pull request per head. The marker is
//                durable state that this module owns, under
//                <home>/state/pr-green/. An interrupted or failed marker write
//                must fail toward one possible duplicate wake, never toward a
//                permanently suppressed one, because a duplicate wake costs an
//                extra merge-time re-read while a lost wake costs the whole
//                capability.
//   Body         the advisory text firstmate reads. It names the task, the
//                pull request URL, and the head it is talking about, and it
//                says plainly that it is advisory evidence - never an approval,
//                a merge, or authority to merge.
//   Errors       returning null is silence and is always safe. The adapter
//                treats an empty, non-string, or oversized body as silence,
//                so every body must be a bounded string that survives JSON
//                encoding. A throw is NOT silence: the adapter answers with an
//                unavailable error, which core captures as an actionable
//                adapter-failure record. Either way no failure path can ever be
//                read as green.
//
// Nothing in this module, before or after a later slice fills it in, may merge,
// arm a merge, write a task record, or record approval or merge authority.
// bin/fm-pr-merge.sh remains the only merge authority and re-validates every
// required check at merge time, so a divergence between this seam and that gate
// can cost a wasted wake or a missed one and never a bad merge.
//
// eslint-disable-next-line no-unused-vars
export function decideWake(entry, ctx) {
  // Slice T1: no readiness predicate is installed yet, so the adapter is silent
  // for every eligible pull request. Later slices replace this body.
  return null;
}
