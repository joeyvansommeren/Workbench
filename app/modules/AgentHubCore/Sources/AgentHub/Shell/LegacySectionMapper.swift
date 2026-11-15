//
//  LegacySectionMapper.swift
//  AgentHub
//
//  Maps the legacy five-section workspace (`AgentHubWorkspaceSection`) onto the
//  new shell's destinations, so existing callers of
//  `AgentHubAppCommand.selectWorkspace` and `AgentHubNavigation` keep working
//  when the new shell is on.
//

import Foundation

enum LegacySectionMapper {
  static func destination(for section: AgentHubWorkspaceSection) -> ShellDestination {
    switch section {
    // Workflows fold into the session tree (decision in the implementation plan).
    case .workflows, .sessions: return .sessions
    case .reviews: return .reviews
    // `showJiraTicket` posts `.sprint`, so it must show the Jira board.
    case .sprint: return .jira
    case .linear: return .linear
    }
  }
}
