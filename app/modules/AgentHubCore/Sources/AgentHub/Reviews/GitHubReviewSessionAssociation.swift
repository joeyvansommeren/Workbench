//
//  GitHubReviewSessionAssociation.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import GRDB

protocol GitHubReviewSessionStoreProtocol: Sendable {
  func saveGitHubReviewSessionAssociation(
    _ association: GitHubReviewSessionAssociation
  ) async throws
  func githubReviewSessionAssociations() async throws -> [GitHubReviewSessionAssociation]
  func reviewWorkspace(account: GitHubReviewAccount) async throws -> GitHubReviewWorkspace?
  func saveReviewWorkspace(_ workspace: GitHubReviewWorkspace) async throws
}

extension GitHubReviewSessionStoreProtocol {
  func reviewWorkspace(account: GitHubReviewAccount) async throws -> GitHubReviewWorkspace? { nil }
  func saveReviewWorkspace(_ workspace: GitHubReviewWorkspace) async throws {}
}

struct GitHubReviewSessionAssociation:
  Codable, Equatable, Sendable, FetchableRecord, PersistableRecord
{
  var pullRequestID: String
  var pullRequestURL: String
  var provider: String
  var pendingID: String?
  var sessionID: String?
  var projectPath: String
  var createdAt: Date
  var updatedAt: Date
  var sourceAccountKey: String?
  var branchName: String?

  static var databaseTableName: String { "github_review_sessions" }

  init(
    pullRequestID: String,
    pullRequestURL: String,
    provider: SessionProviderKind,
    pendingID: UUID?,
    sessionID: String?,
    projectPath: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    sourceAccountKey: String? = nil,
    branchName: String? = nil
  ) {
    self.pullRequestID = pullRequestID
    self.pullRequestURL = pullRequestURL
    self.provider = provider.rawValue
    self.pendingID = pendingID?.uuidString
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sourceAccountKey = sourceAccountKey
    self.branchName = branchName
  }

  var providerKind: SessionProviderKind? {
    SessionProviderKind(rawValue: provider)
  }

  var pendingUUID: UUID? {
    pendingID.flatMap(UUID.init(uuidString:))
  }
}
