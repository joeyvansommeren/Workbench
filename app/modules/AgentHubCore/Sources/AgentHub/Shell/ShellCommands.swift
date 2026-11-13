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

/// What a key shell window exposes to the menu bar.
@MainActor
struct ShellCommandTarget {
  let model: WorkbenchShellModel
  let startNewSession: () -> Void
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
      .keyboardShortcut("s", modifiers: [.control, .command])
      .disabled(shell == nil)

      Button(shell?.model.sidePanelVisible == false ? "Show Side Panel" : "Hide Side Panel") {
        shell?.model.toggleSidePanel()
      }
      .keyboardShortcut("0", modifiers: [.option, .command])
      .disabled(shell == nil)
    }

    // ⌘N starts a session, as it did in the legacy Sessions view.
    CommandGroup(replacing: .newItem) {
      Button("New Session…") {
        shell?.model.select(.sessions)
        shell?.startNewSession()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(shell == nil)
    }

    CommandMenu("Navigate") {
      destinationButton("Sessions", .sessions, key: "1")
      destinationButton("Reviews", .reviews, key: "2")
      destinationButton("Sprint", .sprint, key: "3")

      Divider()

      // TODO(P10): open the new command palette. The legacy palette lives
      // inside the legacy Sessions view and is not reachable from here.
      Button("Search…") {}
        .keyboardShortcut("k", modifiers: .command)
        .disabled(true)

      Button("Resume Session by ID…") {
        AgentHubAppCommand.resumeSessionByID()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])

      Button("Archive Current Session") {
        AgentHubAppCommand.archiveCurrentSession()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
    }
  }

  private func destinationButton(
    _ title: String,
    _ destination: ShellDestination,
    key: KeyEquivalent
  ) -> some View {
    Button(title) { shell?.model.select(destination) }
      .keyboardShortcut(key, modifiers: .command)
      .disabled(shell == nil)
  }
}
