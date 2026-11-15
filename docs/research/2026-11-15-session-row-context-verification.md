# Session row context: delivery verification

Date: 15 November 2026. Scope: the session-row improvement only. Baseline: `4858079225a11125f2d922bb44767d1b1bab119b` (pull request #36). Feature branch: `codex/session-row-context`; pull request base: `codex/workbench-next-four`.

## Delivered behavior

- Rows keep status and title first, then show available worktree line counts and the next action. Counts use tabular numerals. Missing summaries do not become zero changes; nonempty rename/binary summaries may truthfully have zero line additions/deletions.
- Provider marks appear only when the unpaged branch contains multiple providers. Pagination does not change this decision.
- Unread updates use local SQLite markers keyed by provider and session. A marker acknowledges observed activity, not the current clock. Unknown or failed initial loads do not manufacture dots. Active, visible session detail or a validated active workspace tab acknowledges updates; hover, hidden tabs, Reviews, comparison and module landing views do not. After a delayed load, visibility and cancellation are checked again.
- The additive v20 cursor migration keeps earlier migration bodies unchanged. Monotonic writes preserve the newer marker, and Foundation reference-epoch Double values preserve exact Date comparisons after restart. No prompts, transcript contents or terminal output are stored in the cursor table.
- Displayed worktree paths are deduplicated and use the existing summary cache/throttle. A shared two-slot budget bounds sidebar loads across task replacements. Cancelled queued work starts no evaluation; active shared evaluations finish normally. Reopening the sidebar requests a throttled refresh.
- PR-derived actions require an open, current, non-stale observation with the exact session branch. Typed check provenance prevents display wording from bypassing this guard. Review PR states an action; it does not claim merge readiness or passing checks. Existing row opening, focus, menus, hover preview and request/answer routes remain connected.

Related to TES-282.

## Local checks

- Final affected native batch: **80 total, 80 passed, zero failed, zero skipped**, across ten selected suites. These cover cursors, presentation, loading, sidebar projection, migration preservation, navigation, attention, result storage and native label rendering.
- The exact reference-date persistence case and overlapping replacement-load case fail before the fixes. The same regression assertions pass afterward. The real v19 migration fixture seeds and verifies workspace selections, monitored sessions, expansion state, metadata and a result.
- All six fast packages pass: AgentHubVoice, AgentWorkflowCore, AgentHubCLI, AgentHubGitHub, SimulatorPreview and Storybook. Motion and shell guards pass.
- The complete Debug macOS application builds successfully. Configured dependency SwiftLint reports zero violations in 92-file and 157-file runs. Parsing, new-file formatter checks and changed-file whitespace checks pass; existing surrounding formatter warnings are not removed through unrelated formatting. No separate app-wide lint target exists.
- Full Core gate: **2351 total, 2298 passed, 37 failed, 16 skipped**. The run has timing, timeout and headless failures in other reported suites. Their causes are not all established as pre-existing; no all-green full gate or repair of those failures is claimed. No session-row-focused suite appears in the reported failure list. The full gate runs without a concurrent app build.

## Native evidence and limits

A native fixture renders the actual production SessionTreeRowLabel and existing AttentionPill with synthetic data. It avoids constructing a concrete provider, which would request notification permission for an approval row. Eight raw images cover normal and worst-case data in light/dark appearance. The supported shell width is 288 points (264 after insets); 240 and 400 are diagnostic component widths. At 288, long Unicode titles truncate as designed while full counts, PR actions and pills remain visible. At diagnostic 240, action and role text truncate; that width is not supported by the shell. Native geometry verifies row growth, insets and non-overlap.

The fixture does not instantiate the full row wrapper and does not prove keyboard activation, arrow-key routing, hover, context menus, real window transitions or VoiceOver. The accessible label includes status, next action, worktree counts, provider and unread updates in source. Direct accessibility children are unavailable in the test host. Larger text, RTL and manual accessibility checks remain unverified. Synthetic captures are not user research.

## Standards

No documented-standard violations remain. Typed SessionAttentionCategory.checks resolves the earlier copy-based routing concern. Shared scan budgeting, reference-date persistence, cache refresh and focused tests introduce no additional actionable standards findings in the follow-up review.

Standards findings: **0**. Worst issue: none.

## Spec

All three supported findings return to the original author and pass independent follow-up review: timestamp precision, replacement-scan concurrency and reopening cache refresh. Workspace migration coverage is complete for the seeded records. Typed attention provenance preserves exact-branch/current-observation requirements. No incomplete fixes or supported regressions remain in the reviewed delta.

Spec findings: **0**. Worst issue: none.

## Delivery boundary

The change is published as a draft because the full Core gate is unresolved. No CI success is assumed; CI is checked separately after publication. No installed app is replaced, no PR is merged, and GitHub Actions is not enabled. Native captures remain local because no supported PR image-upload route is available here. Generated builds are removed after evidence is preserved. Managed worktree archival respects active-task and primary-checkout protection.

Implementation files: SessionReadCursor.swift and SessionMetadataStore.swift own the cursor; SessionDetailView.swift owns visibility; SessionTreeRow.swift, SessionTreeView.swift, SidebarTreeRows.swift and SessionAttentionItem.swift own presentation/provenance/loading; AgentHubProvider.swift wires the model.
