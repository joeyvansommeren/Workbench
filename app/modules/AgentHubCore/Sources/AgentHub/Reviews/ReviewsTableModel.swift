//
//  ReviewsTableModel.swift
//  AgentHub
//
//  Pure model for the new shell's Reviews table: the columns and their fixed
//  widths, the rule that drops low-priority columns at narrow widths, the
//  sort, and the text and state each row shows. No SwiftUI.
//

import AgentHubGitHub
import CoreGraphics
import Foundation

// MARK: - Columns

/// The table's columns, in display order. Every column has a fixed width
/// except the title, which takes the remaining space.
enum ReviewsTableColumn: String, CaseIterable, Sendable {
  case title
  case checks
  case status
  case priority
  case repository
  case author
  case updated
  case session
  case review

  var header: String {
    switch self {
    case .title: return "Pull request"
    case .checks: return "Checks"
    case .status: return "Status"
    case .priority: return "Priority"
    case .repository: return "Repository"
    case .author: return "Author"
    case .updated: return "Updated"
    case .session: return "Session"
    case .review: return "Review"
    }
  }

  /// Fixed width; for the title, the width it asks for before it flexes.
  var width: CGFloat {
    switch self {
    case .title: return 220
    case .checks: return 20
    case .status: return 108
    case .priority: return 72
    case .repository: return 132
    case .author: return 104
    case .updated: return 60
    case .session: return 136
    case .review: return 72
    }
  }

  var isSortable: Bool { self != .review }

  /// Updated sorts newest first on the first click; text columns A to Z;
  /// priority most urgent first; checks failing first.
  var defaultAscending: Bool { self != .updated }
}

// MARK: - Layout

/// Fixed widths and the column-dropping rule. The view offers the column sets
/// to `ViewThatFits` in order, so it shows the first set whose fixed widths
/// fit: no geometry is read and no size feeds back into state.
enum ReviewsTableLayout {
  static let rowHeight: CGFloat = 40
  static let headerHeight: CGFloat = 32
  /// The fixed slot each cell sits in; the tallest cell (the review menu) is 24.
  static let cellHeight: CGFloat = 24
  static let columnSpacing: CGFloat = 10
  /// Inset of the rows from the panel edge, and the cell padding inside a row.
  static let outerInset: CGFloat = 8
  static let rowPadding: CGFloat = 8
  /// The table's narrowest useful width (title and checks). Below the last
  /// set's width the title truncates; nothing overflows.
  static let minimumWidth: CGFloat = 180

  /// The order columns go in as the table narrows: first dropped first.
  static let dropOrder: [ReviewsTableColumn] = [
    .author, .priority, .repository, .status, .review, .session, .updated,
  ]

  /// Every column, then one fewer at each step, down to title and checks.
  static let columnSets: [[ReviewsTableColumn]] = {
    var sets: [[ReviewsTableColumn]] = [ReviewsTableColumn.allCases]
    var current = ReviewsTableColumn.allCases
    for column in dropOrder {
      current.removeAll { $0 == column }
      sets.append(current)
    }
    return sets
  }()

  /// The width a set needs at its ideal size (title at its ideal width).
  static func width(of columns: [ReviewsTableColumn]) -> CGFloat {
    let cells = columns.reduce(0) { $0 + $1.width }
    let gaps = CGFloat(max(0, columns.count - 1)) * columnSpacing
    return cells + gaps + 2 * (outerInset + rowPadding)
  }

  /// The set `ViewThatFits` picks for `available` points: the first that
  /// fits, else the last. For tests; the view never calls it.
  static func columns(fitting available: CGFloat) -> [ReviewsTableColumn] {
    columnSets.first { width(of: $0) <= available } ?? columnSets[columnSets.count - 1]
  }
}

// MARK: - Sort

/// The column the table is sorted by. Nil on the view model means the
/// suggested order: most urgent priority first, then waiting longest.
struct ReviewsTableSort: Equatable, Sendable {
  var column: ReviewsTableColumn
  var ascending: Bool
  /// The checks states when the Checks sort was chosen. Selecting a row loads
  /// its checks; sorting on the live map would move the row under the cursor,
  /// so this order holds until the next header click.
  var checksSnapshot: [String: CIStatus] = [:]

  /// The sort after a click on `column`'s header: the same column flips,
  /// another column starts in its default direction. A Checks sort takes a
  /// snapshot of `checks`.
  static func next(
    after current: ReviewsTableSort?,
    clicking column: ReviewsTableColumn,
    checks: [String: CIStatus] = [:]
  ) -> ReviewsTableSort {
    let ascending: Bool
    if let current, current.column == column {
      ascending = !current.ascending
    } else {
      ascending = column.defaultAscending
    }
    return ReviewsTableSort(
      column: column, ascending: ascending, checksSnapshot: column == .checks ? checks : [:])
  }
}

