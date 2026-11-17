//
//  ReviewScope.swift
//  AgentHub
//
//  The To review / Mine / All switch at the top of the new shell's Reviews
//  list. A UI preference (`AgentHubDefaults.reviewsScope`), not session state.
//

import Foundation

public enum ReviewScope: String, CaseIterable, Sendable, CustomStringConvertible {
  /// Pull requests not identified as your own; no review request is implied.
  case requested
  /// Your own pull requests.
  case mine
  /// Every pull request within the selected repository sources and optional Project.
  case all

  public var description: String {
    switch self {
    case .requested: return "To review"
    case .mine: return "Mine"
    case .all: return "All"
    }
  }

  /// Whether a pull request belongs in this scope.
  ///
  /// - Parameter isOwn: `GitHubReviewsViewModel.isOwnPullRequest(_:)`; nil while
  ///   your GitHub login is unknown. Mine then shows nothing (it never guesses),
  ///   and To review shows everything, so the queue is not empty while the
  ///   login loads.
  func includes(isOwn: Bool?) -> Bool {
    switch self {
    case .requested: return isOwn != true
    case .mine: return isOwn == true
    case .all: return true
    }
  }
}
