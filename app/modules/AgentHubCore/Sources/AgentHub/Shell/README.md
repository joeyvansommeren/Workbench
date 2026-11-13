# Shell (new interface)

The window root shown when `AgentHubDefaults.appleShellEnabled` is on at launch.
`AgentHubApp` reads the flag once, so the root, menus and window style are fixed
until relaunch. With the flag off, `AgentHubOperationsView` runs unchanged.

## Slots

`ShellFrame(sidebar:toolbar:detail:)` lays out three slots. Each phase replaces
only its own slot:

| Slot | View | Replaced by |
|---|---|---|
| sidebar | `ShellSidebarContainer` (`Sidebar/`: nav rows, session tree, footer) | P5 |
| toolbar | `ShellToolbar` (`SessionsToolbarContent` (P6), `SprintToolbarContent` (P9), titles, search) | P6 tabs, P8, P9 |
| detail | `ShellDetailSlot` (one `case` per destination) | P6 Sessions, P8 Reviews, P9 Sprint |

Per-window state lives in `ShellRoot`: `WorkbenchShellModel`,
`SessionNavigationModel` and `SessionsActionCoordinator` (environment-injected,
never provider singletons). Menu commands reach the key window through
`FocusedValues.workbenchShell`.

## Title bar spike (2026-11-13): Variant B

Measured in an AppKit test host on macOS 27.

- **Variant A (real `NSToolbar` items) failed.** The toolbar gives the right
  chrome (52 pt bar, traffic lights at x 19, y 19), but items do not align with
  the content column: the gaps between items change with state (12, 8, 20 pt), at
  900 pt wide the spacer item jumps before the toggle, and an item with
  `maxWidth: .infinity` stays at its minimum, so P6's tab strip cannot fill.
- **Variant B (chosen).** `.hiddenTitleBar` window (as legacy), no toolbar items,
  safe-area top is 0, and the shell draws its own 52 pt row. Nothing ignores the
  top safe area except backgrounds. `TitleBarDragArea` gives the empty row drag
  and double-click (it honours `AppleActionOnDoubleClick`).
- **Known gap.** Without a toolbar the system title bar is 32 pt, so the traffic
  lights sit at x 9, y 9, not centred in the 52 pt row as in the prototype.
  Moving them needs AppKit frame changes on every layout, which is a layout-loop
  risk, so they stay.

## Layout-loop rules

No `NavigationSplitView`, `HSplitView`, `VSplitView` or `.inspector` in shell
code. No `GeometryReader` widths. The sidebar collapses as a plain `HStack`
child. `ShellLayout.windowMinWidth` is 900: no split view is hosted in the
shell any more, and every destination's content minimum plus the 288 pt
sidebar and the 8 pt panel inset fits it. `ReviewsLayoutTests` (Reviews) and
`SessionTabsModelTests` (Sessions: `SessionDetailLayout`, content 260 + side
panel 320) check it.

## P6: session view (`Shell/Session/`)

- **Tabs.** `SessionTabsModel` is per window (owned by `ShellRoot`, injected
  with `.environment(sessionTabsModel)`). `SessionTabsSync` keeps it in step:
  any `primarySessionId` change (sidebar, palette, router, launch) opens or
  selects a tab, so callers only use `SessionNavigationModel.selectSession`.
  Closing a tab never stops the session. Pending tabs take the resolved id in
  place. Open tabs persist per provider in `session_workspace_state`
  (`v17_add_open_session_tab_ids`, saved through `CLISessionsViewModel`'s
  gated workspace-state write). Tabs whose session goes away are pruned;
  restored ids that never resolved stay hidden.
- **Toolbar.** `SessionsToolbarContent` → `SessionTabStrip`: tabs flex
  120–204 pt, overflow goes to a chevron menu. The strip measures only its own
  width (parent-driven, rounded, stored on change).
- **Detail.** `SessionDetailView`: `SessionHeaderView`, the shared
  `MonitoringCardContentArea` (terminal/chat/files/diffs, also used by the
  legacy card) and `SessionSidePanel` in a `ResizablePanelContainer`
  (400 default, 320–520). Effects run through `SessionCardEffects`, the same
  modifier the legacy card uses. Panels come from `SidePanelContentView`
  (shared with the legacy panel); availability from `SidePanelSegments`.
- **Persistence across windows.** Each provider saves the ordered union of
  every window's tabs (`OpenSessionTabsAggregate`). The first window to ask
  after launch gets the saved tabs (`claimRestoredOpenSessionTabIds`); later
  windows start empty. So no window drops another window's tabs, and a closed
  tab stays saved only while another window has it open. A closed window's
  tabs stay saved until relaunch.
- **Selection.** While nothing is shown (launch, sessions loading), the first
  restored tab is shown, else the newest session; never after the user closed
  every tab this run (`SessionTabsModel.selectionUpkeep`).
