# Audit brief template

## Audit objective

Audit the example project's POST /session/refresh endpoint and its authentication dependencies to establish, with high confidence, whether authorization enforcement and token-lifetime validation are correct before declaring the area clean.

## Threat model or defect class

Investigate missing or bypassable authorization checks and token-lifetime defects, particularly acceptance of expired refresh tokens. Determine whether the endpoint correctly authenticates requests, validates token expiration and other applicable claims, enforces the intended authorization policy, and rejects invalid or unauthorized refresh attempts. A clean verdict requires evidence from the relevant implementation, dependencies, and tests or reproducible traces; absence of an obvious defect in the endpoint handler alone is insufficient.

## Entry points and initial scope - this list is never a whitelist

- Files and slices: Initially unidentified. Begin with bounded reconnaissance to locate the POST /session/refresh route, its handler, and the smallest set of authentication or token-validation interfaces directly involved. Establish exact file paths, symbols, and line ranges before deep inspection.
- Navigation maps and indexes already available: Inspect existing repository navigation maps, indexes, and project documentation for relevant route, authentication, and token-validation references. Record available paths; do not build new maps during reconnaissance.
- Invariants to verify:
  - Only requests satisfying the intended authentication and authorization policy may refresh a session. Locate the authoritative policy definition.
  - Expired refresh tokens must be rejected. Locate the token-expiration policy and the implementation enforcing it.
  - Token validation must enforce all applicable lifetime constraints and relevant claims. Establish these constraints from the repository's implementation, configuration, and documentation.
  - Refresh behavior must not bypass security checks through alternate routes, shared helpers, middleware ordering, or inconsistent validation paths.
  - Any new session or token issued by a successful refresh must comply with the intended lifetime and authorization policies.
- Dependencies to establish: Route registration, middleware and authentication guards, refresh-handler callers, token parsing and verification functions, signing and verification configuration, expiration and clock-handling logic, shared session state, token revocation or rotation mechanisms if present, relevant configuration, and tests covering refresh behavior.

## Bounded initial reconnaissance

1. Identify the repository structure and inspect existing navigation maps, indexes, route-registration files, and relevant interface or section headers.
2. Search for POST /session/refresh, /session/refresh, and equivalent route declarations to locate the actual entry point and any aliases.
3. Identify the handler and directly referenced authentication, authorization, and token-validation interfaces. Read signatures and surrounding declarations before expanding into implementation bodies.
4. Locate existing tests and configuration references specifically concerning refresh tokens, expiration, authentication middleware, and session renewal.
5. Record the initial scope as exact path:symbol or path:line-range references, including the reason each item is necessary.
6. Stop reconnaissance when the route, its direct security boundaries, and the next relevant implementation dependencies are identified. Begin targeted inspection at that point.

Do not infer that the endpoint is secure or insecure during reconnaissance. A previous review suspected that expired tokens were accepted; treat this only as a lead to verify independently.

## Reading budget — effort guidance, never a hard limit

- Reconnaissance: Approximately 15% of the effort, focused on identifying the endpoint, security boundaries, and direct dependencies.
- Targeted inspection: Approximately 70% of the effort, covering the handler, token-validation implementation, relevant authorization policy, configuration, and the dependency closure required to establish behavior.
- Expansion: Approximately 15% initially reserved for following credible leads into additional callers, shared helpers, alternate routes, tests, and security-sensitive state. Expand further whenever evidence warrants it, regardless of the initial allocation.

A budget shapes effort, never verdicts. Following credible defect evidence beyond the budget is required when necessary to establish the result.

## Expansion triggers — any one of these requires broader inspection

- A finding depends on behavior outside the initial scope.
- An authorization, expiration, or token-lifetime invariant is defined elsewhere.
- Callers, consumers, configuration, middleware ordering, or shared state affect the result.
- Evidence conflicts across files, tests, configuration, or documentation.
- A required authentication, authorization, token-validation, revocation, rotation, or integrity check cannot be located.
- An assumption about token-library behavior, expiration enforcement, clock handling, or external middleware cannot be verified with a cited line.
- The endpoint delegates security decisions to shared helpers whose behavior has not been inspected.
- An alternate route or code path can issue, accept, renew, or invalidate the same class of tokens.
- Tests appear to establish security behavior without exercising the relevant boundary conditions.
- A suspected defect depends on a default configuration, omitted claim, optional validation flag, or error-handling branch that has not been verified.

For each expansion, record the newly inspected path or symbol, the evidence that triggered expansion, and what the inspection established. The initial scope is an entry point, never a whitelist.

## Verification required

For each suspected defect, establish the actual behavior from implementation evidence and, where feasible, a focused test, reproducible request, or execution trace. Cite exact file and line ranges for the security-relevant behavior and the assumptions on which the conclusion depends. Do not report a finding from an excerpt alone.

Answer these specific questions:

1. **Route and authorization**
   
   - Where is POST /session/refresh registered, and which middleware or guards execute before the handler?
   - What authentication and authorization requirements apply to the endpoint?
   - Can an unauthenticated request, an invalid token, or a token belonging to an unauthorized principal reach a successful refresh path?
   - Are there alternate routes or handler paths that bypass the same checks?
