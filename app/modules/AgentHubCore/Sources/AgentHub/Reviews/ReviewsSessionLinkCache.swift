//
//  ReviewsSessionLinkCache.swift
//  AgentHub
//
//  Keeps the Reviews pull request → session links between renders. Linking
//  scans every session (prompts, ticket keys) for every visible pull request;
//  the Reviews body re-renders on every session status tick, but the links
//  only change when the pull requests, the launches or the session inventory
//  (ids, names, branches, pending launches) change. Statuses are applied on
//  top of the cached links on each render, which is cheap.
//

import Foundation

@MainActor
final class ReviewsSessionLinkCache {
  private var key: Int?
  private var cached: [String: [GitHubReviewSessionLink]] = [:]

  /// The cached links when `key` matches the last call, else `compute()`.
  func links(
    key: Int,
    compute: () -> [String: [GitHubReviewSessionLink]]
  ) -> [String: [GitHubReviewSessionLink]] {
    if key == self.key { return cached }
    cached = compute()
    self.key = key
    return cached
  }

  /// `links` with each session's current status. Pending links have no status.
  static func applyingStatuses(
    _ links: [String: [GitHubReviewSessionLink]],
    statuses: [SessionProviderKind: [String: SessionStatus]]
  ) -> [String: [GitHubReviewSessionLink]] {
    links.mapValues { list in
      list.map { link in
        guard !link.isPending else { return link }
        let status = statuses[link.provider]?[link.session.id]
        guard status != link.status else { return link }
        return GitHubReviewSessionLink(
          provider: link.provider,
          session: link.session,
          itemID: link.itemID,
          isPending: link.isPending,
          displayName: link.displayName,
          status: status
        )
      }
    }
  }
}
