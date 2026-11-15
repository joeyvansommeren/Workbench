import Foundation
import GRDB
import Testing
@testable import AgentHubCore

struct SessionResultStoreTests {
  @Test func migrationPreservesExistingDataAndStoresAllThreeRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("metadata.sqlite").path
    let baseline = try SessionMetadataStore(path: path)
    try await baseline.setCustomName("Keep this", for: "existing")
    let state = SessionWorkspaceState(selectedRepositoryPaths: ["/tmp/main"],
      monitoredSessionIds: ["existing"], openSessionTabIds: ["claude-existing"])
    try await baseline.saveWorkspaceState(state, for: .claude)
    // Reconstruct the exact previous schema by removing only this additive migration's tables.
    // All pre-existing schema and seeded rows remain unchanged.
    let db = try DatabaseQueue(path: path)
    try await db.write { database in
      for table in ["session_results", "project_launch_recipes", "workflow_finish_archives"] {
        try database.drop(table: table)
      }
      try database.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: [SessionMetadataStore.MigrationID.createResultReview])
    }
    let store = try SessionMetadataStore(path: path)
    #expect(try await store.getCustomName(for: "existing") == "Keep this")
    #expect(try store.readWorkspaceState(for: .claude) == state)
    var result = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    result.summary = "A real explicit result"
    try await store.saveSessionResult(result)
    var codexResult = result
    codexResult.provider = .codex
    try await store.saveSessionResult(codexResult)
    let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", destination: "http://localhost:3000/route")
    try await store.saveProjectLaunchRecipe(recipe)
    let archive = WorkflowFinishArchiveRecord(workflowID: "task", repositoryPath: "/tmp/main",
      branchName: "feature", pullRequestURL: "https://github.com/example/repo/pull/1",
      pullRequestHeadSHA: "head", archivedAt: Date(timeIntervalSince1970: 1))
    try await store.saveWorkflowFinishArchive(archive)
    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.loadSessionResults().count == 2)
    #expect(try await reopened.loadProjectLaunchRecipe(repositoryPath: "/tmp/main") == recipe)
    #expect(try await reopened.loadWorkflowFinishArchives() == [archive])
  }
}
