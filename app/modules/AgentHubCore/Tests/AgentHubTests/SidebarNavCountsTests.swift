import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sidebar nav counts")
struct SidebarNavCountsTests {
  @Test("Reviews counts the review queue")
  func reviewsCount() {
    let counts = SidebarNavCounts(
      reviewQueueCount: 5, tracker: .jira, jiraOpenTicketCount: 0, linearOpenIssueCount: 0)
    #expect(counts.reviews == 5)
  }

  @Test("Sprint counts the tracker Sprint shows")
  func sprintFollowsTracker() {
    let jira = SidebarNavCounts(
      reviewQueueCount: 0, tracker: .jira, jiraOpenTicketCount: 4, linearOpenIssueCount: 9)
    let linear = SidebarNavCounts(
      reviewQueueCount: 0, tracker: .linear, jiraOpenTicketCount: 4, linearOpenIssueCount: 9)
    #expect(jira.sprint == 4)
    #expect(linear.sprint == 9)
  }

  @Test("Zero hides the count")
  func zeroHides() {
    let counts = SidebarNavCounts(
      reviewQueueCount: 0, tracker: .linear, jiraOpenTicketCount: 3, linearOpenIssueCount: 0)
    #expect(counts.reviews == nil)
    #expect(counts.sprint == nil)
  }
}
