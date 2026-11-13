//
//  ClaudeTUIThemeHint.swift
//  AgentHub
//
//  Claude Code draws its TUI with its own theme. With Claude's dark theme on
//  the new shell's light terminal, text is hard to read. Workbench reads the
//  `theme` key from `~/.claude.json` (read-only, never written) and shows a
//  one-line hint to switch with `/config`.
//

import Foundation

protocol ClaudeTUIThemeReading: Sendable {
  /// Claude Code's configured TUI theme ("dark", "light", "dark-daltonized", …),
  /// or nil when it is not set or the file cannot be read.
  func currentTheme() async -> String?
}

struct ClaudeTUIThemeReader: ClaudeTUIThemeReading {
  let configURL: URL

  init(
    configURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude.json")
  ) {
    self.configURL = configURL
  }

  func currentTheme() async -> String? {
    let url = configURL
    // The file can be several MB; read it off the main actor.
    return await Task.detached(priority: .utility) {
      guard let data = try? Data(contentsOf: url) else { return nil }
      return Self.theme(fromConfigData: data)
    }.value
  }

  static func theme(fromConfigData data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object["theme"] as? String
  }
}

enum ClaudeTUIThemeHint {
  static let message = "Claude uses a dark theme. Run /config in the terminal to pick a light theme."

  /// Only for Claude sessions in the new shell's light terminal, and only when
  /// Claude's theme is a dark one. An unknown theme shows nothing.
  static func shouldShow(
    claudeTheme: String?,
    providerKind: SessionProviderKind,
    isDarkTerminal: Bool,
    followsWorkbenchPalette: Bool
  ) -> Bool {
    guard followsWorkbenchPalette, providerKind == .claude, !isDarkTerminal else { return false }
    guard let claudeTheme else { return false }
    return claudeTheme.lowercased().hasPrefix("dark")
  }
}
