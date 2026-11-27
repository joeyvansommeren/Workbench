import AgentWorkflowLinear
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Linear queue transition journal")
struct LinearQueueTransitionJournalTests {
  @Test("Migration v25 preserves existing session data and orchestrator records")
  func preservesBaseline() async throws {
    let databaseQueue = try DatabaseQueue()
    let donor = try SessionMetadataStore(databaseQueue: DatabaseQueue())
    let oldVersion = SessionMetadataStore.MigrationID.addOrchestratorAllocationDisposition
    try donor.migrator.migrate(databaseQueue, upTo: oldVersion)
    let expected = try await databaseQueue.write { database in
      try database.execute(sql: """
        INSERT INTO session_metadata (sessionId, customName, createdAt, updatedAt)
        VALUES ('session', 'Existing session', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """)
      try database.execute(sql: """
        INSERT INTO orchestrator_runs (id, payload) VALUES ('existing', x'AC0D')
        """)
      let sessionRows = try Row.fetchAll(database, sql: "SELECT * FROM session_metadata")
      let runRows = try Row.fetchAll(database, sql: "SELECT * FROM orchestrator_runs")
      return (sessionRows, runRows)
    }
    let store = try SessionMetadataStore(databaseQueue: databaseQueue)
    let plan = try makePlan()
    #expect(try await store.prepareLinearQueueTransition(plan) == .prepared)
    let actual = try await databaseQueue.read { database in
      let sessionRows = try Row.fetchAll(database, sql: "SELECT * FROM session_metadata")
      let runRows = try Row.fetchAll(database, sql: "SELECT * FROM orchestrator_runs")
      return (sessionRows, runRows)
    }
    #expect(expected.0 == actual.0)
    #expect(expected.1 == actual.1)
  }

