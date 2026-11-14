import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Reviews table")
struct ReviewsTableTests {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  // MARK: - Columns

  @Test("The first set has every column; each next set drops one, down to title and checks")
  func columnSets() {
    let sets = ReviewsTableLayout.columnSets
    #expect(sets.first == ReviewsTableColumn.allCases)
    #expect(sets.last == [.title, .checks])
    #expect(sets.count == ReviewsTableLayout.dropOrder.count + 1)
    for (index, column) in ReviewsTableLayout.dropOrder.enumerated() {
      #expect(sets[index].contains(column))
      #expect(!sets[index + 1].contains(column))
    }
    // Every set is narrower than the one before, so the first fit is the widest that fits.
    let widths = sets.map(ReviewsTableLayout.width(of:))
    #expect(widths == widths.sorted(by: >))
  }

  @Test("Width adds fixed columns, gaps and insets")
  func width() {
    let columns: [ReviewsTableColumn] = [.title, .checks]
    let expected: CGFloat = 220 + 20 + 10 + 2 * (8 + 8)
    #expect(ReviewsTableLayout.width(of: columns) == expected)
  }

  @Test("Wide panels show every column; narrow ones drop author first, then priority")
  func columnDropping() {
    let all = ReviewsTableLayout.columnSets[0]
    #expect(ReviewsTableLayout.columns(fitting: ReviewsTableLayout.width(of: all)) == all)

    let justUnder = ReviewsTableLayout.width(of: all) - 1
    #expect(!ReviewsTableLayout.columns(fitting: justUnder).contains(.author))
    #expect(ReviewsTableLayout.columns(fitting: justUnder).contains(.priority))

    // 1152 pt window: content 856 pt. Author and priority go, the rest stays.
    let wide = ReviewsTableLayout.columns(fitting: 856)
    #expect(!wide.contains(.author))
    #expect(!wide.contains(.priority))
    #expect(wide.contains(.repository))
    #expect(wide.contains(.session))
    #expect(wide.contains(.review))

    // Narrower than the last set: the last set, which truncates its title.
    #expect(ReviewsTableLayout.columns(fitting: 100) == [.title, .checks])
  }

  // MARK: - Sort

  @Test("Clicking the sorted column flips it; another column starts in its default direction")
  func nextSort() {
    let byTitle = ReviewsTableSort.next(after: nil, clicking: .title)
    #expect(byTitle == ReviewsTableSort(column: .title, ascending: true))
    #expect(ReviewsTableSort.next(after: byTitle, clicking: .title).ascending == false)

    let byUpdated = ReviewsTableSort.next(after: byTitle, clicking: .updated)
    #expect(byUpdated == ReviewsTableSort(column: .updated, ascending: false))
  }

  @Test("No sort is the suggested order: most urgent priority, then waiting longest")
  func suggestedOrder() {
    let pullRequests = [
      pullRequest("low-new", priority: "Low", updated: 300),
      pullRequest("urgent", priority: "Urgent", updated: 200),
      pullRequest("low-old", priority: "Low", updated: 100),
    ]
    let rows = ReviewsTableRows.make(pullRequests: pullRequests, links: [:], checks: [:], sort: nil)
    #expect(rows.map(\.id) == ["urgent", "low-old", "low-new"])
  }

  @Test("Sorting by a text column puts empty values last in both directions")
  func textSortEmptyLast() {
    let pullRequests = [
      pullRequest("none", status: nil),
      pullRequest("b", status: "Ready"),
      pullRequest("a", status: "In review"),
    ]
    let ascending = ReviewsTableRows.make(
      pullRequests: pullRequests, links: [:], checks: [:],
      sort: ReviewsTableSort(column: .status, ascending: true))
    #expect(ascending.map(\.id) == ["a", "b", "none"])

    let descending = ReviewsTableRows.make(
      pullRequests: pullRequests, links: [:], checks: [:],
      sort: ReviewsTableSort(column: .status, ascending: false))
    #expect(descending.map(\.id) == ["b", "a", "none"])
  }

