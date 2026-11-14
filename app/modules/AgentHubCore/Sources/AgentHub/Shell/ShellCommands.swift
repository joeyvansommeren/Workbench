//
//  ShellCommands.swift
//  AgentHub
//
//  Menu commands for the new shell. They act on the key window's shell through
//  a focused scene value, so each window keeps its own state. The legacy root
//  keeps its own Navigate menu (see `AgentHubApp`); the app installs one or the
//  other, fixed for the process.
//

import SwiftUI

/// What a key shell window exposes to the menu bar. Menu items call these
/// closures instead of posting app-wide notifications, so with two windows
/// only the key window reacts.
@MainActor
struct ShellCommandTarget {
  let model: WorkbenchShellModel
  let startNewSession: () -> Void
  let resumeSessionByID: () -> Void
  let togglePalette: () -> Void
  let archiveCurrentSession: () -> Void
}

extension FocusedValues {
  @Entry var workbenchShell: ShellCommandTarget?
}

public struct ShellCommands: Commands {
  @FocusedValue(\.workbenchShell) private var shell

  public init() {}

  public var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button(shell?.model.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
        shell?.model.toggleSidebar()
      }
      .keyboardShortcut(ShellShortcut.toggleSidebar)
      .disabled(shell == nil)

      Button(shell?.model.sidePanelVisible == false ? "Show Side Panel" : "Hide Side Panel") {
        shell?.model.toggleSidePanel()
      }
      .keyboardShortcut(ShellShortcut.toggleSidePanel)
      .disabled(shell == nil)
    }

    // The window has no toolbar (Shell/README.md, "Title row clicks"), so
    // View shows no Show/Hide Toolbar item.
    CommandGroup(replacing: .toolbar) {}

    // ⌘N starts a session, as it did in the legacy Sessions view.
    CommandGroup(replacing: .newItem) {
      Button("New Session…") {
        shell?.model.select(.sessions)
        shell?.startNewSession()
      }
      .keyboardShortcut(ShellShortcut.newSession)
      .disabled(shell == nil)
    }

    CommandMenu("Navigate") {
      ForEach(ShellDestination.allCases, id: \.self) { destination in
        destinationButton(destination)
      }

      Divider()

      Button("Search…") {
        shell?.togglePalette()
      }
      .keyboardShortcut(ShellShortcut.search)
      .disabled(shell == nil)

      Button("Resume Session by ID…") {
        shell?.resumeSessionByID()
      }
      .keyboardShortcut(ShellShortcut.resumeSessionByID)
      .disabled(shell == nil)

      // Archive acts on the session shown in Sessions, as in the legacy view.
      Button("Archive Current Session") {
        shell?.archiveCurrentSession()
      }
      .keyboardShortcut(ShellShortcut.archiveCurrentSession)
      .disabled(shell?.model.destination != .sessions)
    }
  }

  private func destinationButton(_ destination: ShellDestination) -> some View {
    Button(destination.title) { shell?.model.select(destination) }
      .keyboardShortcut(destination.shortcut)
      .disabled(shell == nil)
  }
}
