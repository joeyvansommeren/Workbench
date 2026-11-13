//
//  ReviewScope.swift
//  AgentHub
//
//  The Requested / Mine / All switch at the top of the new shell's Reviews
//  list. A UI preference (`AgentHubDefaults.reviewsScope`), not session state.
//

import Foundation

public enum ReviewScope: String, CaseIterable, Sendable, CustomStringConvertible {
  /// Pull requests by someone else: the ones waiting for your review.
  case requested
  /// Your own pull requests.
  case mine
  /// Everything in the selected GitHub Project view.
  case all

  public var description: String {
    switch self {
    case .requested: return "Requested"
    case .mine: return "Mine"
    case .all: return "All"
    }
  }

  /// Whether a pull request belongs in this scope.
  ///
  /// - Parameter isOwn: `GitHubReviewsViewModel.isOwnPullRequest(_:)`; nil while
  ///   your GitHub login is unknown. Mine then shows nothing (it never guesses),
  ///   and Requested shows everything, so the queue is not empty while the
  ///   login loads.
  func includes(isOwn: Bool?) -> Bool {
    switch self {
    case .requested: return isOwn != true
    case .mine: return isOwn == true
    case .all: return true
    }
  }
}
