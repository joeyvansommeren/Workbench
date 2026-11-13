//
//  SessionProviderKind.swift
//  AgentHubSessionGraph
//
//  Provider identity shared by session graph and AgentHubCore.
//

import Foundation

public enum SessionProviderKind: String, CaseIterable, Codable, Sendable {
  case claude = "Claude"
  case codex = "Codex"

  /// Tooltip text for controls disabled because the provider CLI is missing.
  public var notInstalledHelp: String {
    switch self {
    case .claude: return "Claude Code is not installed"
    case .codex: return "Codex is not installed"
    }
  }
}
