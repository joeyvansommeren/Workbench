//
//  CommandPaletteEntries.swift
//  AgentHub
//
//  Pure builder for the new shell's command palette (prototype
//  `paletteEntries()` / `renderPalette()`): Sessions, Pull requests, Go to and
//  Commands, with status ordering, filtering and highlight ranges. No SwiftUI
//  state, no providers: the view hands in plain snapshots.
//

import Foundation

// MARK: - Inputs

/// A session as the palette needs it.
struct CommandPaletteSessionInput: Equatable {
  /// The `SidebarSessionItemID` used by `SessionNavigationModel`.
  let itemID: String
  let title: String
  let branch: String
  let status: SessionStatus?
  let isPending: Bool
}

/// A pull request as the palette needs it.
struct CommandPalettePullRequestInput: Equatable {
  let id: String
  let title: String
  let number: Int
  let repositoryName: String
  /// `owner/name`; also the stable key for the repository tile colour.
  let repositoryNameWithOwner: String
}

// MARK: - Output

enum CommandPaletteGroup: String, CaseIterable {
  case sessions = "Sessions"
  case pullRequests = "Pull requests"
  case goTo = "Go to"
  case commands = "Commands"
}

/// The commands the palette offers. Key caps mirror the menu shortcuts.
enum CommandPaletteCommand: String, CaseIterable {
  case newSession
  case resumeSessionByID
  case toggleSidePanel
  case toggleSidebar
  case openSettings
  case switchAppearance

  var title: String {
    switch self {
    case .newSession: return "New session"
    case .resumeSessionByID: return "Resume session by ID"
    case .toggleSidePanel: return "Toggle side panel"
    case .toggleSidebar: return "Toggle sidebar"
    case .openSettings: return "Open Settings"
    case .switchAppearance: return "Switch appearance"
    }
  }

  var systemImage: String {
    switch self {
    case .newSession: return "plus"
    case .resumeSessionByID: return "arrow.clockwise"
    case .toggleSidePanel: return "sidebar.right"
    case .toggleSidebar: return "sidebar.left"
    case .openSettings: return "gearshape"
    case .switchAppearance: return "moon"
    }
  }

  /// The menu shortcut, from the table `ShellCommands` binds.
  var shortcut: ShellShortcut? {
    switch self {
    case .newSession: return .newSession
    case .resumeSessionByID: return .resumeSessionByID
    case .toggleSidePanel: return .toggleSidePanel
    case .toggleSidebar: return .toggleSidebar
    case .openSettings: return .openSettings
    case .switchAppearance: return nil
    }
  }

  var keys: [String] { shortcut?.keyCaps ?? [] }
}

/// What a palette row shows at its leading edge.
enum CommandPaletteLead: Equatable {
  case status(SessionStatusPresentation)
  /// A repository letter tile. `colorKey` picks the stable tile colour.
  case tile(name: String, colorKey: String)
  case symbol(String)
  /// SF Symbols has no pull-request glyph; draw `PullRequestGlyph`.
  case pullRequestGlyph
}

/// What running a palette row does. The view maps it onto the window.
enum CommandPaletteTarget: Equatable {
  case session(itemID: String)
  case pullRequest(id: String, repositoryNameWithOwner: String, number: Int)
  case destination(ShellDestination)
  case command(CommandPaletteCommand)
}

struct CommandPaletteEntry: Identifiable, Equatable {
  let id: String
  let group: CommandPaletteGroup
  let lead: CommandPaletteLead
  let title: String
  /// Branch, or "repo #123"; empty for Go to and Commands.
  let meta: String
  /// Status word for sessions; nil elsewhere.
  let trailingText: String?
  /// Key caps for Go to and Commands; empty elsewhere.
  let keys: [String]
  let target: CommandPaletteTarget
  /// First case-insensitive match of the query in `title` / `meta`.
  var titleHighlight: Range<String.Index>?
  var metaHighlight: Range<String.Index>?
}

// MARK: - Builder

enum CommandPaletteEntries {
  /// With an empty query the palette shows a short list, as in the prototype.
  static let idleSessionLimit = 4
  static let idleCommandLimit = 3

  /// attention > ready > running > thinking > idle (prototype order).
  static func statusRank(_ presentation: SessionStatusPresentation) -> Int {
    switch presentation.category {
    case .attention: return 0
    case .ready: return 1
    case .working: return presentation.shape == .spinningArc ? 2 : 3
    case .idle: return 4
    }
  }

