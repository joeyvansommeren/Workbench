import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Pull request row presentation")
struct PullRequestRowPresentationTests {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  private static let ageCases: [(TimeInterval?, String)] = [
    (nil, ""),
    (0, "now"),
    (59, "now"),
    (60, "1m"),
    (59 * 60, "59m"),
    (2 * 3_600, "2h"),
    (23 * 3_600, "23h"),
    (24 * 3_600, "1d"),
    (6 * 86_400, "6d"),
    (7 * 86_400, "1w"),
    (364 * 86_400, "52w"),
    (400 * 86_400, "1y"),
    (-30, "now"),
  ]

  @Test("Age is compact", arguments: ageCases)
  func age(secondsAgo: TimeInterval?, expected: String) {
    let date = secondsAgo.map { now.addingTimeInterval(-$0) }
    #expect(PullRequestRowPresentation.age(from: date, now: now) == expected)
  }

  @Test("Row text: repo and number, author, age")
  func rowText() {
    let row = PullRequestRowPresentation(
      pullRequest: pullRequest(author: "lvermeulen", updatedAt: now.addingTimeInterval(-7_200)),
      checks: nil, now: now)

    #expect(row.repositoryLabel == "xfa-dashboard #1843")
    #expect(row.author == "lvermeulen")
    #expect(row.age == "2h")
    #expect(row.checks == nil)
  }

  @Test("Checks map pass, fail and pending; no checks shows no icon")
  func checksState() {
    #expect(PullRequestChecksState(.success) == .pass)
    #expect(PullRequestChecksState(.failure) == .fail)
    #expect(PullRequestChecksState(.pending) == .pending)
    #expect(PullRequestChecksState(CIStatus.none) == nil)
    #expect(PullRequestChecksState(nil) == nil)
  }

  @Test("Checks summary: worst state wins and counts that state")
  func checksSummary() throws {
    let passed = try runs(["SUCCESS", "SUCCESS", "SKIPPED"])
    expectSummary(passed, text: "2 passed", state: .pass)

    let failed = try runs(["SUCCESS", "FAILURE", "PENDING"])
    expectSummary(failed, text: "1 failed", state: .fail)

    let pending = try runs(["SUCCESS", "PENDING", "PENDING"])
    expectSummary(pending, text: "2 pending", state: .pending)

    expectSummary(nil, text: "No checks", state: nil)
  }

  // MARK: - Helpers

  private func expectSummary(
    _ checks: [GitHubCheckRun]?, text: String, state: PullRequestChecksState?
  ) {
    let summary = PullRequestChecksSummary(checks: checks)
    #expect(summary.text == text)
    #expect(summary.state == state)
  }

  /// "PENDING" builds an in-progress run; anything else is a conclusion.
  private func runs(_ outcomes: [String]) throws -> [GitHubCheckRun] {
    let items = outcomes.enumerated().map { index, outcome in
      outcome == "PENDING"
        ? #"{"name":"c\#(index)","status":"IN_PROGRESS"}"#
        : #"{"name":"c\#(index)","status":"COMPLETED","conclusion":"\#(outcome)"}"#
    }
    return try JSONDecoder().decode(
      [GitHubCheckRun].self, from: Data("[\(items.joined(separator: ","))]".utf8))
  }

  private func pullRequest(author: String?, updatedAt: Date?) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: "pr", number: 1843, title: "Device checks: empty state for new orgs",
      url: "https://github.com/xfa/xfa-dashboard/pull/1843", repositoryName: "xfa-dashboard",
      repositoryNameWithOwner: "xfa/xfa-dashboard", authorLogin: author, updatedAt: updatedAt,
      isDraft: false, state: "open", projectStatus: nil)
  }
}
