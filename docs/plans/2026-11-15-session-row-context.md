# TES-282 — useful session rows

Baseline: detached 4858079225a11125f2d922bb44767d1b1bab119b in `workbench-session-rows`. This specification covers only session rows. No app code has changed.

## User-facing behavior

- Show status and title first. Show the local diff size and next action on a secondary line below. Use an adaptive minimum row height and existing typography, spacing, colour and diff tokens. Large numbers use tabular numerals. Absent or empty diff summaries show nothing; a nonempty summary can truthfully show `+0 −0`.
- Show the provider mark for every session in a branch only when that branch contains both providers. Determine this from unpaged branch membership, so Load more does not change the marks. Always include the provider in the VoiceOver label.
- Reuse `SessionAttentionModel.items` for real next actions. Existing approval and answer pills remain separate controls and authoritative; do not repeat their words in the secondary line. If there is no higher-priority reason and a current, non-stale `.ready` snapshot identifies an open PR whose `headRefName` equals the known session branch, show `Review PR #N` or `Review draft #N`. Do not describe a PR as ready, or infer readiness from CI, missing data or unknown states. No current PR, unavailable or stale observation, or closed/merged PR produces no PR action.
- A dot means `Unread updates`: observed session activity newer than the acknowledged activity, not necessarily a new message. Include status, action, provider, and unread state in the accessible row label.
- Keep the existing button, selection, focus and arrow-key behavior, context menu, hover preview, workflow role and Approve/Answer button routes. Keep guide-line alignment correct for variable-height rows, using the Shape path bounds where needed. Do not use geometry-to-state feedback, scale-on-hover, or new polling.

## Durable unread state

- Add a `SessionReadCursorStoreProtocol` and an additive `v20_create_session_read_cursors` migration at the end of `SessionMetadataStore`'s identifiers and migrator. Store `provider`, `sessionId`, and `lastReadActivityAt`, with a composite provider/session key. No existing migration changes. Implement atomic monotonic upsert: an older write can never replace a newer timestamp.
- Add a provider-owned `@MainActor @Observable` read-cursor model. It loads markers once and merges loaded values with the in-memory maximum, including when a load and acknowledgement overlap. Use the protocol for tests. A failed write must remain eligible for retry; avoid duplicate writes for an unchanged durable cursor.
- After a successful cursor load, a loaded, non-pending session with observed activity and no marker is unread. Pending or failed cursor loads are unknown and never manufacture dots. It is unread when activity is strictly later than the marker. Nil activity is unknown and does not create a dot. Use observed activity as the cursor, not the wall clock.
- Drive acknowledgement from actual visible session detail, not sidebar selection or hover. The driver belongs on `SessionDetailView`, so hiding the sidebar does not stop it. Require the Sessions destination and the actual displayed detail; do not acknowledge while Reviews, a module landing, comparison, or another destination replaces it. For ordinary detail use the displayed primary session only when there is no selected workspace. For workspace detail use the selected workspace's live decoded snapshot. Validate both the active panel and active tab indices before using `activeLinkedSession`; its built-in fallback can otherwise select the wrong tab. Resolve its provider and session ID to a monitored item. Do not use `lastWorkspaceOpen` alone as evidence. Observe destination, actual detail selection, workspace snapshot and activity. While visible, newer observed activity advances its cursor. Opening or returning acknowledges the then-visible activity. All windows share the provider-owned model.
- `AgentWorkspacesViewModel.handleWorkspaceChanged` updates the observable workspace snapshot. Read `AccessorySessions.md` before any workspace-facing edits. Invalid, missing, hidden or unlinked workspace tabs must not clear unread state.

## Diff loading and shared observations

- `CLISessionsViewModel.localDiffSummary(for:)` already supplies local worktree summaries, and `LocalDiffSummaryService` already caches, deduplicates in-flight work and throttles invalidation. Summaries are normally loaded by open cards, so sidebar rows need bounded loading.
- Use one sidebar-level activity-driven driver, not a task or polling loop per row. Its inputs are displayed paged session rows after collapsed repositories are excluded. Normalize and deduplicate worktree paths across providers. Limit concurrent evaluations (at most two); cancel queued work on input changes and disappearance. Load with `ensureLocalDiffSummary(for:)`. For newer observed activity on a displayed path, coalesce and invoke the existing throttled `forceRefresh` path once. Make results available to both providers sharing a path through the shared cache and their view models. Missing summaries stay absent.
- Reuse `SessionAttentionModel.snapshots`, which receives shared GitHub observations from `SidebarCIFailureDriver`, keyed by row item ID. Its matching logic protects the current project path and branch. Add no subscription or polling loop.

## Owned files

- `Services/SessionMetadataStore.swift` and a narrow read-cursor protocol/model file: additive migration, storage and monotonic writes.
- `Configuration/AgentHubProvider.swift`: shared read-cursor model.
- `Shell/Session/SessionDetailView.swift` and a focused adjacent helper if needed: actual detail visibility and acknowledgement.
- `Shell/Sidebar/SidebarTreeRows.swift`, `SessionTreeView.swift`, `SessionTreeRow.swift`, and focused helpers as needed: presentation projection, provider grouping, bounded diff loading and accessible row layout.
- `Tests/AgentHubTests/SessionMetadataMigrationSafetyTests.swift`, `SidebarTreeRowsTests.swift`, and focused new cursor, visibility, row-presentation and diff-loading suites.

## Verification

Write focused tests that first establish the missing behavior, then pass after implementation. Cover:

1. Migration from the complete current baseline: seed existing workspace and v19 result records, open the migrated database, and verify the records survive. Check cursor round-trip, provider isolation, monotonic writes and restart persistence. Update the last-migration assertion.
2. Unread: no marker after successful load, pending/failed loads, nil activity, equal/newer/older activity, repeated acknowledgements, overlapping load/write, out-of-order completions, store failure and retry. Exercise actual primary and workspace visibility, hidden tabs, invalid active panel or tab indices, destination changes, comparison, hover, missing snapshots and multiple windows.
3. Diff loading: visible paged rows only, collapsed exclusion, path deduplication across providers, concurrency bound, coalesced activity refresh and cancellation; nil and empty summaries do not render as zero.
4. Presentation: mixed-provider branches including unloaded pages, long titles and large counts, status and action precedence, all PR states including missing/stale snapshots and a same-repository linked PR from a different head branch, and accessible labels. Existing attention pills remain independent controls.
5. Run the affected `AgentHubCore-Tests` suites with the repository's `xcodebuild` targeted-test command, plus repo lint and relevant shell checks. Root owns native builds and tests. Check the running native app at normal and narrow widths with keyboard, VoiceOver, context menu, hover and both attention pills.

Root independently verifies this contract before implementation begins.

## Visibility and persistence clarifications

A read acknowledgement requires an active native window and the currently displayed session. Revalidate cancellation, destination, session and activity after any awaited cursor load. A scene being active alone is not proof that its window has focus. A background or inactive window must not silently clear updates.

Round-trip sub-millisecond activity without creating a false unread update after restart. If storage requires canonical precision, apply that precision consistently to storage and comparisons. Existing migrations remain unchanged.

Use exact PR branch/current-snapshot checks for check-derived attention reasons as well as the fallback PR action. Diff help and accessible wording identify worktree changes; two sessions sharing a worktree share those counts.
