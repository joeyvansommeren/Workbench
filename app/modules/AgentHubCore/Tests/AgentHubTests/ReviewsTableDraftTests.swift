import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Reviews table — draft marker")
struct ReviewsTableDraftTests {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  // MARK: - Draft row spoken label

  @Test("A draft row's accessibility value starts with Draft")
  func draftRowAccessibilityValue() {
    let row = GitHubReviewTableRow(
      pullRequest: pullRequest("draft-pr", isDraft: true),
      sessionLinks: [])
    let presentation = ReviewsTableRowPresentation(row: row, checks: nil, now: now)

    #expect(presentation.accessibilityValue.hasPrefix("Draft"))
  }

  @Test("A non-draft row's accessibility value does not contain Draft")
  func nonDraftRowAccessibilityValue() {
    let row = GitHubReviewTableRow(
      pullRequest: pullRequest("open-pr", isDraft: false),
      sessionLinks: [])
    let presentation = ReviewsTableRowPresentation(row: row, checks: nil, now: now)

    #expect(!presentation.accessibilityValue.contains("Draft"))
  }

  // MARK: - Helpers

  private func pullRequest(
    _ id: String,
    isDraft: Bool,
    author: String? = "lvermeulen",
    status: String? = nil,
    priority: String? = nil,
    updated: TimeInterval = 1_000
  ) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: id, number: 1843, title: "Pull request \(id)",
      url: "https://github.com/xfa/xfa-dashboard/pull/1843", repositoryName: "xfa-dashboard",
      repositoryNameWithOwner: "xfa/xfa-dashboard", authorLogin: author,
      updatedAt: Date(timeIntervalSince1970: updated),
      isDraft: isDraft, state: "open", projectStatus: status, projectPriority: priority)
  }
}
