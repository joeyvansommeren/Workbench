# Shell (new interface)

The window root shown when `AgentHubDefaults.appleShellEnabled` is on at launch.
`AgentHubApp` reads the flag once, so the root, menus and window style are fixed
until relaunch. With the flag off, `AgentHubOperationsView` runs unchanged.

## Slots

`ShellFrame(sidebar:toolbar:detail:)` lays out three slots. Each phase replaces
only its own slot:

| Slot | View | Replaced by |
|---|---|---|
| sidebar | `ShellSidebarContainer` (`Sidebar/`: session tree, footer) | P5 |
| toolbar | `ShellToolbar` (destination tabs, search, palette, light/dark) | P12 |
| detail | `ShellDetailSlot` (one `case` per destination) | P6 Sessions, P8 Reviews, P9 Jira and Linear |

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
- **Known gap (closed in P12).** Without a toolbar the system title bar is
  32 pt and the traffic lights sit at x 9, y 9. P12 centres them; see below.

## Layout-loop rules

No `NavigationSplitView`, `HSplitView`, `VSplitView` or `.inspector` in shell
code. No `GeometryReader` widths. The sidebar collapses as a plain `HStack`
child. `ShellLayout.windowMinWidth` is 900: no split view is hosted in the
shell any more, and every destination's content minimum plus the 288 pt
sidebar and the 8 pt panel inset fits it. `ReviewsLayoutTests` (Reviews) and
`SessionDetailReviewTests` (Sessions: `SessionDetailLayout`, content 260 + side
panel 320) check it.

## P6: session view (`Shell/Session/`)

Sessions shows the one session selected in the sidebar (the P6 tab strip was
removed in P12; see "P12" for selection and persistence).

- **Detail.** `SessionDetailView`: `SessionHeaderView`, the shared
  `MonitoringCardContentArea` (terminal/chat/files/diffs, also used by the
  legacy card) and `SessionSidePanel` in a `ResizablePanelContainer`
  (400 default, 320–520). Effects run through `SessionCardEffects`, the same
  modifier the legacy card uses. Panels come from `SidePanelContentView`
  (shared with the legacy panel); availability from `SidePanelSegments`.
- **Parity with the legacy panel.** Edits/Plan auto-open with the legacy rules
  (`SidePanelAutoOpenTracker`), CI-failure "Open GitHub panel" / "Fix CI"
  notification actions (`CIFailureFixAction`, shared), Create PR
  (`CreatePullRequestAction`, shared) and Commit (2 s per-session cooldown).
- **No split views.** The legacy `MultiProviderMonitoringPanelView` is not in
  this path. A workflow comparison shows the implementation session.
  `GitHubPRDetailView` uses a fixed `HStack` when the flag is on.
- **Terminal palette.** With the flag on, `TerminalPaletteResolver` drives the
  SwiftTerm colours (incl. 16 ANSI slots) and the Ghostty overlay from the
  Workbench palette; a palette or appearance switch repaints open terminals.
  Flag off: the legacy rules, unchanged.

## Sidebar (P5)

`Sidebar/` holds the prototype sidebar: `SessionTreeView` and `SidebarFooter`.
(The Reviews and Sprint nav rows became tabs in P12.)

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

Since P12, `.jira` shows `JiraDestinationView` and `.linear` shows
`LinearDestinationView` (both in `Jira/SprintDestinationView.swift`). The list
head (`SprintListHead`) shows the sprint or cycle name with its days-left chip
(no title when Linear has no active cycle), All | Mine and Filters. Jira and Linear map to the
tracker-neutral `SprintColumnItem`s (`Sprint/SprintBoardItems.swift`), drawn by
`SprintBoardView`: up to 4 equal columns, more scroll sideways with
`containerRelativeFrame`; no GeometryReader. The ticket detail is a 380 pt
trailing panel in a plain HStack (not `.inspector`); it still hosts the legacy
`JiraTicketDetailView` / `LinearIssueDetailView`. Breadcrumbs:
`sprint filter: …`, `sprint ticket: open|close|start …`.

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
- **Refresh:** on appear, and when `localDiffSummary` or the session's
  `lastActivityAt` changes (catches staging and same-count re-edits), at most
  once per 2 s. The selection survives by relative path, else the first file.
  The model lives in `SidePanelDiffModelCache` on `SessionDetailContent`, so
  mode and selection survive the full diff and back.
