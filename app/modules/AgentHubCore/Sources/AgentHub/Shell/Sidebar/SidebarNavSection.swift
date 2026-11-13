//
//  SidebarNavSection.swift
//  AgentHub
//
//  The Reviews and Sprint rows at the top of the sidebar (`SidebarNav` in the
//  prototype), with their counts.
//

import SwiftUI

struct SidebarNavSection: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    let counts = navCounts
    VStack(spacing: 0) {
      ShellSidebarRow(
        title: "Reviews",
        count: counts.reviews,
        isSelected: shellModel.destination == .reviews,
        action: { shellModel.select(.reviews) },
        lead: { navIcon(.pullRequest, isSelected: shellModel.destination == .reviews) }
      )
      ShellSidebarRow(
        title: "Sprint",
        count: counts.sprint,
        isSelected: shellModel.destination == .sprint,
        action: { shellModel.select(.sprint) },
        lead: { navIcon(.board, isSelected: shellModel.destination == .sprint) }
      )
    }
  }

  private func navIcon(_ glyph: SidebarGlyph, isSelected: Bool) -> some View {
    SidebarIcon(glyph: glyph)
      .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
  }

  private var navCounts: SidebarNavCounts {
    guard let agentHub else { return SidebarNavCounts(reviews: nil, sprint: nil) }
    // Only the tracker Sprint shows is read, so the other one's updates do not
    // re-render the sidebar.
    let tracker = shellModel.sprintTracker
    return SidebarNavCounts(
      reviewQueueCount: agentHub.gitHubReviewsViewModel.pullRequests.count,
      tracker: tracker,
      jiraOpenTicketCount: tracker == .jira ? agentHub.jiraSprintViewModel.myOpenTicketCount : 0,
      linearOpenIssueCount: tracker == .linear ? agentHub.linearViewModel.myOpenIssueCount : 0
    )
  }
}
