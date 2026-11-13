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
child. `ShellLayout.windowMinWidth` is 1288 while the legacy Reviews view is
hosted: its `NavigationSplitView` sidebar (min 260) + divider + PR `HSplitView`
(350 + divider + 380) = 992, plus the 288 shell sidebar and the 8 pt panel
inset. P8 lowers it to 900 when it replaces Reviews.

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
- **Appearance**: Settings › Appearance shows System / Light / Dark and
  Standard / Warm when the flag is on (YAML theme picker hidden), applied live
  by `WorkbenchAppearanceController`. The stored appearance is applied when a
  shell window opens.