  @Test("Submission survives reopen, is exclusive, and is resolved only once")
  func recoversInFlightIntent() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("metadata.sqlite").path
    let first = try SessionMetadataStore(path: path)
    let second = try SessionMetadataStore(path: path)
    let plan = try makePlan()
    #expect(try await first.prepareLinearQueueTransition(plan) == .prepared)
    let now = Date(timeIntervalSince1970: 100)
    async let firstAcquired = first.beginLinearQueueSubmission(plan, from: .prepared, at: now)
    async let secondAcquired = second.beginLinearQueueSubmission(plan, from: .prepared, at: now)
    let acquired = try await [firstAcquired, secondAcquired]
    #expect(acquired.compactMap { $0 }.count == 1)
    let attempt = try #require(acquired.compactMap { $0 }.first)
    let submitted = LinearQueueTransitionPhase.submitted(attempt)
    let reopened = try SessionMetadataStore(path: path)
    let pending = try await reopened.pendingLinearQueueTransitionIDs(account: plan.account)
    let operationID = try #require(pending.first)
    let restored = try #require(try await reopened.linearQueueTransitionRecord(
      operationID: operationID, account: plan.account))
    #expect(restored.plan == plan)
    #expect(restored.phase == submitted)
    let unauthorizedAccount = LinearQueueAccount(workspaceID: plan.account.workspaceID, userID: "other")
    #expect(try await reopened.pendingLinearQueueTransitionIDs(account: unauthorizedAccount).isEmpty)
    #expect(try await reopened.linearQueueTransitionPlan(operationID: operationID, account: unauthorizedAccount) == nil)
    #expect(try await reopened.prepareLinearQueueTransition(restored.plan) == submitted)
    #expect(try await reopened.beginLinearQueueSubmission(plan, from: .prepared, at: now) == nil)
    #expect(try await reopened.beginLinearQueueSubmission(plan, from: submitted, at: now) == nil)
    let competing = try makePlan()
    await #expect(throws: LinearQueueError.operationConflict) {
      try await reopened.prepareLinearQueueTransition(competing)
    }
    let differentPayload = try makePlan(operationID: plan.operationID, targetState: "other-state")
    await #expect(throws: LinearQueueError.operationConflict) {
      try await reopened.prepareLinearQueueTransition(differentPayload)
    }
    let confirmed = LinearQueueTransitionPhase.confirmed(revision: "observed")
    #expect(try await reopened.resolveLinearQueueTransition(plan, from: submitted, phase: confirmed) == confirmed)
    #expect(try await first.resolveLinearQueueTransition(
      plan, from: .prepared, phase: .conflict(.ownerChanged)) == confirmed)
    #expect(try await second.prepareLinearQueueTransition(competing) == .prepared)
  }

  @Test("An operation cannot become remote-confirmed before submission")
  func cannotSkipSubmission() async throws {
    let store = try SessionMetadataStore(databaseQueue: DatabaseQueue())
    let plan = try makePlan()
    #expect(try await store.prepareLinearQueueTransition(plan) == .prepared)
    await #expect(throws: LinearQueueError.operationConflict) {
      try await store.resolveLinearQueueTransition(plan, from: .prepared, phase: .confirmed(revision: "observed"))
    }
    #expect(try await store.prepareLinearQueueTransition(plan) == .prepared)
  }

  @Test("The journal rolls back known unsent attempts and caps retries atomically")
  func boundedRecovery() async throws {
    let store = try SessionMetadataStore(databaseQueue: DatabaseQueue())
    let plan = try makePlan()
    let now = Date(timeIntervalSince1970: 100)
    let ready = now.addingTimeInterval(LinearQueueTransitionAttempt.retryDelay)
    #expect(try await store.prepareLinearQueueTransition(plan) == .prepared)
    let unsent = try #require(try await store.beginLinearQueueSubmission(plan, from: .prepared, at: now))
    try await store.rollBackUnsentLinearQueueSubmission(plan, attempt: unsent, to: .prepared)
    #expect(try await store.prepareLinearQueueTransition(plan) == .prepared)
    let initial = try #require(try await store.beginLinearQueueSubmission(plan, from: .prepared, at: now))
    let initialPhase = LinearQueueTransitionPhase.submitted(initial)
    let retry = try #require(try await store.beginLinearQueueSubmission(plan, from: initialPhase, at: ready))
    let retryPhase = LinearQueueTransitionPhase.submitted(retry)
    #expect(retry.number == .retry)
    #expect(try await store.beginLinearQueueSubmission(plan, from: initialPhase, at: ready) == nil)
    #expect(try await store.beginLinearQueueSubmission(plan, from: retryPhase, at: ready) == nil)
    await #expect(throws: LinearQueueError.operationConflict) {
      try await store.resolveLinearQueueTransition(plan, from: retryPhase, phase: .rejected(.rateLimited))
    }
    try await store.rollBackUnsentLinearQueueSubmission(plan, attempt: retry, to: initialPhase)
    #expect(try await store.prepareLinearQueueTransition(plan) == initialPhase)
    #expect(try await store.resolveLinearQueueTransition(
      plan, from: initialPhase, phase: .rejected(.forbidden)) == .rejected(.forbidden))
    #expect(try await store.pendingLinearQueueTransitionIDs(account: plan.account).isEmpty)
    #expect(try await store.prepareLinearQueueTransition(makePlan()) == .prepared)
  }

  private func makePlan(operationID: UUID = UUID(), targetState: String = "active") throws
    -> LinearQueueTransitionPlan {
    let data = Data(
      """
      {
        "id":"issue","identifier":"TEST-1","title":"Fixture",
        "team":{"id":"team"},"project":{"id":"project"},"assignee":null,
        "state":{"id":"entry","name":"Ready","type":"unstarted","position":1,"color":"#000000"},
        "updatedAt":"initial","priority":0,"sortOrder":1
      }
      """.utf8)
    let issue = try JSONDecoder().decode(LinearQueueIssue.self, from: data)
    return try LinearQueueTransitionPlan(
      operationID: operationID, account: .init(workspaceID: "workspace", userID: "person"),
      projectID: "project", issue: issue, targetStateID: targetState)
  }
}