2. **Expiration enforcement**
   
   - Where is the refresh token's expiration established, parsed, and validated?
   - Does the validation path reject tokens that are expired at request time?
   - Is expiration enforcement mandatory, or can configuration, library defaults, optional claims, error handling, or a fallback path bypass it?
   - Does the implementation use a consistent time source and handle relevant boundary conditions correctly?
   - Can a token that expired before the request still obtain a valid new session or token?
3. **Other token-lifetime constraints**
   
   - What maximum lifetime, not-before, issued-at, absolute-session-expiry, or other temporal constraints are actually required by the repository's policy?
   - Which of those constraints are enforced, and where?
   - Can refreshing extend a session beyond an intended absolute lifetime or otherwise renew credentials that should no longer be valid?
   - Are signing, issuer, audience, token-type, or equivalent claims validated where required by the implementation's security model?
4. **Refresh state and integrity**
   
   - If the system implements refresh-token rotation, revocation, replay prevention, or server-side session tracking, are these checks enforced consistently?
   - Can concurrent requests, stale shared state, or an error-handling path bypass the intended controls?
   - Do successful refreshes issue credentials with the intended claims and lifetime?
5. **Evidence and confidence**
   
   - Which tests cover valid, invalid, expired, boundary-expired, revoked, or otherwise unauthorized refresh attempts?
   - Which important cases are untested or cannot be verified?
   - Does the evidence establish the behavior conclusively, or does a missing dependency, external behavior, or runtime configuration leave the result unresolved?

For every finding:

- State the violated invariant and the concrete security impact.
- Cite the implementation and relevant policy or configuration using exact path:line-range references.
- Provide a reproduction, focused test, or execution trace demonstrating the behavior where feasible.
- Cite the surrounding implementation lines that establish why the behavior is incorrect.
- Distinguish confirmed defects from plausible risks and unresolved assumptions.
- Recommend the smallest appropriate corrective action without claiming it has been implemented or verified.

If execution or tests are unavailable, explicitly state the verification limitation and provide the strongest source-based trace available. Do not substitute assumptions for evidence.

## Carry-forward discipline

- Every subsequent turn and status update must carry current conclusions, unresolved questions, exact file-and-line citations, and the next investigation steps—not accumulated history.
- Preserve raw evidence in repository files or logs and refer to it by path instead of pasting it.
- Include only the excerpts needed for the current decision.
- Never re-paste complete source files, verbose tool output, prior reports, this brief, or unchanged background.
- Preserve every observation needed to reproduce or challenge a finding, including relevant test commands, results, configuration assumptions, and execution traces.
- Update the carried-forward state whenever a finding is confirmed, disproved, or materially revised.
- Do not repeat the suspected expired-token defect as established fact unless the evidence confirms it.

## Stop conditions

Stop only when:

1. The route, authorization boundary, token-validation implementation, and relevant dependency closure have been inspected.
2. The authorization and token-lifetime defect checklist has been exhausted against the repository's actual security policy.
3. Each credible finding has been verified by a reproduction, focused test, or sufficiently complete source trace with cited supporting lines.
4. Every expansion trigger has been resolved with cited evidence or explicitly recorded as unresolved.
5. Relevant tests and configuration have been examined sufficiently to support the verdict.
6. The report includes a scope-sufficiency statement and identifies any remaining limitations that prevent a clean verdict.

If a required dependency, runtime behavior, or policy cannot be verified, report the limitation explicitly and do not declare the affected area clean.

"Looks clean here" is never a valid stop condition while a credible investigation lead remains open. Fewer findings are not a win; judge the audit by whether it missed defects, not by how little it inspected.

## Report requirements

Deliver a concise, evidence-backed report with the following sections:

1. **Verdict**
   
   - Choose CLEAN, DEFECT FOUND, or INCONCLUSIVE.
   - State the confidence level and the principal evidence supporting the verdict.
   - Use CLEAN only when the required checks are verified and no material investigation lead remains unresolved.
2. **Findings**
   
   - For each finding, include severity, violated invariant, concrete impact, exact path:line-range citations, and reproduction or verification evidence.
   - Separate confirmed defects, plausible risks, and unresolved questions.
   - If no defects are found, state that explicitly and cite the evidence supporting the conclusion.
3. **Authorization and token-lifetime checklist**
   
   - Summarize the evidence for route protection, authorization enforcement, expired-token rejection, applicable temporal claims, session-lifetime constraints, and relevant refresh-state controls.
   - Mark each item VERIFIED, DEFECT, UNRESOLVED, or NOT APPLICABLE, with a brief rationale and citations.
4. **Scope-expansion log**
   
   - Record every addition beyond the initial scope, why it was necessary, the paths or symbols inspected, and what the evidence established.
   - If no expansion occurred, state None and explain why the initial scope was sufficient.
5. **Verification record**
   
   - List the tests, commands, reproductions, and traces performed, their results, and the assumptions they confirmed.
   - Identify unexecuted tests and external behaviors that could not be verified.
6. **Scope sufficiency and remaining leads**
   
   - State whether the inspected scope is sufficient to support the verdict, with cited evidence.
   - List unresolved investigation leads and the next concrete steps, or explicitly state None when no credible leads remain.
7. **Carry-forward state**
   
   - Record current conclusions, unresolved questions, exact file-and-line citations, and the next investigation steps.
   - Keep this section compact and suitable for the next audit turn without reproducing prior history.
