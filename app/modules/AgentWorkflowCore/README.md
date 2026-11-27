# AgentWorkflowCore

Provider-neutral workflow and policy layer for local agent orchestration.

## Invariants

- Every ticket has one non-writing coordinator.
- Every branch run has exactly one implementer and one reviewer.
- The reviewer has no workspace-write or test-execution capability.
- A review is bound to the tested diff hash.
- A branch gets at most two automated review cycles.
- Commit, push, and draft pull request actions require a diff-bound human approval.
- Workflow events are append-only.

## Products

- `AgentWorkflowCore`: domain models, state machine, approvals, and SQLite persistence.
- `AgentWorkflowJiraCLI`: read-only Jira ticket lookup through `acli jira workitem view`.

The package deliberately does not launch agents or perform Git and GitHub mutations. Those actions
belong in provider adapters and a privileged action broker in AgentHubCore.

## Orchestrator persistence

SessionMetadataStore owns the ordered selection, claims, attempts, thread links, and transition events. AgentWorkflowStore owns the ticket, branch, review, approval, and workflow event records. Keep the stores linked by stable IDs. An allocation writes a metadata intent, writes the workflow records and receipt, then acknowledges the receipt in metadata. On restart, replay pending intents with the same operation IDs.

Look up acknowledged allocations by run and item before dispatching after a restart. A workflow ID collision proves that the request created no records. Record that rejection, release the claim, and allow a new operation ID. Keep uncertain outcomes pending and continue recovering unrelated operations. The recovery result identifies which requests still need attention.

Use the provider's pending launch ID to identify a thread. Bind a real session after the provider identifies it. Thread closure, review evidence, tracker state, and live activity are independent. Closing a thread does not stop its process.

### Run transitions

| Current state | Event | Next state |
| --- | --- | --- |
| Draft | Start | Running |
| Running | Pause | Pausing |
| Pausing | Confirm a safe pause | Paused |
| Paused | Reconcile and resume | Running |
| Draft, running, pausing, paused | Stop | Stopping |
| Stopping | Confirm outstanding dispatch has stopped | Stopped |
| Running, paused | Confirm every selected item is terminal | Completed |
| Draft, running, pausing, paused | Confirm providers or queue scope for an older saved run | Same state |
| Draft, running, pausing, paused, stopping | Record or clear a run-wide blocker | Same state |

Attention includes item flags and durable run-wide blockers. Existing work can stay active while a run-wide blocker stops new dispatch. The run retains its confirmed providers and project or sprint across restarts. Older saved runs require explicit confirmation of missing settings before dispatch can resume.

### Item transitions

| Current state | Event | Next state |
| --- | --- | --- |
| Queued | Block | Blocked |
| Blocked | Verify eligibility | Queued |
| Queued, blocked, failed, cancelled | Record prerequisite evidence | Same state |
| Queued | Reserve a verified dispatch | Launching |
| Launching, running | Require launch reconciliation | Reconciling |
| Launching, reconciling | Identify the current provider session | Running |
| Cancelling | Identify the current provider session | Cancelling |
| Running | Hand off for review | Awaiting review |
| Awaiting review | Confirm completion with evidence | Completed |
| Awaiting review | Explicitly skip review | Skipped |
| Launching, reconciling, running | Confirm the attempt cannot run | Failed |
| Launching, reconciling, running | Request cancellation | Cancelling |
| Cancelling | Confirm cancellation | Cancelled |
| Queued, blocked | Cancel or skip | Cancelled or skipped |
| Failed, cancelled | Reserve a permitted retry | Launching |

Completed, failed, skipped, and cancelled items are terminal. A retry is an explicit exception and takes a new attempt ID. The prior workflow records remain linked. Review holds the issue claim until the item reaches a terminal state. Terminal transitions do not update the remote tracker.

An allocation for a dependent item requires verified prerequisites on its initial base. Each attempt records its own base commit. If the base advances, verify the prerequisites again and dispatch on that base while keeping the original workflow links.
