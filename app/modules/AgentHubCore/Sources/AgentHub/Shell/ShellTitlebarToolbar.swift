//
//  ShellTitlebarToolbar.swift
//  AgentHub
//
//  The window's only toolbar item: the sidebar toggle (`.window-controls` in
//  the prototype). Having a toolbar makes AppKit draw a 52 pt unified title
//  bar, so the real traffic lights centre at y 26 in the shell's title row;
//  the toggle sits right of them (x 100–128), centred too, and stays put when
//  the sidebar hides. Everything else in the row is SwiftUI (`ShellToolbar`).
//
//  Why a real item: an empty `NSToolbar` gives a 66 pt bar; one item gives
//  52 pt. Any item gets a 44 × 52 pt hit area right of the traffic lights
//  (measured), which would cover a SwiftUI toggle drawn there, so the toggle
//  is that item. Why not move the window buttons by hand: AppKit lays them
//  out again on resize, full screen and appearance changes, so they would
//  have to be moved from layout callbacks, a layout-loop risk. Details and
//  measurements: Shell/README.md, "P12".
//
//  Layout-loop safety: the item set is fixed for the window's life and never
//  shown or hidden at runtime. Only the toggle's label and help text change.
//

import SwiftUI

struct ShellTitlebarToolbar: ViewModifier {
  let shellModel: WorkbenchShellModel

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .toolbar {
          ToolbarItem(placement: .navigation) { ShellSidebarToggle(shellModel: shellModel) }
            // No Liquid Glass capsule: the prototype draws a plain icon button.
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    } else {
      content
        .toolbar {
          ToolbarItem(placement: .navigation) { ShellSidebarToggle(shellModel: shellModel) }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
  }
}

/// The sidebar toggle (⌃⌘S). Fixed 28 pt frame, so the item never resizes.
struct ShellSidebarToggle: View {
  let shellModel: WorkbenchShellModel

  var body: some View {
    IconButton(
      systemImage: "sidebar.left",
      accessibilityLabel: shellModel.sidebarVisible ? "Hide sidebar" : "Show sidebar",
      accessibilityIdentifier: "shell.toggleSidebar"
    ) {
      shellModel.toggleSidebar()
    }
    .help(shellModel.sidebarVisible ? "Hide sidebar  ⌃⌘S" : "Show sidebar  ⌃⌘S")
    .fixedSize()
  }
}
