import AgentWorkflowLinear
import Foundation
import GRDB

extension SessionMetadataStore: LinearQueueTransitionJournaling {
  public func pendingLinearQueueTransitionIDs(account: LinearQueueAccount) async throws -> [UUID] {
    try await dbQueue.read { database in
      let ids = try String.fetchAll(
        database,
        sql: """
          SELECT operationID FROM linear_queue_transitions
          WHERE workspaceID = ? AND userID = ? AND active = 1 ORDER BY rowid
          """,
        arguments: [Data(account.workspaceID.utf8), Data(account.userID.utf8)])
      return try ids.map { id in
        guard let operationID = UUID(uuidString: id) else { throw LinearQueueError.operationConflict }
        return operationID
      }
    }
  }

  public func linearQueueTransitionRecord(operationID: UUID, account: LinearQueueAccount) async throws
    -> LinearQueueTransitionRecord? {
    try await dbQueue.read { database in
      let payload = try Data.fetchOne(
        database,
        sql: """
          SELECT payload FROM linear_queue_transitions
          WHERE operationID = ? AND workspaceID = ? AND userID = ?
          """,
        arguments: [operationID.uuidString, Data(account.workspaceID.utf8), Data(account.userID.utf8)])
      guard let payload else { return nil }
      let record = try JSONDecoder().decode(LinearQueueJournalRecord.self, from: payload)
      guard record.plan.operationID == operationID, record.plan.account == account else {
        throw LinearQueueError.operationConflict
      }
      return LinearQueueTransitionRecord(plan: record.plan, phase: record.phase)
    }
  }

  public func prepareLinearQueueTransition(_ plan: LinearQueueTransitionPlan) async throws
    -> LinearQueueTransitionPhase {
    try await writeLinearQueueJournal { database in
      if let record = try LinearQueueJournalRecord.fetch(for: plan, in: database) {
        return record.phase
      }
      let active = try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM linear_queue_transitions
            WHERE workspaceID = ? AND userID = ? AND issueID = ? AND active = 1
          )
          """,
        arguments: [
          Data(plan.account.workspaceID.utf8), Data(plan.account.userID.utf8), Data(plan.issueID.utf8)
        ]) ?? false
      guard !active else { throw LinearQueueError.operationConflict }
      let record = LinearQueueJournalRecord(plan: plan, phase: .prepared)
      try database.execute(
        sql: """
          INSERT INTO linear_queue_transitions (operationID, workspaceID, userID, issueID, payload, active)
          VALUES (?, ?, ?, ?, ?, 1)
          """,
        arguments: [
          plan.operationID.uuidString, Data(plan.account.workspaceID.utf8), Data(plan.account.userID.utf8),
          Data(plan.issueID.utf8), try JSONEncoder().encode(record)
        ])
      return .prepared
    }
  }

  public func beginLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase, at now: Date
  ) async throws -> LinearQueueTransitionAttempt? {
    try await writeLinearQueueJournal { database in
      guard var record = try LinearQueueJournalRecord.fetch(for: plan, in: database) else {
        throw LinearQueueError.operationConflict
      }
      guard record.phase == expected, let attempt = expected.nextAttempt(at: now) else { return nil }
      record.phase = .submitted(attempt)
      try record.save(in: database, active: true)
      return attempt
    }
  }

  public func rollBackUnsentLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, attempt: LinearQueueTransitionAttempt, to priorPhase: LinearQueueTransitionPhase
  ) async throws {
    try await writeLinearQueueJournal { database in
      guard var record = try LinearQueueJournalRecord.fetch(for: plan, in: database) else {
        throw LinearQueueError.operationConflict
      }
      guard record.phase == .submitted(attempt), priorPhase.nextAttempt(at: attempt.submittedAt) == attempt else {
        return
      }
      record.phase = priorPhase
      try record.save(in: database, active: true)
    }
  }

  public func resolveLinearQueueTransition(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase,
    phase: LinearQueueTransitionPhase
  ) async throws -> LinearQueueTransitionPhase {
    try await writeLinearQueueJournal { database in
      guard var record = try LinearQueueJournalRecord.fetch(for: plan, in: database) else {
        throw LinearQueueError.operationConflict
      }
      guard record.phase == expected else { return record.phase }
      switch (record.phase, phase) {
      case (.prepared, .conflict), (.submitted, .confirmed), (.submitted, .observedTarget):
        record.phase = phase
        try record.save(in: database, active: false)
      case (.submitted(let attempt), .rejected) where attempt.number == .initial:
        record.phase = phase
        try record.save(in: database, active: false)
      case (.confirmed, _), (.observedTarget, _), (.conflict, _), (.rejected, _):
        break
      default:
        throw LinearQueueError.operationConflict
      }
      return record.phase
    }
  }

  private func writeLinearQueueJournal<Value: Sendable>(
    _ update: @escaping @Sendable (Database) throws -> Value
  ) async throws -> Value {
    try await dbQueue.writeWithoutTransaction { database in
      // Reserve the writer before reading the journal so different connections
      // cannot both read the same phase and then contend to upgrade their locks.
      var result: Value?
      try database.inTransaction(.immediate) {
        result = try update(database)
        return .commit
      }
      guard let result else { throw LinearQueueError.operationConflict }
      return result
    }
  }
}

private struct LinearQueueJournalRecord: Codable {
  let plan: LinearQueueTransitionPlan
  var phase: LinearQueueTransitionPhase

  static func fetch(for plan: LinearQueueTransitionPlan, in database: Database) throws -> Self? {
    let payload = try Data.fetchOne(
      database,
      sql: "SELECT payload FROM linear_queue_transitions WHERE operationID = ?",
      arguments: [plan.operationID.uuidString])
    guard let payload else { return nil }
    let record = try JSONDecoder().decode(Self.self, from: payload)
    guard record.plan == plan else { throw LinearQueueError.operationConflict }
    return record
  }

  func save(in database: Database, active: Bool) throws {
    try database.execute(
      sql: "UPDATE linear_queue_transitions SET payload = ?, active = ? WHERE operationID = ?",
      arguments: [try JSONEncoder().encode(self), active, plan.operationID.uuidString])
  }
}
