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
| toolbar | `ShellToolbar` (destination tabs, search) | P12 |
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
  safe-area top is 0, and the shell draws its own title band (height from
  `ShellTitleBarMetrics`, see "Title band"). Nothing ignores the top safe area
  except backgrounds. `TitleBarDragArea` gives the empty band drag and
  double-click (it honours `AppleActionOnDoubleClick`).
- **Traffic lights.** Without a toolbar the system title bar is 32 pt and the
  traffic lights sit at x 9–69, centred 16 pt from the top (macOS 27). P12
  centred them in a 52 pt bar with a toolbar; that broke every click in the
  title row and was undone. The title band now follows the lights instead.
  See "Title row clicks" and "Title band".

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
  not an input question). Since P15 it opens the session, where the banner
  shows the whole command; it never approves from the tree
  (`SidebarApprovePillText`).
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
`AgentHubDefaults.reviewsAgent`. The queue carries no CI data, so after each
queue refresh a batched GraphQL rollup fetch (`checkRollups`, 50 per call)
fills `checksByPullRequestID`. Only this view turns it on
(`wantsQueueChecks`); the legacy Reviews makes no checks calls. Rows and the
detail use GitHub's rollup rule (`CIStatus.rollup`: skipped and neutral count
as passed), so an icon keeps its meaning when the detail loads.
Breadcrumbs: `reviews scope: <x>`, `reviews pr: <repo>#<n>`, `reviews filters:
open`, `reviews agent`, `reviews start review`, `reviews open session`.
The legacy `GitHubReviewsView` is unchanged for the flag-off path.
**P13** replaced the list with a table (`ReviewsTableView`, model in `ReviewsTableModel`: fixed column widths, `ViewThatFits` drops columns, sort in `GitHubReviewsViewModel.tableSort`) and the detail with a fixed 400 pt trailing panel (close button / Esc); breadcrumbs `reviews sort: <column>`, `reviews detail: open|close`.

## P9: Sprint

Since P12, `.jira` shows `JiraDestinationView` and `.linear` shows
`LinearDestinationView` (both in `Jira/SprintDestinationView.swift`). The list
head (`SprintListHead`) shows the sprint or cycle name with its days-left chip
(no title when Linear has no active cycle), All | Mine and Filters. Jira and Linear map to the
tracker-neutral `SprintColumnItem`s (`Sprint/SprintBoardItems.swift`), drawn by
`SprintBoardView`: up to 4 equal columns, more scroll sideways with
`containerRelativeFrame`; no GeometryReader. The ticket detail is a 380 pt
trailing panel in a plain HStack (not `.inspector`); since P16 it hosts
`Sprint/TicketDetailView` (see "P16: ticket detail"). Breadcrumbs:
`sprint filter: …`, `sprint ticket: open|close|start …`.

**People filter (Jira, 2026-11-14, Joey).** P9 had moved the legacy avatar
bar into Filters; it is back in the head, after All | Mine
(`SprintPeopleStrip`, logic in `SprintPeopleFilter`). You first, then
everyone by name, then Unassigned. One click filters to that person, a
second click shows everyone; your own avatar is the Mine filter. Selected =
accent tint and ring; hover and press change colour only. The head's
`ViewThatFits` shows 6 avatars, then 3, then only the menu; the rest sit in
a "+n" menu (never a "+1"). Filters no longer has an Assignee picker, and
its count and clear cover the search only. Linear has no per-person filter
(Everyone / Mine), so its head is unchanged. Breadcrumb `sprint filter:
person on|off`.

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
- **Tree:** Approve pill (spinner while an answer is in flight) and an Answer
  pill for input questions. Both only open the session (P15).
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
  first mode with changes, because the header diffstat and "Commit N files"
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
- **Title row** (`ShellToolbar`): tabs at the content column, a spacer, then
  Search. Standard | Warm and light/dark left the row (2026-11-14, Joey): they
  live in Settings › Appearance (`WorkbenchAppearanceSettingsSection`) and the
  palette's "Switch appearance", which crossfades the window
  (`ThemeCrossfade`). Breadcrumbs: `appearance: <x>`, `shell: <destination>`.
