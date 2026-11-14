import Foundation
import Testing

@testable import AgentHubCore

@Suite("Shell destination counts")
struct ShellDestinationCountsTests {
  @Test("Each tab counts its own source; Sessions has none")
  func countsPerDestination() {
    let counts = ShellDestinationCounts(reviewQueueCount: 5, jiraOpenTicketCount: 4, linearOpenIssueCount: 9)
    #expect(counts.count(for: .sessions) == nil)
    #expect(counts.count(for: .reviews) == 5)
    #expect(counts.count(for: .jira) == 4)
    #expect(counts.count(for: .linear) == 9)
  }

  @Test("Zero hides the count")
  func zeroHides() {
    let counts = ShellDestinationCounts(reviewQueueCount: 0, jiraOpenTicketCount: 3, linearOpenIssueCount: 0)
    #expect(counts.reviews == nil)
    #expect(counts.jira == 3)
    #expect(counts.linear == nil)
  }
}
