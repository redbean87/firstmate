# Live-validation evidence: skill-policy change (fm/fm-decisionmap-c1)

Change under test: two agent skill Markdown files only.

## Diff base..target

```diff
diff --git a/.agents/skills/captain-hold-lifecycle/SKILL.md b/.agents/skills/captain-hold-lifecycle/SKILL.md
index 438f6353..59709e8e 100644
--- a/.agents/skills/captain-hold-lifecycle/SKILL.md
+++ b/.agents/skills/captain-hold-lifecycle/SKILL.md
@@ -21,6 +21,9 @@ For a Lavish board-backed handoff, pass the reply through `bin/fm-procevent-lavi
 Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
 The originating investigation or review is never its own inventory entry, so hold a separate task for the call and pass `--origin <origin-id>` so `complete` can check it.
 Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
+The inventory is fog-of-war bounded: hold a task only for a question the surface sharpens enough to state precisely now, and the test is whether the question can be stated precisely, not whether it can be answered now.
+A dim follow-up that cannot yet be stated as a question stays in the originating report as a named not-yet-specified line instead of being pre-sliced into a held task; a later pass that sharpens it into a stateable question promotes it to a hold.
+Give every held question a short plain name in its hold reason and refer to the decision by that name in reports, status, and captain chat; the task id remains the durable key, never the way the decision is named to humans.
 Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
 After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain.
 A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
@@ -59,7 +62,7 @@ The absence of a routed work item is not a divergence and the guard never requir
 ## Operating sequence
 
 1. Read the complete investigation result and complete the visual review before declaring either complete.
-2. Inventory only genuine unresolved choices that require the captain, and find the task each one gates.
+2. Inventory only genuine unresolved choices that require the captain and can be stated precisely now, and find the task each one gates; dim follow-ups stay as named not-yet-specified lines in the originating report.
 3. Hold that task - or create one captain-held task for the review's open questions - with a concise reason carrying the question and options.
 4. Run `complete` with the full captain-held inventory for that review pass.
 5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
diff --git a/.agents/skills/scout-completion/SKILL.md b/.agents/skills/scout-completion/SKILL.md
index de7759e6..9b43e5d7 100644
--- a/.agents/skills/scout-completion/SKILL.md
+++ b/.agents/skills/scout-completion/SKILL.md
@@ -10,6 +10,8 @@ metadata:
 
 A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
 A report may recommend implementation but does not authorize it.
+For an investigation expected to span multiple sessions, deciding is the default deliverable, not building: each session resolves the decisions it can state and names the handoff - what remains to decide and where the next session picks up - and executes none of the planned work unless the brief explicitly says to.
+The fog-of-war boundary between a stateable question and a dim follow-up, and the hold mechanics, live in `captain-hold-lifecycle`.
 Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
 When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
 When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
```

## Deterministic consumer search

No script, test, generated prompt, or config reads the changed body text:

```
$ grep -rn "scout-completion/SKILL\|captain-hold-lifecycle/SKILL" --include=*.sh --include=*.mjs --include=*.py .
./bin/fm-captain-hold.sh:5:# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
./bin/fm-brief.sh:644:Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
./tests/fm-brief.test.sh:961:  assert_grep "$ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md" "$scout" \

$ grep -rn "fog-of-war|not-yet-specified|deciding is the default" (excluding the two changed files)
(no matches)
```

The only deterministic consumer found is bin/fm-brief.sh, which embeds the skill
PATH as a reference for the spawned agent; it does not embed the changed policy body.

## Surrounding deterministic contract still green

```
$ bin/fm-test-run.sh tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
FM_TEST_END ... tests/fm-brief.test.sh exit=0 duration_ms=32178 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=32305
```
