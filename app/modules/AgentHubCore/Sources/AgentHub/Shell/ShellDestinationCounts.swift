//
//  ShellDestinationCounts.swift
//  AgentHub
//
//  The numbers on the destination tabs. Pure: the tab bar reads the view
//  models and hands the raw values in.
//

import Foundation

struct ShellDestinationCounts: Equatable {
  /// Pull requests waiting for my review (the Requested scope).
  let reviews: Int?
  /// My open tickets in the active Jira sprint.
  let jira: Int?
  /// My open Linear issues.
  let linear: Int?

  init(reviewQueueCount: Int, jiraOpenTicketCount: Int, linearOpenIssueCount: Int) {
    reviews = Self.visible(reviewQueueCount)
    jira = Self.visible(jiraOpenTicketCount)
    linear = Self.visible(linearOpenIssueCount)
  }

  /// The count a tab shows; nil hides it. Sessions has no count.
  func count(for destination: ShellDestination) -> Int? {
    switch destination {
    case .sessions: return nil
    case .reviews: return reviews
    case .jira: return jira
    case .linear: return linear
    }
  }

  /// Zero is noise on a tab: show nothing instead.
  private static func visible(_ count: Int) -> Int? {
    count > 0 ? count : nil
  }
}