- **Parity with the legacy panel.** Edits/Plan auto-open with the legacy rules
  (`SidePanelAutoOpenTracker`), CI-failure "Open GitHub panel" / "Fix CI"
  notification actions (`CIFailureFixAction`, shared), Create PR
  (`CreatePullRequestAction`, shared) and Commit (2 s per-session cooldown).
- **No split views.** The legacy `MultiProviderMonitoringPanelView` is not in
  this path. A workflow comparison opens both sessions as tabs.
  `GitHubPRDetailView` uses a fixed `HStack` when the flag is on.
- **Terminal palette.** With the flag on, `TerminalPaletteResolver` drives the
  SwiftTerm colours (incl. 16 ANSI slots) and the Ghostty overlay from the
  Workbench palette; a palette or appearance switch repaints open terminals.
  Flag off: the legacy rules, unchanged.

## Sidebar (P5)

`Sidebar/` holds the prototype sidebar: `SidebarNavSection` (Reviews and
Sprint with `SidebarNavCounts`), `SessionTreeView` and `SidebarFooter`.

- **Tree.** `SessionTreeProjection` (P3) → `SessionTreeWorkflowMerge` (adds
  tracked repos without sessions and empty rows for manual workflows) →
  `SidebarTreeRows` (one flat list) → a `ScrollView` + `LazyVStack` of
  `Equatable` rows. The projection runs in `SessionTreeContent.body` only;
  selection is read in a child view, so selecting does not re-project.
- **Workflows.** `BranchWorkflowDecorationIndex` adapts
  `AgentWorkflowDashboardViewModel.detectedBranches` (archived ones dropped)
  into branch-row decorations: PR number with CI state, roles, menu actions.
  `WorkflowDiscoveryDriver` runs the dashboard's `load()` 3 s after launch and
  a debounced `refreshDetectedWorkflows()`, since the Workflows view is gone.
- **One entry point to open a session:** `SidebarTreeActions.open(_:)`
  (workspace-owned sessions focus their workspace; others call
  `SessionNavigationModel.selectSession`). P6 makes that open a tab.
- **Approve pill:** `SessionNode.showsApprovePill` (Claude, pending tool use,
  not an input question). The action is the single closure
  `SidebarTreeActions.approve`, now `SidebarApproval.respond` (P7, below).
- **Collapse state** is `SelectedRepository.isExpanded`, persisted in
  `SessionWorkspaceState.expansionState` (SQLite) through
  `CLISessionsViewModel.setRepositoryExpanded(path:isExpanded:)`.
- **Icons** are the prototype's SVG paths (`SidebarIcons.swift`); SF Symbols
  has no pull-request glyph, so use `PullRequestGlyph` (Design/Components).

## P8: Reviews

`ShellDetailSlot` `.reviews` shows `Reviews/ReviewsDestinationView`: a fixed
list (`PullRequestRow`), a hairline and `PullRequestDetailView`, in a plain
`HStack` (widths in `ReviewsLayout`). No split views; the search field sits in the Filters popover
with project and view and never takes focus on appear. The scope (Requested /
Mine / All) is `GitHubReviewsViewModel.reviewScope`, saved in
`AgentHubDefaults.reviewsScope` only when the user picks it (a jump to a
pull request outside the scope widens to All in memory); the "Review with" agent in
`AgentHubDefaults.reviewsAgent`. The queue carries no CI data, so a row shows
its checks icon once its detail has loaded (`checksByPullRequestID`).
Breadcrumbs: `reviews scope: <x>`, `reviews pr: <repo>#<n>`, `reviews filters:
open`, `reviews agent`, `reviews start review`, `reviews open session`.
The legacy `GitHubReviewsView` is unchanged for the flag-off path.

## P9: Sprint

`.sprint` shows `SprintDestinationView` (`Jira/`), toolbar `SprintToolbarContent`
(`Sprint/`): the sprint or cycle name and a days-left chip ("Sprint" when Linear
has no active cycle). As in the prototype, Jira | Linear, All | Mine and Filters
sit in the board's list head, not the toolbar. Jira and Linear map to the
tracker-neutral `SprintColumnItem`s (`Sprint/SprintBoardItems.swift`), drawn by
`SprintBoardView`: up to 4 equal columns, more scroll sideways with
`containerRelativeFrame`; no GeometryReader. The ticket detail is a 380 pt
trailing panel in a plain HStack (not `.inspector`); it still hosts the legacy
`JiraTicketDetailView` / `LinearIssueDetailView`. With no saved tracker, Sprint
opens on Jira when `acli` is installed, else Linear. Breadcrumbs:
`sprint tracker: …`, `sprint filter: …`, `sprint ticket: open|close|start …`.

## P7: Approvals (Claude only)

Approve and Deny work in the app. There is no programmatic channel (the hook
only observes, no hook changes), so the answer is a keystroke into the agent
tab, behind `ApprovalResponding` (`Services/ApprovalResponder.swift`).

- **One path:** `CLISessionsViewModel.respondToApproval(sessionId:decision:)`
  serves the banner, the tree pill, the chat `onApprove` and voice. Allow once
  types "1"; "Always allow" types "2"; Deny sends Escape (the "No" number is
  not stable across tools).