enum ReviewsTableRows {
  /// Rows for the visible pull requests, sorted. Ties keep the newest first.
  static func make(
    pullRequests: [GitHubProjectPullRequest],
    links: [String: [GitHubReviewSessionLink]],
    sort: ReviewsTableSort?
  ) -> [GitHubReviewTableRow] {
    let rows = pullRequests.map {
      GitHubReviewTableRow(pullRequest: $0, sessionLinks: links[$0.id] ?? [])
    }
    guard let sort else {
      return rows.sorted(using: GitHubReviewTableRow.suggestedSortOrder)
    }
    return rows.sorted { lhs, rhs in
      // Empty values (no status, no session) go last in both directions.
      let lhsEmpty = textValue(lhs, column: sort.column)?.isEmpty == true
      let rhsEmpty = textValue(rhs, column: sort.column)?.isEmpty == true
      if lhsEmpty != rhsEmpty { return rhsEmpty }
      let order = compare(lhs, rhs, sort: sort)
      if order == .orderedSame {
        return lhs.updatedSortValue > rhs.updatedSortValue
      }
      return sort.ascending ? order == .orderedAscending : order == .orderedDescending
    }
  }

  /// The text a text column sorts on; nil for number columns.
  private static func textValue(_ row: GitHubReviewTableRow, column: ReviewsTableColumn) -> String? {
    switch column {
    case .title: return row.title
    case .status: return row.status
    case .repository: return row.repository
    case .author: return row.author
    case .session: return row.sessionSortValue
    case .priority, .updated, .checks, .review: return nil
    }
  }

  private static func compare(
    _ lhs: GitHubReviewTableRow, _ rhs: GitHubReviewTableRow, sort: ReviewsTableSort
  ) -> ComparisonResult {
    if let left = textValue(lhs, column: sort.column),
      let right = textValue(rhs, column: sort.column)
    {
      return left.localizedStandardCompare(right)
    }
    switch sort.column {
    case .priority: return number(lhs.prioritySortValue, rhs.prioritySortValue)
    case .updated: return number(lhs.updatedSortValue, rhs.updatedSortValue)
    case .checks:
      return number(checksRank(sort.checksSnapshot[lhs.id]), checksRank(sort.checksSnapshot[rhs.id]))
    default: return .orderedSame
    }
  }

  private static func checksRank(_ status: CIStatus?) -> Int {
    PullRequestChecksState.sortRank(PullRequestChecksState(status))
  }

  private static func number<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
  }
}

// MARK: - Row presentation

/// What one table row shows. Equatable, so rows redraw only when it changes.
struct ReviewsTableRowPresentation: Equatable {
  let id: String
  let title: String
  /// `#1843`, shown in mono after the title.
  let number: String
  let repositoryName: String
  let repositoryFullName: String
  let author: String
  let age: String
  let status: String?
  let priority: String?
  let isUrgent: Bool
  let checks: PullRequestChecksState?
  let sessionName: String?
  let sessionStatus: SessionStatusPresentation?
  /// Linked sessions beyond the first, shown as `+N`.
  let extraSessionCount: Int
  /// What VoiceOver reads after the row label: status, priority, author,
  /// age and checks, so the user does not have to step into every cell.
  let accessibilityValue: String

  init(row: GitHubReviewTableRow, checks: CIStatus?, now: Date = Date()) {
    let pullRequest = row.pullRequest
    id = pullRequest.id
    title = pullRequest.title
    number = "#\(pullRequest.number)"
    repositoryName = pullRequest.repositoryName
    repositoryFullName = pullRequest.repositoryNameWithOwner
    author = pullRequest.authorLogin ?? "unknown"
    age = PullRequestRowPresentation.age(from: pullRequest.updatedAt, now: now)
    status = Self.nonEmpty(pullRequest.projectStatus)
    priority = Self.nonEmpty(pullRequest.projectPriority)
    isUrgent = GitHubReviewRecommendation.isUrgent(pullRequest.projectPriority)
    self.checks = PullRequestChecksState(checks)
    let link = row.sessionLinks.first
    sessionName = link?.displayName
    sessionStatus = link.map { SessionStatusPresentation(status: $0.status, isPending: $0.isPending) }
    extraSessionCount = max(0, row.sessionLinks.count - 1)
    accessibilityValue = [
      status,
      priority.map { "\($0) priority" },
      "by \(author)",
      pullRequest.updatedAt.map { "updated \(Self.spokenAge(from: $0, now: now))" },
      self.checks?.accessibilityLabel,
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
  }

  /// "5 hours ago": the compact age ("5h") reads badly in VoiceOver.
  static func spokenAge(from date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

// MARK: - Keyboard selection

enum ReviewsTableSelection {
  /// The row ↑ (-1) or ↓ (+1) moves to. With nothing selected, ↓ picks the
  /// first row and ↑ the last; the ends stay put.
  static func moved(from selectedID: String?, in ids: [String], by delta: Int) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let selectedID, let index = ids.firstIndex(of: selectedID) else {
      return delta >= 0 ? ids.first : ids.last
    }
    return ids[min(max(index + delta, 0), ids.count - 1)]
  }
}
