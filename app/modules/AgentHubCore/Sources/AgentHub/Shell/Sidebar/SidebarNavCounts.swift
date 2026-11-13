//
//  SidebarNavCounts.swift
//  AgentHub
//
//  The numbers next to Reviews and Sprint in the sidebar. Pure: the nav
//  section reads the view models and hands the raw values in.
//

import Foundation

struct SidebarNavCounts: Equatable {
  /// Pull requests waiting in the review queue; `nil` hides the count.
  let reviews: Int?
  /// My open tickets in the selected tracker; `nil` hides the count.
  let sprint: Int?

  init(reviews: Int?, sprint: Int?) {
    self.reviews = reviews
    self.sprint = sprint
  }

  /// - Parameters:
  ///   - reviewQueueCount: Pull requests in the review queue.
  ///   - tracker: The tracker Sprint shows; picks which ticket count is used.
  ///   - jiraOpenTicketCount: My open Jira tickets in the active sprint.
  ///   - linearOpenIssueCount: My open Linear issues.
  init(
    reviewQueueCount: Int,
    tracker: SprintTracker,
    jiraOpenTicketCount: Int,
    linearOpenIssueCount: Int
  ) {
    let sprintCount = tracker == .jira ? jiraOpenTicketCount : linearOpenIssueCount
    self.init(
      reviews: Self.visible(reviewQueueCount),
      sprint: Self.visible(sprintCount)
    )
  }

  /// Zero is noise in a sidebar: show nothing instead.
  private static func visible(_ count: Int) -> Int? {
    count > 0 ? count : nil
  }
}