  @Test("Sorting by checks puts failing first; ties keep the newest first")
  func checksSort() {
    let pullRequests = [
      pullRequest("pass", updated: 100),
      pullRequest("unknown", updated: 400),
      pullRequest("fail", updated: 200),
      pullRequest("pending-old", updated: 50),
      pullRequest("pending-new", updated: 300),
    ]
    let checks: [String: CIStatus] = [
      "pass": .success, "fail": .failure, "pending-old": .pending, "pending-new": .pending,
    ]
    let rows = ReviewsTableRows.make(
      pullRequests: pullRequests, links: [:], checks: checks,
      sort: ReviewsTableSort(column: .checks, ascending: true))
    #expect(rows.map(\.id) == ["fail", "pending-new", "pending-old", "pass", "unknown"])
  }

  @Test("Sorting by updated, newest first, and by session name")
  func updatedAndSessionSort() {
    let pullRequests = [
      pullRequest("old", updated: 100),
      pullRequest("new", updated: 300),
      pullRequest("mid", updated: 200),
    ]
    let byUpdated = ReviewsTableRows.make(
      pullRequests: pullRequests, links: [:], checks: [:],
      sort: ReviewsTableSort(column: .updated, ascending: false))
    #expect(byUpdated.map(\.id) == ["new", "mid", "old"])

    let links = ["old": [link("Alpha review")], "mid": [link("Beta review")]]
    let bySession = ReviewsTableRows.make(
      pullRequests: pullRequests, links: links, checks: [:],
      sort: ReviewsTableSort(column: .session, ascending: true))
    #expect(bySession.map(\.id) == ["old", "mid", "new"])
  }

  // MARK: - Row presentation

  @Test("A row shows number, repository, author, age, status, priority and session")
  func rowPresentation() {
    let row = GitHubReviewTableRow(
      pullRequest: pullRequest(
        "pr", status: " In review ", priority: "Urgent", updated: now.timeIntervalSince1970 - 7_200),
      sessionLinks: [link("Review device checks"), link("Second")])
    let presentation = ReviewsTableRowPresentation(row: row, checks: .failure, now: now)

    #expect(presentation.number == "#1843")
    #expect(presentation.repositoryName == "xfa-dashboard")
    #expect(presentation.repositoryFullName == "xfa/xfa-dashboard")
    #expect(presentation.author == "lvermeulen")
    #expect(presentation.age == "2h")
    #expect(presentation.status == "In review")
    #expect(presentation.priority == "Urgent")
    #expect(presentation.isUrgent)
    #expect(presentation.checks == .fail)
    #expect(presentation.sessionName == "Review device checks")
    #expect(presentation.extraSessionCount == 1)
  }

  @Test("Missing values: unknown author, no status, no priority, no session")
  func rowPresentationEmpty() {
    let row = GitHubReviewTableRow(
      pullRequest: pullRequest("pr", author: nil, status: "  ", priority: nil), sessionLinks: [])
    let presentation = ReviewsTableRowPresentation(row: row, checks: nil, now: now)

    #expect(presentation.author == "unknown")
    #expect(presentation.status == nil)
    #expect(presentation.priority == nil)
    #expect(!presentation.isUrgent)
    #expect(presentation.checks == nil)
    #expect(presentation.sessionName == nil)
    #expect(presentation.sessionStatus == nil)
    #expect(presentation.extraSessionCount == 0)
  }

  // MARK: - Keyboard

  @Test("Arrow keys move the selection and stop at the ends")
  func keyboardSelection() {
    let ids = ["a", "b", "c"]
    #expect(ReviewsTableSelection.moved(from: nil, in: ids, by: 1) == "a")
    #expect(ReviewsTableSelection.moved(from: nil, in: ids, by: -1) == "c")
    #expect(ReviewsTableSelection.moved(from: "a", in: ids, by: 1) == "b")
    #expect(ReviewsTableSelection.moved(from: "a", in: ids, by: -1) == "a")
    #expect(ReviewsTableSelection.moved(from: "c", in: ids, by: 1) == "c")
    #expect(ReviewsTableSelection.moved(from: "gone", in: ids, by: 1) == "a")
    #expect(ReviewsTableSelection.moved(from: "a", in: [], by: 1) == nil)
  }

  // MARK: - Helpers

  private func pullRequest(
    _ id: String,
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
      isDraft: false, state: "open", projectStatus: status, projectPriority: priority)
  }

  private func link(_ name: String) -> GitHubReviewSessionLink {
    GitHubReviewSessionLink(
      provider: .claude,
      session: CLISession(
        id: name, projectPath: "/tmp/xfa-dashboard", branchName: "main", lastActivityAt: now,
        firstMessage: nil),
      itemID: "claude-\(name)", isPending: false, displayName: name, status: .idle)
  }
}
