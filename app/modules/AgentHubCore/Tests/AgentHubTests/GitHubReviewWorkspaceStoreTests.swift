import AgentHubGitHub
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Review workspace persistence")
struct GitHubReviewWorkspaceStoreTests {
  @Test("v22 preserves the complete v21 baseline, links, titles, and launch origins")
  func migrationPreservation() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reviews-\(UUID()).sqlite"
    ).path
    let queue = try DatabaseQueue(path: path)
    let template = try SessionMetadataStore(path: ":memory:")
    try template.migrator.migrate(
      queue, upTo: SessionMetadataStore.MigrationID.createSessionLaunchOrigins)
    try await queue.write { db in
      try SessionMetadata(sessionId: "existing", customName: "Manual title", isPinned: true).insert(
        db)
      try db.execute(
        sql: "INSERT INTO session_launch_origins VALUES (?, ?, ?, ?)",
        arguments: ["pending", "Claude", "existing", Data("origin".utf8)])
      try db.execute(
        sql: """
          INSERT INTO github_review_sessions
          (pullRequestID, pullRequestURL, provider, sessionID, projectPath, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          "PR1", "https://code.example.test/acme/shared/pull/1", "Claude", "existing",
          "/fixture/shared", Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 200),
        ])
      try db.execute(
        sql: "INSERT INTO session_results VALUES (?, ?)",
        arguments: ["result", Data("result".utf8)])
    }
    let migrated = try SessionMetadataStore(path: path)
    #expect(
      try await migrated.getMetadata(for: ["existing"])["existing"]?.customName == "Manual title")
    let links = try await migrated.githubReviewSessionAssociations()
    #expect(links.count == 1)
    #expect(links.first?.sessionID == "existing")
    #expect(links.first?.sourceAccountKey == nil)
    #expect(links.first?.branchName == nil)
    try await queue.read { db throws -> Void in
      #expect(
        try Data.fetchOne(db, sql: "SELECT payload FROM session_launch_origins")
          == Data("origin".utf8))
      #expect(
        try Data.fetchOne(db, sql: "SELECT payload FROM session_results") == Data("result".utf8))
    }
  }

  @Test("Sources and queues round-trip without crossing host or account")
  func accountIsolation() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reviews-\(UUID()).sqlite"
    ).path
    let store = try SessionMetadataStore(path: path)
    let account = GitHubReviewAccount(host: "code.example.test", nodeID: "U1", login: "alex")
    let workspace = GitHubReviewWorkspace(
      account: account, selectedOwnerID: "owner-1",
      enabledOwnerIDs: ["owner-1", "owner-2"], repositoryName: "shared",
      ownerLabels: ["owner-2": "Company"],
      projectID: nil, viewID: nil, queues: [:])
    try await store.saveReviewWorkspace(workspace)
    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.reviewWorkspace(account: account) == workspace)
    #expect(
      try await reopened.reviewWorkspace(
        account: GitHubReviewAccount(
          host: "another.example.test", nodeID: "U1", login: "alex")) == nil)
    #expect(
      try await reopened.reviewWorkspace(
        account: GitHubReviewAccount(
          host: "code.example.test", nodeID: "U2", login: "sam")) == nil)
  }

  @Test("An account rename retains the saved workspace")
  func renamedAccountWorkspace() async throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let old = GitHubReviewAccount(host: "code.example.test", nodeID: "U1", login: "alex")
    let renamed = GitHubReviewAccount(host: "code.example.test", nodeID: "U1", login: "new-alex")
    let workspace = GitHubReviewWorkspace(
      account: old, selectedOwnerID: "code.example.test/U1",
      enabledOwnerIDs: ["code.example.test/U1"], repositoryName: "shared",
      ownerLabels: ["code.example.test/U1": "Personal work"],
      projectID: nil, viewID: nil, queues: [:])
    try await store.saveReviewWorkspace(workspace)
    #expect(try await store.reviewWorkspace(account: renamed) == workspace)
  }

  @Test("Review associations retain source account and actual launch branch")
  func associationIdentity() async throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let association = GitHubReviewSessionAssociation(
      pullRequestID: "code.example.test/U1|acme/shared#1",
      pullRequestURL: "https://code.example.test/acme/shared/pull/1", provider: .codex,
      pendingID: UUID(), sessionID: nil, projectPath: "/fixture/shared",
      sourceAccountKey: "code.example.test/U1", branchName: "feature/review")
    try await store.saveGitHubReviewSessionAssociation(association)
    let saved = try #require(try await store.githubReviewSessionAssociations().first)
    #expect(saved.sourceAccountKey == association.sourceAccountKey)
    #expect(saved.branchName == "feature/review")
    let launch = try #require(GitHubReviewSessionLaunch(saved))
    #expect(launch.resolving(to: "session").association.branchName == "feature/review")
  }
}