  static func build(
    query: String,
    sessions: [CommandPaletteSessionInput],
    pullRequests: [CommandPalettePullRequestInput]
  ) -> [CommandPaletteEntry] {
    let all = allEntries(sessions: sessions, pullRequests: pullRequests)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      return Array(all.filter { $0.group == .sessions }.prefix(idleSessionLimit))
        + all.filter { $0.group == .goTo }
        + Array(all.filter { $0.group == .commands }.prefix(idleCommandLimit))
    }

    return all.compactMap { entry in
      guard firstMatch(of: trimmed, in: "\(entry.title) \(entry.meta)") != nil else { return nil }
      var highlighted = entry
      highlighted.titleHighlight = firstMatch(of: trimmed, in: entry.title)
      highlighted.metaHighlight = firstMatch(of: trimmed, in: entry.meta)
      return highlighted
    }
  }

  /// The highlighted row follows an entry id, not a position, so a live status
  /// reorder never moves Return onto another session. Falls back to the
  /// first row when the id is gone (or none was picked yet).
  static func activeIndex(for entryID: String?, in entries: [CommandPaletteEntry]) -> Int {
    entryID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
  }

  static func firstMatch(of query: String, in text: String) -> Range<String.Index>? {
    guard !query.isEmpty else { return nil }
    return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
  }

  private static func allEntries(
    sessions: [CommandPaletteSessionInput],
    pullRequests: [CommandPalettePullRequestInput]
  ) -> [CommandPaletteEntry] {
    sessionEntries(sessions) + pullRequestEntries(pullRequests) + goToEntries + commandEntries
  }

  private static func sessionEntries(_ sessions: [CommandPaletteSessionInput]) -> [CommandPaletteEntry] {
    // Stable: equal ranks keep the caller's order (newest first).
    sessions.enumerated()
      .map { (offset: $0.offset, input: $0.element, presentation: SessionStatusPresentation(status: $0.element.status, isPending: $0.element.isPending)) }
      .sorted { lhs, rhs in
        let lhsRank = statusRank(lhs.presentation)
        let rhsRank = statusRank(rhs.presentation)
        return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
      }
      .map { item in
        CommandPaletteEntry(
          id: "session-\(item.input.itemID)",
          group: .sessions,
          lead: .status(item.presentation),
          title: item.input.title,
          meta: item.input.branch,
          trailingText: item.presentation.word,
          keys: [],
          target: .session(itemID: item.input.itemID)
        )
      }
  }

  private static func pullRequestEntries(
    _ pullRequests: [CommandPalettePullRequestInput]
  ) -> [CommandPaletteEntry] {
    pullRequests.map { pullRequest in
      CommandPaletteEntry(
        id: "pr-\(pullRequest.id)",
        group: .pullRequests,
        lead: .tile(name: pullRequest.repositoryName, colorKey: pullRequest.repositoryNameWithOwner),
        title: pullRequest.title,
        meta: "\(pullRequest.repositoryName) #\(pullRequest.number)",
        trailingText: nil,
        keys: [],
        target: .pullRequest(
          id: pullRequest.id,
          repositoryNameWithOwner: pullRequest.repositoryNameWithOwner,
          number: pullRequest.number
        )
      )
    }
  }

  private static let goToEntries: [CommandPaletteEntry] = ShellDestination.allCases.map { destination in
    CommandPaletteEntry(
      id: "goto-\(destination.rawValue)",
      group: .goTo,
      lead: lead(for: destination),
      title: destination.title,
      meta: "",
      trailingText: nil,
      keys: destination.shortcut.keyCaps,
      target: .destination(destination)
    )
  }

  private static func lead(for destination: ShellDestination) -> CommandPaletteLead {
    switch destination {
    case .sessions: return .symbol("terminal")
    case .reviews: return .pullRequestGlyph
    case .jira, .linear: return .symbol("rectangle.split.3x1")
    }
  }

  private static let commandEntries: [CommandPaletteEntry] = CommandPaletteCommand.allCases.map {
    CommandPaletteEntry(
      id: "command-\($0.rawValue)",
      group: .commands,
      lead: .symbol($0.systemImage),
      title: $0.title,
      meta: "",
      trailingText: nil,
      keys: $0.keys,
      target: .command($0)
    )
  }
}