- **Cap:** 400 lines per file; patches over 2 MB (`GitDiffError.patchTooLarge`)
  show a note. "Show full diff" (also in the mode menu, and above a load
  error) expands the side panel to the legacy `GitDiffView`, opened on the
  compact view's mode and file; its Close returns to the compact view.
- **Keys and breadcrumbs:** ↑/↓ move the selection once the list has focus.
  `side panel diff: file <path>`, `side panel diff: mode <mode>`.

## P12: title bar and destination tabs

- **Destinations.** `.sessions`, `.reviews`, `.jira`, `.linear`, shown as tabs
  in the title row (`ShellDestinationTabs`: P6 tab look, lead icon, count from
  `ShellDestinationCounts`; no close, no "+"). ⌘1–⌘4 come from `ShellShortcuts`.
  `LegacySectionMapper`: `.sprint` → Jira, `.linear` → Linear, `.workflows` →
  Sessions. The destination was never saved, so no old state needs mapping;
  the old `sprintTracker` default is no longer read.
- **Title row** (`ShellToolbar`): tabs at the content column, a spacer, Search,
  Standard | Warm (`ShellPaletteSwitch`) and light/dark (`ShellAppearanceButton`:
  moon in light, sun in dark; explicit Light/Dark, from System the opposite of
  what shows). Both use `WorkbenchAppearanceController` and the stored values,
  so the bar, Settings and the palette stay in step. Breadcrumbs:
  `palette: <x>`, `appearance: <x>`, `shell: <destination>`.
- **Traffic lights.** The sidebar toggle is the window's only toolbar item
  (`ShellTitlebarToolbar`, `.navigation`, Liquid Glass background hidden,
  toolbar background hidden). With a toolbar AppKit draws a 52 pt unified bar
  and centres the real traffic lights at y 26 (frames x 19, 42, 65). Measured
  in a test host (macOS 27): empty `NSToolbar` → 66 pt bar; one item → 52 pt;
  the item lands at x 100–128, y 12–40 at 1440 and 900 wide; its AppKit
  viewer takes x 92–136 over the full 52 pt, which is why the toggle is the
  item and not a SwiftUI view drawn under an invisible item. Clicks elsewhere
  in the band still reach the hosting view (`TitleBarDragArea`: drag, and
  double-click per `AppleActionOnDoubleClick`).
- **Rejected:** moving `standardWindowButton`s by hand. AppKit lays them out
  again on resize, zoom, full screen and appearance changes, and the 32 pt
  titlebar container would clip them, so they would need moving from layout
  callbacks: a layout-loop risk.
- **Toolbar never changes at runtime.** `ShellWindowChrome` (hooked up once
  per window) turns off toolbar customization, display-mode changes and
  autosave; `ShellCommands` replaces the `.toolbar` command group, so View has
  no Show/Hide Toolbar. Check when touching either: a hidden or resized
  toolbar changes the title bar height and the top safe area at runtime, and
  would remove the only sidebar toggle.
- **Full screen.** `ShellWindowChrome` sets `WorkbenchShellModel.isFullScreen`
  from the window's full-screen notifications (never from geometry). With the
  sidebar hidden the title row's leading padding drops from 142 to 50, since
  the traffic lights are gone (the toggle's full-screen position is assumed,
  not measured).
- **Narrow windows.** The tabs fall back to icon + count, then icon only
  (`ViewThatFits`); the row has `minWidth: 0` and gives way to the trailing
  controls.
- **Safe area.** With the toolbar the top safe area is 52 pt (0 without it
  under `.hiddenTitleBar`). `ShellFrame` ignores the top container safe area
  and lays out from the window's top edge, so the layout is the same either
  way and never reads the inset. The item set never changes at runtime.
- **Sessions.** One session, the sidebar's selection. `SessionDetailStateModel`
  (was `SessionTabsModel`) keeps per-session content mode, Files state, side
  panel segment and auto-open state, plus the selection upkeep: on launch the
  session shown at the last run, else the newest; when the shown session goes
  away, the newest; when it was a launch that just resolved, its real session
  (checked against `resolvedPendingSessionHistory`, so the order of the
  resolution handlers does not matter). The restored session is preferred
  only until the first session shows. Per-session state of sessions that
  went away is pruned. `ShownSessionSync` (was `SessionTabsSync`) saves the
  shown session per window in the v17 `openSessionTabIds` column (migration
  untouched; ordered union across windows via `OpenSessionTabsAggregate`; the
  first window takes it back via `claimRestoredOpenSessionTabIds`).
- **Sidebar** starts with the repo → branch → session tree at 52 pt.
