//
//  ShellShortcuts.swift
//  AgentHub
//
//  One table for the new shell's keyboard shortcuts and destination titles.
//  The menu bar (`ShellCommands`) binds them; the command palette shows them
//  as key caps. Change a shortcut here and both follow.
//

import SwiftUI

struct ShellShortcut: Equatable {
  let key: KeyEquivalent
  let modifiers: EventModifiers
  /// Key caps in the macOS menu order (⌃ ⌥ ⇧ ⌘), then the key.
  let keyCaps: [String]

  static let newSession = ShellShortcut(key: "n", modifiers: .command, keyCaps: ["⌘", "N"])
  static let search = ShellShortcut(key: "k", modifiers: .command, keyCaps: ["⌘", "K"])
  static let resumeSessionByID = ShellShortcut(
    key: "r", modifiers: [.shift, .command], keyCaps: ["⇧", "⌘", "R"])
  static let toggleSidebar = ShellShortcut(
    key: "s", modifiers: [.control, .command], keyCaps: ["⌃", "⌘", "S"])
  static let toggleSidePanel = ShellShortcut(
    key: "0", modifiers: [.option, .command], keyCaps: ["⌥", "⌘", "0"])
  static let archiveCurrentSession = ShellShortcut(
    key: "a", modifiers: [.option, .command], keyCaps: ["⌥", "⌘", "A"])
  /// Settings is bound by the system Settings scene; listed for the palette.
  static let openSettings = ShellShortcut(key: ",", modifiers: .command, keyCaps: ["⌘", ","])

  static func == (lhs: ShellShortcut, rhs: ShellShortcut) -> Bool {
    lhs.keyCaps == rhs.keyCaps
  }
}

extension ShellDestination {
  var title: String {
    switch self {
    case .sessions: return "Sessions"
    case .reviews: return "Reviews"
    case .sprint: return "Sprint"
    }
  }

  /// ⌘1, ⌘2, ⌘3 in sidebar order.
  var shortcut: ShellShortcut {
    switch self {
    case .sessions: return ShellShortcut(key: "1", modifiers: .command, keyCaps: ["⌘", "1"])
    case .reviews: return ShellShortcut(key: "2", modifiers: .command, keyCaps: ["⌘", "2"])
    case .sprint: return ShellShortcut(key: "3", modifiers: .command, keyCaps: ["⌘", "3"])
    }
  }
}

extension View {
  func keyboardShortcut(_ shortcut: ShellShortcut) -> some View {
    keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
  }
}
