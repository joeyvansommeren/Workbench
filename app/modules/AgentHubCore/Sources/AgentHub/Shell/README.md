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
| toolbar | `ShellToolbar` (`ShellSessionsToolbarContent` / titles / search) | P6 tabs, P8, P9 |
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
child. `ShellLayout.windowMinWidth` is 1137 while the legacy Sessions workflow
comparison (`HSplitView`, two 420 pt panes) is hosted; P6 lowers it to 900.
`ReviewsLayoutTests` checks that Reviews fits the minimum.

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
  `SidebarTreeActions.approve`, today `SidebarApproval.terminalApprove`
  (types "1" into the agent terminal). P7 replaces that closure.
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
