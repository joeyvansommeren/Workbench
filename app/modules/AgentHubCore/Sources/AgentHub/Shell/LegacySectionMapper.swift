//
//  LegacySectionMapper.swift
//  AgentHub
//
//  Maps the legacy five-section workspace (`AgentHubWorkspaceSection`) onto the
//  new shell's three destinations, so existing callers of
//  `AgentHubAppCommand.selectWorkspace` and `AgentHubNavigation` keep working
//  when the new shell is on.
//

import Foundation

enum LegacySectionMapper {
  /// Where a legacy section lands in the new shell.
  struct Target: Equatable {
    let destination: ShellDestination
    /// Set when the section implies a tracker (`.sprint` is Jira, `.linear` is
    /// Linear). `nil` leaves the user's tracker preference alone.
    let sprintTracker: SprintTracker?
  }

  static func target(for section: AgentHubWorkspaceSection) -> Target {
    switch section {
    // Workflows fold into the session tree (decision in the implementation plan).
    case .workflows, .sessions:
      return Target(destination: .sessions, sprintTracker: nil)
    case .reviews:
      return Target(destination: .reviews, sprintTracker: nil)
    // `showJiraTicket` posts `.sprint`, so it must show the Jira board.
    case .sprint:
      return Target(destination: .sprint, sprintTracker: .jira)
    case .linear:
      return Target(destination: .sprint, sprintTracker: .linear)
    }
  }
}
