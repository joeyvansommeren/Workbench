import AgentHubGitHub
import Foundation

/// Account-scoped Reviews state, stored through the existing SQLite service.
struct GitHubReviewWorkspace: Codable, Equatable, Sendable {
  var account: GitHubReviewAccount
  var selectedOwnerID: String?
  var enabledOwnerIDs: Set<String>
  var repositoryName: String
  var ownerLabels: [String: String]
  var projectID: String?
  var viewID: String?
  var queues: [String: CachedQueue]

  struct CachedQueue: Codable, Equatable, Sendable {
    var pullRequests: [GitHubProjectPullRequest]
    var updatedAt: Date
    var isTruncated: Bool
  }
}
