
## Common gate decision table

A gate kind that has already recurred follows this lookup instead of being reasoned out again:

| Gate kind | Default action |
| --- | --- |
| Ask-user finding on a docs/prose-only change reporting no live-validatable surface | Approve without live validation, with the finding decision per `ask-user-authority` |
| A required CI check cancelled by the provider without a verdict | Re-run that single job on a fresh runner, and never count the cancellation as a pass |
| A job or test step cut off by its own time budget from provider slowness or an outage | Re-run that one step or job, not the whole run |

A gate matching no row falls back to the existing gate flow in this file.
