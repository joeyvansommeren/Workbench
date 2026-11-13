# Shell (new interface)

The window root shown when `AgentHubDefaults.appleShellEnabled` is on at launch.
`AgentHubApp` reads the flag once, so the root, menus and window style are fixed
until relaunch. With the flag off, `AgentHubOperationsView` runs unchanged.

## Slots

`ShellFrame(sidebar:toolbar:detail:)` lays out three slots. Each phase replaces
only its own slot:

| Slot | View | Replaced by |
|---|---|---|
| sidebar | `ShellSidebarContainer` (nav rows + `ShellPlaceholderSessionList`) | P5 |
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
