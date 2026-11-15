import Foundation
import GRDB
import Testing

@testable import AgentHubCore

/// Migration-preservation tests for `v17_add_open_session_tab_ids`: a database
/// at the previous schema keeps every workspace-state field, and the new
/// column round-trips.
@Suite("Session metadata migration safety")
struct SessionMetadataMigrationSafetyTests {

  @Test("Open-tab migration preserves existing workspace state")
  func openTabMigrationPreservesWorkspaceState() async throws {
    let path = temporaryDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)
    let encoder = JSONEncoder()

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.addOpenSessionTabIds,
        in: db
      )
      // The baseline helper creates the table up to v9; add the later fork columns.
      try db.alter(table: "session_workspace_state") { t in
        t.add(column: "selectedFolderPathsData", .blob)
        t.add(column: "archivedSessionIdsData", .blob)
      }
      try db.execute(
        sql: """
          INSERT INTO session_workspace_state
          (provider, selectedRepositoryPathsData, monitoredSessionIdsData, expansionStateData,
           updatedAt, ownedWorktreePathsData, selectedFolderPathsData, archivedSessionIdsData)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          SessionProviderKind.claude.rawValue,
          try encoder.encode(["/tmp/project"]),
          try encoder.encode(["session-1", "session-2"]),
          try encoder.encode(["repo:/tmp/project": true]),
          Date(timeIntervalSince1970: 1_000),
          try encoder.encode(["/tmp/project-wt"]),
          try encoder.encode(["/tmp"]),
          try encoder.encode(["session-old"]),
        ]
      )
    }
    try dbQueue.close()

    let store = try SessionMetadataStore(path: path)
    #expect(
      try store.readWorkspaceState(for: .claude)
        == SessionWorkspaceState(
          selectedRepositoryPaths: ["/tmp/project"],
          selectedFolderPaths: ["/tmp"],
          monitoredSessionIds: ["session-1", "session-2"],
          archivedSessionIds: ["session-old"],
          ownedWorktreePaths: ["/tmp/project-wt"],
          expansionState: ["repo:/tmp/project": true],
          openSessionTabIds: []
        )
    )
    #expect(try store.readWorkspaceState(for: .codex) == SessionWorkspaceState())
  }

  @Test("Open tab ids round-trip with the rest of the workspace state")
  func openTabIdsRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    let state = SessionWorkspaceState(
      selectedRepositoryPaths: ["/tmp/project"],
      monitoredSessionIds: ["a", "b"],
      openSessionTabIds: ["claude-b", "claude-a"]
    )
    try await store.saveWorkspaceState(state, for: .claude)
    #expect(try store.readWorkspaceState(for: .claude) == state)
  }

  @Test("The open-tab migration is the last registered identifier")
  func migrationIsAppended() {
    #expect(
      SessionMetadataStore.migrationIdentifiers.last
        == SessionMetadataStore.MigrationID.addOpenSessionTabIds)
  }
}

private func temporaryDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_migration_safety_\(UUID().uuidString).sqlite")
    .path
}
