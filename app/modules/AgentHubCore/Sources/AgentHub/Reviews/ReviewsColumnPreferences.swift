import Foundation
import Observation

/// Column visibility is a UI choice; queue and session state stay with their owners.
@MainActor
@Observable
final class ReviewsColumnPreferences {
  static let storageKey = "com.agenthub.reviews.visibleColumns"
  static let optionalColumns = ReviewsTableColumn.allCases.filter { $0 != .title && $0 != .checks }

  private var chosenColumns: Set<ReviewsTableColumn>?
  private let defaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    defaults = userDefaults
    chosenColumns = userDefaults.stringArray(forKey: Self.storageKey).map {
      Set($0.compactMap(ReviewsTableColumn.init(rawValue:)))
    }
  }

  func columns(for rows: [GitHubReviewTableRow]) -> [ReviewsTableColumn] {
    let optional = chosenColumns ?? defaultColumns(for: rows)
    return ReviewsTableColumn.allCases.filter { $0 == .title || $0 == .checks || optional.contains($0) }
  }

  func setVisible(_ visible: Bool, column: ReviewsTableColumn, rows: [GitHubReviewTableRow]) {
    guard Self.optionalColumns.contains(column) else { return }
    var chosen = chosenColumns ?? defaultColumns(for: rows)
    if visible { chosen.insert(column) } else { chosen.remove(column) }
    chosenColumns = chosen
    defaults.set(Self.optionalColumns.filter(chosen.contains).map(\.rawValue), forKey: Self.storageKey)
  }

  func reset() {
    chosenColumns = nil
    defaults.removeObject(forKey: Self.storageKey)
  }

  private func defaultColumns(for rows: [GitHubReviewTableRow]) -> Set<ReviewsTableColumn> {
    var columns: Set<ReviewsTableColumn> = [.updated]
    if rows.contains(where: { !($0.pullRequest.projectStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      columns.insert(.status)
    }
    if Set(rows.map { $0.pullRequest.repositoryNameWithOwner.lowercased() }).count > 1 {
      columns.insert(.repository)
    }
    if rows.contains(where: { !$0.sessionLinks.isEmpty }) { columns.insert(.session) }
    return columns
  }
}