- **Sidebar toggle and traffic lights.** No `NSToolbar` (see "Title row
  clicks"). The toggle is `ShellWindowControls`, a SwiftUI overlay on
  `ShellFrame`, 12 pt right of the zoom button (x 81–109 on macOS 27; 8–36 in
  full screen), centred in the title band; it stays put when the sidebar
  hides. Its background is a `TitleBarDragArea` over the sidebar column, so
  the whole band drags the window. Band height and positions: "Title band".
- **Rejected:** moving `standardWindowButton`s by hand. AppKit lays them out
  again on resize, zoom, full screen and appearance changes, and the 32 pt
  titlebar container would clip them, so they would need moving from layout
  callbacks: a layout-loop risk.
- **View menu.** `ShellCommands` replaces the `.toolbar` command group, so
  View has no Show/Hide Toolbar item.
- **Full screen.** `ShellWindowChrome` sets `WorkbenchShellModel.isFullScreen`
  from the window's full-screen notifications (never from geometry). The
  toggle moves to x 8 and, with the sidebar hidden, the title row's leading
  padding drops from 123 to 50, since the traffic lights are gone.
- **Narrow windows.** The tabs fall back to icon + count, then icon only
  (`ViewThatFits`); the row has `minWidth: 0` and gives way to the trailing
  controls.
- **Safe area.** `ShellFrame` ignores the top container safe area and lays
  out from the window's top edge, so the layout never reads the inset.
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
- **Sidebar** starts with the repo → branch → session tree at the content
  panel's top (`ShellLayout.contentTop`, 40 pt on macOS 27).

## Title row clicks (fix, 2026-11-14)

- **Bug.** In the installed app no control in the title row took a click:
  tabs, Search, Standard | Warm, light/dark. The sidebar toggle worked.
- **Root cause.** P12 gave the window an `NSToolbar` (the toggle as its only
  item) for the 52 pt bar and centred traffic lights. With a toolbar, a
  mouse-down under the titlebar reaches the content only inside the region
  the content's hosting view reports through AppKit's
  `_regionForOpaqueDescendants:forMove:forUnderTitlebar:`. Elsewhere
  `-[NSWindow sendEvent:]` calls `performWindowDragWithEvent:` and no view
  gets `mouseDown:`. SwiftUI's region covers its controls in a simple tree,
  but not once the content has composited layers: one `.clipShape` or
  `.shadow` below the row (the content panel has both) was enough. Hit
  testing was never the problem: the frame view resolves those points into
  the hosting view.
- **Evidence** (macOS 27, real `ShellFrame` + `ShellToolbar`, a trusted probe
  app that loads the test bundle, key and active window, real HID clicks and
  `NSWindow.sendEvent`, also inside a real `WindowGroup`): with the toolbar,
  tab and Search clicks did nothing, and the hosting view never received
  `mouseDown:`. Without it they worked. A bare row plus a toolbar worked until
  a clipped or shadowed view was added below the row. P12's measurement used
  a stand-alone host with no such layers, so it saw clicks pass.
- **Fix (approach c): no `NSToolbar`.** The toggle is a SwiftUI overlay again
  (`ShellWindowControls`), as before P12. The lights stay at AppKit's default
  for a hidden title bar, and the title band is fitted to them ("Title band").
- **Rejected:** (a) the whole row as the toolbar's only item. Clicks work
  there, but AppKit sizes a flexible SwiftUI item to its minimum. Its width
  would have to come from window-resize state, and an item one frame too wide
  moves to overflow, which takes the whole row and the toggle with it (a
  runtime toolbar change). (b) Keep the toolbar and mark the row as
  interactive: an opaque, non-movable AppKit view behind the row did not
  enter SwiftUI's region, and there is no public API for it.
- **Guard.** `ShellTitleBarHitTests` hosts the real `ShellFrame` the way a
  scene does and clicks every title-row control through `NSWindow.sendEvent`
  at 1440 and 900 pt. It also checks the empty bar (drag, double-click zoom,
  with the double-click setting injected, not read from the machine) and
  that the window has no toolbar. It failed on the P12 code and passes now.
  (The real `WorkbenchShellView` root cannot be hosted in `xctest`: its
  sessions view model asks `UNUserNotificationCenter` for permission, which
  throws without an app bundle. The static guard below covers the root.)
  `TitleBarDragView` accepts the first mouse, like a real title bar, so an
  inactive window drags and zooms from the first click.
- **Static guard.** `scripts/check-shell.sh` (run by `scripts/test.sh`, also
  in `packages`, so CI runs it) fails on `.toolbar`, `ToolbarItem…` and
  `.searchable` in `Shell/`, `Reviews/`, `Sprint/`, `Design/` and the two
  Sprint destination files. Any of them gives the window an `NSToolbar`
  again. Legacy flag-off files are listed in the script's `ALLOWED`.

## Title band (2026-11-14)

- **One line.** Traffic lights, sidebar toggle, tabs and Search share one
  centre line, as in the prototype (Joey's complaint was that they did not).
  The lights cannot move safely (see "Rejected" in P12), so the band follows
  them.
- **Measured, not assumed.** `ShellWindowChrome` reads the real close and
  zoom buttons at window hookup (next run-loop turn) and again on window
  notifications: leaving full screen (a window that opened in full screen
  keeps the default until then), a screen or backing-scale change, and
  becoming key. Never from layout; the model ignores equal metrics.
  `ShellRoot` applies it (`.shellWindowChrome(_:)`) outside the
  `.wbRedrawsOnPaletteChange()` subtree, so a palette switch keeps it; it
  removes its observers when dismantled. The result goes to
  `WorkbenchShellModel.titleBar` (`ShellTitleBarMetrics`): band height = 2 ×
  the close button's centre below the top edge; toggle leading = the zoom
  button's right edge + 12. The buttons' place does not depend on our
  content, so nothing feeds back. Implausible values (lights hidden in full
  screen, band outside 20–60) are ignored. The default, `.standard`, is the
  macOS 27 measurement: band 32 pt (lights centred 16 pt from the top),
  zoom button ending at x 69. Only macOS 27 was available to measure; older
  systems may differ (a 28 pt title bar), which is why it is measured.
- **Below the band.** The content panel starts 8 pt below it
  (`DesignTokens.Inset.panel`, 40 pt on macOS 27), and the sidebar tree
  starts at the same y (`ShellLayout.contentTop`).
- **Controls.** The destination tabs are 28 pt (`Size.control`, not the
  32 pt `Size.tab`), so the pill clears the window's top edge in a 32 pt
  band. Search and the toggle are 28 pt too. All are centred in the band.
  The old 52 pt `Size.titlebar` token is gone.
- **Guard.** `ShellTitleBarHitTests` sweeps each control top to bottom and
  checks that its centre line is the close button's (±1 pt) at 1440 and 900
  pt, and that the toggle sits 12 pt after the zoom button. It also checks
  full screen with the lights hidden: toggle at the edge, tabs still clicked.

## P14: motion pass

Plan: `Workbench-ui-explorations/apple/MOTION-PLAN.md`.

- **Hover and press change colour only**, on the first frame. No scale
  anywhere. Press = hover fill + `wbSurfacePressed` (darker in light, lighter
  in dark). The four button styles share `WBButtonBody`; the split buttons
  share `WBSplitLeftBody`; `IconButton` and `AttentionPill` read `isPressed`
  through private styles.
- **Springs** are critically damped and always go through `.wbAnimation(_:)`
  (nil under Reduce Motion). `scripts/check-motion.sh` (run by
  `scripts/test.sh`, also in `packages`, so CI runs it) fails on press/hover
  scale and bouncy springs in new-shell code.
- **Instant:** selection, hover, destination change, ⌘1–4, tabs, counts, field
  focus. Destination tabs are `.fixedSize()`, so the sidebar animation moves
  them and never resizes them.
- **Animated:** approval banner (rises 8 pt on `medium`, fades out on
  `fast`), banner phase and banner ↔ chip crossfades and the Approve pill
  title ↔ spinner (`fast`), palette and scrim (opacity only, `fast`), repo
  chevron (`fast`), "Load more" rows (fade, `fast`), sidebar toggle
  (`medium`, unchanged), Jira notice (`standard`, no bounce).
- **Trailing panels** (side panel, Reviews detail, Sprint detail): the width
  appears at once; only the contents fade and slide 8 pt
  (`wbPanelEntrance()`, `Design/Motion/PanelEntrance.swift`). The session side
  panel animates only when it is opened (`WorkbenchShellModel.sidePanelEntrance`),
  not when a session switch remounts it. Reviews and Sprint animate only when
  the selection goes from none to one while the destination is on screen
  (`wbTracksPanelOpen`), not on ⌘2/3/4 or at launch.
- **Approve ⌘↩** handlers are owned by their request
  (`setApprovalShortcutHandler(forKey:request:_:)`): a banner leaving late
  cannot clear the next request's handler.
- **Theme switch** from the palette's "Switch appearance": one window
  crossfade of a `CALayer` snapshot (`Design/Motion/ThemeCrossfade.swift`, 0.24 s ease-out). It also
  runs under Reduce Motion.
- **Hover preview:** 700 ms for the first, then at once while one is open or
  for 1 s after (`HoverPreviewTiming` on `SidebarTreeActions`).

## P16: sidebar follow-ups

- **CI-failure notifications.** `SidebarCIFailureNotifications`
  (`Sidebar/SidebarCIFailureNotifications.swift`) is applied once per window
  in `ShellRoot`, not on the sidebar: tree rows are lazy and the sidebar
  leaves the hierarchy when hidden. `SidebarCIFailureObserver` keeps one
  `SessionGitHubQuickAccessViewModel` per monitored session (key: item id +
  repository key, as the legacy row's task id) with the legacy row's recipe
  (`SessionCIObservation`: stagger, no refresh on subscribe, shared with
  `CollapsibleSessionRow`) and feeds `GitHubCIFailureNotifier`, so
  a failure notifies once per (repo, PR, head commit), whichever surface sees
  it first.
- **View Transcript** in the session row's context menu calls
  `SessionsActionCoordinator.openSessionFile`, which reads the file off the
  main actor and shows "Couldn't read the transcript" when it is missing,
  unreadable or empty; `SessionsPresentationModifier`
  presents `coordinator.sessionFileSheetItem` with the legacy
  `SessionTranscriptSheetView` (the legacy views never set it). The header
  "…" menu already had it. Breadcrumb `tree: transcript <id>`.
- **First-run sidebar.** `CLISessionsViewModel.hasLoadedRepositories` turns on
  once the launch restore has put the saved repositories in place (or found
  none); it stays off when the saved state can't be read. The sidebar shows
  "No projects" with Open project only when both providers have loaded and
  nothing is tracked (`SidebarFirstRun`); the footer's Open project is hidden
  then, so there is one button.

## P16: ticket detail (Jira and Linear)

`Sprint/TicketDetailView` replaces the legacy `JiraTicketDetailView` /
`LinearIssueDetailView` in the shell (both stay for the flag-off path).
`TicketDetailPresentation` (pure, `TicketDetailPresentationTests`) maps a Jira
ticket or a Linear issue to one `SprintTicketDetail`. The panel: key and close
(Esc), title, the status chip (a menu with the other columns, "Move To"; Linear
moves through `LinearViewModel.moveIssue`, optimistic with rollback, as on the
board), priority, type and label tags,
"Start session" (`SplitButton`; the primary half uses
`SprintStartProvider.preferred`, the menu names Claude Code or Codex; same
start path and starting guard as the card) and "Open in Jira/Linear", a
`PropertyCard` (Assignee, Sprint or Cycle, Project: the legacy repository
picker), linked sessions (`StatusGlyph` and word, click opens), pull requests
(Jira only, with refresh), and the description through the Reviews
`pullRequestDescription` MarkdownUI theme (headings capped below the panel
title: `DescriptionMarkdownHeading`), capped at 1200 characters with
"Show all". Jira's plain-text description keeps its line breaks as hard
breaks. The entrance stays in `SprintDestinationLayout`. Breadcrumbs:
`sprint ticket: move <key>`, `sprint ticket: project`, `sprint ticket: open
session`. Linear Filters now has an Assignee choice (Everyone / Mine), because
the list head drops All | Mine at the narrowest widths.
