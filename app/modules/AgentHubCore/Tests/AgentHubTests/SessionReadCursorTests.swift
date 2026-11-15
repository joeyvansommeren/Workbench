import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session read cursors")
@MainActor
struct SessionReadCursorTests {
  @Test("Unknown load state does not invent unread updates")
  func loadAndAcknowledge() async {
    let store = CursorFake()
    let model = SessionReadCursorModel(store: store)
    let first = Date(timeIntervalSince1970: 100)
    #expect(!model.isUnread(provider: .claude, sessionID: "same", activity: first))
    await model.load()
    #expect(model.isUnread(provider: .claude, sessionID: "same", activity: first))
    await model.acknowledge(provider: .claude, sessionID: "same", activity: first)
    #expect(!model.isUnread(provider: .claude, sessionID: "same", activity: first))
    #expect(model.isUnread(provider: .codex, sessionID: "same", activity: first))
    #expect(
      model.isUnread(provider: .claude, sessionID: "same", activity: first.addingTimeInterval(1)))
    #expect(!model.isUnread(provider: .claude, sessionID: "same", activity: nil))
  }

  @Test("A delayed load cannot acknowledge a session after visibility changes")
  func delayedLoad() async {
    let store = SuspendedCursorStore()
    let model = SessionReadCursorModel(store: store)
    let cursor = SessionReadCursor(
      provider: .claude, sessionID: "one", activity: Date(timeIntervalSince1970: 10))
    var visible: SessionReadCursor? = cursor
    let task = Task { await SessionReadVisibility.acknowledge(cursor, model: model) { visible } }
    await store.waitForLoad()
    visible = nil
    await store.releaseLoad()
    await task.value
    #expect(await store.writes == [])
    #expect(model.isUnread(provider: .claude, sessionID: "one", activity: cursor.activity))
  }

  @Test("A newer acknowledgement survives an in-flight older write")
  func overlappingWrites() async {
    let store = SuspendedWriteStore()
    let model = SessionReadCursorModel(store: store)
    await model.load()
    let date = Date(timeIntervalSince1970: 100)
    let first = Task {
      await model.acknowledge(provider: .claude, sessionID: "one", activity: date)
    }
    await store.waitForWrite()
    await model.acknowledge(
      provider: .claude, sessionID: "one", activity: date.addingTimeInterval(1))
    await store.releaseWrite()
    await first.value
    #expect(await store.writes.map(\.activity) == [date, date.addingTimeInterval(1)])
  }

  @Test("A failed load does not invent unread updates")
  func failedLoad() async {
    let model = SessionReadCursorModel(store: FailedLoadStore())
    await model.load()
    #expect(!model.isUnread(provider: .claude, sessionID: "one", activity: .now))
  }

  @Test("A failed write can be retried without losing newer activity")
  func retry() async {
    let store = FailingCursorStore()
    let model = SessionReadCursorModel(store: store)
    await model.load()
    let date = Date(timeIntervalSince1970: 100)
    await model.acknowledge(provider: .claude, sessionID: "one", activity: date)
    await model.acknowledge(
      provider: .claude, sessionID: "one", activity: date.addingTimeInterval(1))
    #expect(await store.saved?.activity == date.addingTimeInterval(1))
  }

  @Test("SQLite migration preserves the real prior schema and cursor writes are monotonic")
  func migrationAndPersistence() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let donor = try SessionMetadataStore(path: folder.appendingPathComponent("donor.sqlite").path)
    let path = folder.appendingPathComponent("baseline.sqlite").path
    let db = try DatabaseQueue(path: path)
    try donor.migrator.migrate(db, upTo: SessionMetadataStore.MigrationID.createResultReview)
    let result = SessionResult(provider: .claude, sessionID: "saved", projectPath: "/tmp/work")
    let payload = try JSONEncoder().encode(result)
    let repositories = try JSONEncoder().encode(["/tmp/work"])
    let sessions = try JSONEncoder().encode(["saved"])
    let expansion = try JSONEncoder().encode(["repo:/tmp/work": true])
    try await db.write { database in
      try database.execute(
        sql:
          "INSERT INTO session_metadata (sessionId, customName, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
        arguments: [
          "saved", "Keep this", Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 10),
        ])
      try database.execute(
        sql: """
          INSERT INTO session_workspace_state
          (provider, selectedRepositoryPathsData, monitoredSessionIdsData, expansionStateData, updatedAt)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          SessionProviderKind.claude.rawValue, repositories, sessions, expansion,
          Date(timeIntervalSince1970: 10),
        ])
      try database.execute(
        sql: "INSERT INTO session_results (recordKey, payload) VALUES (?, ?)",
        arguments: [result.id, payload])
    }
    try db.close()
    let store = try SessionMetadataStore(path: path)
    #expect(try await store.getCustomName(for: "saved") == "Keep this")
    #expect(try await store.loadSessionResults() == [result])
    let workspace = try store.readWorkspaceState(for: .claude)
    #expect(workspace.selectedRepositoryPaths == ["/tmp/work"])
    #expect(workspace.monitoredSessionIds == ["saved"])
    #expect(workspace.expansionState == ["repo:/tmp/work": true])
    let newer = Date(timeIntervalSinceReferenceDate: 817_000_000.1234561)
    try await store.acknowledgeReadCursor(
      .init(provider: .claude, sessionID: "same", activity: newer))
    try await store.acknowledgeReadCursor(
      .init(provider: .claude, sessionID: "same", activity: newer.addingTimeInterval(-10)))
    try await store.acknowledgeReadCursor(
      .init(provider: .codex, sessionID: "same", activity: newer.addingTimeInterval(-20)))
    let reopened = try SessionMetadataStore(path: path)
    let cursors = try await reopened.loadReadCursors()
    #expect(cursors.contains(.init(provider: .claude, sessionID: "same", activity: newer)))
    #expect(
      cursors.contains(
        .init(provider: .codex, sessionID: "same", activity: newer.addingTimeInterval(-20))))
  }
}

private actor CursorFake: SessionReadCursorStoreProtocol {
  var cursors: [SessionReadCursor] = []
  func loadReadCursors() -> [SessionReadCursor] { cursors }
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) { cursors.append(cursor) }
}

private actor SuspendedCursorStore: SessionReadCursorStoreProtocol {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private var hasStarted = false
  private(set) var writes: [SessionReadCursor] = []
  func loadReadCursors() async -> [SessionReadCursor] {
    hasStarted = true
    started?.resume()
    await withCheckedContinuation { continuation = $0 }
    return []
  }
  func waitForLoad() async {
    if hasStarted { return }
    await withCheckedContinuation { started = $0 }
  }
  func releaseLoad() {
    continuation?.resume()
    continuation = nil
  }
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) { writes.append(cursor) }
}

private actor FailingCursorStore: SessionReadCursorStoreProtocol {
  private var fail = true
  private(set) var saved: SessionReadCursor?
  func loadReadCursors() -> [SessionReadCursor] { [] }
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) throws {
    if fail {
      fail = false
      throw TestError.failed
    }
    saved = cursor
  }
  enum TestError: Error { case failed }
}

private actor SuspendedWriteStore: SessionReadCursorStoreProtocol {
  private(set) var writes: [SessionReadCursor] = []
  private var continuation: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  func loadReadCursors() -> [SessionReadCursor] { [] }
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) async {
    writes.append(cursor)
    guard writes.count == 1 else { return }
    started?.resume()
    await withCheckedContinuation { continuation = $0 }
  }
  func waitForWrite() async {
    if !writes.isEmpty { return }
    await withCheckedContinuation { started = $0 }
  }
  func releaseWrite() {
    continuation?.resume()
    continuation = nil
  }
}

private actor FailedLoadStore: SessionReadCursorStoreProtocol {
  enum Failure: Error { case unavailable }
  func loadReadCursors() throws -> [SessionReadCursor] { throw Failure.unavailable }
  func acknowledgeReadCursor(_ cursor: SessionReadCursor) {}
}