- **Fail closed.** It only types when the pending tool use is approvable
  (`PendingToolUse.isApprovablePermission`: Claude, not an input question), and:
  on a text backend (`canReadAgentScreen`, SwiftTerm) the live screen tail
  shows Claude's menu (`ClaudePermissionMenu`; wording pinned in the test
  fixture `ClaudePermissionMenuFixtures`). A scrolled-back tab is refused,
  never sent to the sidecar check. On backends without screen text (Ghostty)
  the sidecar's open `pending` line must carry this tool use id. "Always allow"
  also needs option 2 to read "Yes" on screen, so it is refused on Ghostty.
  Otherwise: "Answer in the terminal".
- **One key per request.** The hook writes `resolved` only after the tool
  finishes, so an approved, running tool still looks pending. Once a key went
  out for an `ApprovalRequestKey` (tool use id, plus the timestamp when the id
  is empty or synthetic), the view model refuses more (`.alreadyAnswered`) and
  the banner shows no Approve/Deny buttons for it.
- **Progress.** `ApprovalResponseTracker` (on the view model): `sending`, then
  `answered` once the screen no longer shows the menu (polled for 3 s), or
  `checkTerminal` ("Sent. Check the terminal.") when it can't confirm. A
  refusal (`answerInTerminal`) keeps the buttons for a retry. Banner and pill
  share it.
- **Banner** (`Session/ApprovalBanner.swift`): an overlay on the terminal
  content in `SessionDetailView`, never a sibling, so the PTY never resizes.
  "Show in terminal" swaps it for a top-corner "Show approval" chip.
- **⌘↩.** The terminal's key monitor eats ⌘↩ (newline or submit). While the
  banner shows, the surface's `approvalShortcutHandler` is set and
  `ApprovalShortcutRouting` sends ⌘↩ to Approve, on both backends; without a
  banner, nothing changes for any `NewlineShortcut`. When the terminal is not
  first responder, the Approve button's own ⌘↩ shortcut handles it.
- **Tree:** Approve pill (spinner while sending; on refusal it opens the
  session) and an Answer pill for input questions, which only opens the session.
- Breadcrumbs: `approval: shown|approve|deny <tool>`.

## P10: overlays and settings

`Overlays/` holds the window-level overlays, attached once in `ShellRoot` by
`ShellOverlayHost`:

- **Command palette** (`WorkbenchCommandPalette`, 640 pt) on ⌘K and the toolbar
  Search field. `ShellOverlayModel` (per window, in the environment) owns
  open/closed and logs `palette: open|close`. Rows come from the pure
  `UI/CommandPaletteEntries.swift`. The legacy `CommandPaletteView` is unchanged.
- **New session sheet** (`NewSessionSheet`, 560 pt) on ⌘N, the toolbar "+" and
  the palette. It drives `MultiSessionLaunchViewModel` through
  `NewSessionSheetModel`; `NewSessionTarget` maps New / existing / None to the
  launch. "More options…" hands the same launch view model to the legacy
  launcher. The request lives on the window's `SessionsActionCoordinator`
  (`newSessionSheetRequest`), so any view can open the sheet with
  `ShellSessionActions.startNewSession(preselectedWorktree:)` (branch-row "+").
- **Shortcuts**: `ShellShortcuts.swift` is the one table of key equivalents and
  destination titles; `ShellCommands` binds it and the palette shows it.
- **Appearance**: Settings › Appearance shows System / Light / Dark and
  Standard / Warm when the flag is on (YAML theme picker hidden), applied live
  by `WorkbenchAppearanceController`. The stored appearance is applied when a
  shell window opens.

## P6b: compact side panel Diff

With the flag on, the side panel's Diff segment shows `SidePanelDiffView`
instead of the legacy `GitDiffView`: a flat file list (mono path, +n −m), then
the selected file's hunks at full panel width. Only the code scrolls sideways
(one horizontal `ScrollView` per hunk); tints and line numbers stay put. No
GeometryReader.

- **Data:** `SidePanelDiffModel` lists files with `GitDiffServiceProtocol` and
  fetches the selected file's patch with the new `unifiedPatch(for:…)` (libgit2
  first, git CLI fallback). `SidePanelDiffParser` (pure) turns it into hunks.
- **Mode:** automatic until the user picks one in the compact "Branch ▾" menu.
  Automatic probes `DiffMode` order (branch → staged → unstaged) and takes the
  first mode with changes, because the header diffstat and "Commit N files…"
  count every mode. The legacy `GitDiffView` keeps its own rule.
- **Refresh:** reloads when `localDiffSummary` changes; the selection survives
  by relative path, else the first file.
- **Cap:** 400 lines per file. "Show full diff" (also in the mode menu) expands
  the side panel to the legacy `GitDiffView`; its Close returns to the compact
  view.
- **Keys and breadcrumbs:** ↑/↓ move the selection once the list has focus.
  `side panel diff: file <path>`, `side panel diff: mode <mode>`.
