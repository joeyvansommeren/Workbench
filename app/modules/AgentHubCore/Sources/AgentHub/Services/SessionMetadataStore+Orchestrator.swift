import AgentWorkflowCore
import Foundation
import GRDB

extension SessionMetadataStore: OrchestratorMetadataStoring {
  public func createOrchestratorRun(_ run: OrchestratorRun) async throws {
    guard run.state == .draft, run.revision == 0, run.providers != nil, run.queueScope != nil else {
      throw OrchestratorMetadataError.runConflict(run.id)
    }
    try await dbQueue.write { db in
      if let existing = try Self.orchestratorRun(run.id, in: db) {
        guard existing.policy == run.policy, existing.selection == run.selection,
          existing.providers == run.providers, existing.queueScope == run.queueScope
        else {
          throw OrchestratorMetadataError.runConflict(run.id)
        }
        return
      }
      try db.execute(
        sql: "INSERT INTO orchestrator_runs (id, payload) VALUES (?, ?)",
        arguments: [run.id.uuidString, try JSONEncoder().encode(run)])
      for selected in run.selection {
        let item = try OrchestratorQueueItem(run: run, itemID: selected.id)
        try db.execute(
          sql: "INSERT INTO orchestrator_queue_items (runID, id, payload) VALUES (?, ?, ?)",
          arguments: [run.id.uuidString, item.id.uuidString, try JSONEncoder().encode(item)])
      }
    }
  }

  public func orchestratorRuns() async throws -> [OrchestratorRun] {
    try await dbQueue.read { database in
      try Data.fetchAll(database, sql: "SELECT payload FROM orchestrator_runs ORDER BY rowid")
        .map { try JSONDecoder().decode(OrchestratorRun.self, from: $0) }
    }
  }

  public func recordOrchestratorThread(_ thread: OrchestratorThread) async throws {
    try await dbQueue.write { database in
      guard thread.role != .implementer else { throw OrchestratorThreadError.invalidOwner }
      guard let run = try Self.orchestratorRun(thread.runID, in: database) else {
        throw OrchestratorMetadataError.missingRun(thread.runID)
      }
      guard let provider = run.providers?.provider(for: thread.role),
        provider.rawValue.utf8.elementsEqual(thread.provider.rawValue.utf8)
      else { throw OrchestratorMetadataError.providerPolicyMismatch(run.id) }
      try Self.recordOrchestratorThread(thread, in: database)
    }
  }

  public func orchestratorThreads(runID: UUID) async throws -> [OrchestratorThread] {
    try await dbQueue.read { database in
      try Self.orchestratorThreads(runID: runID, in: database)
    }
  }

  public func bindOrchestratorThread(
    id: UUID, pendingLaunchID: UUID, session: OrchestratorSessionIdentity
  ) async throws {
    try await dbQueue.write { database in
      var thread = try Self.orchestratorThread(id, in: database)
      guard thread.role != .implementer else { throw OrchestratorThreadError.invalidOwner }
      try thread.bind(pendingLaunchID: pendingLaunchID, session: session)
      try Self.updateOrchestratorThread(thread, in: database)
    }
  }

  public func closeOrchestratorThread(id: UUID, reason: OrchestratorThreadCloseReason) async throws {
    try await dbQueue.write { database in
      var thread = try Self.orchestratorThread(id, in: database)
      try thread.close(reason)
      try Self.updateOrchestratorThread(thread, in: database)
    }
  }

  public func orchestratorRun(id: UUID) async throws -> OrchestratorRun? {
    try await dbQueue.read { try Self.orchestratorRun(id, in: $0) }
  }

  public func orchestratorItems(runID: UUID) async throws -> [OrchestratorQueueItem] {
    try await dbQueue.read { db in
      guard let run = try Self.orchestratorRun(runID, in: db) else {
        throw OrchestratorMetadataError.missingRun(runID)
      }
      return try run.selection.map { try Self.orchestratorItem(runID, $0.id, in: db) }
    }
  }

  public func applyOrchestratorEvent(_ event: OrchestratorRunEvent) async throws
    -> OrchestratorTransitionResult
  {
    try await dbQueue.write { db in
      guard var run = try Self.orchestratorRun(event.runID, in: db) else {
        throw OrchestratorMetadataError.missingRun(event.runID)
      }
      guard try !Self.isOrchestratorEventReplay(event, id: event.id, in: db) else {
        return .duplicate
      }
      let items: [OrchestratorQueueItem]
      switch event.command {
      case .confirmStopped, .confirmCompleted:
        items = try Self.orchestratorItems(runID: run.id, in: db)
        guard try !Self.hasPendingAllocation(runID: run.id, in: db) else {
          throw OrchestratorTransitionError.workRemains
        }
      default:
        items = []
      }
      if case .confirmProviders(let providers) = event.command {
        try Self.checkExistingProviders(run: run, providers: providers, in: db)
      }
      let result = try OrchestratorStateMachine.apply(event, to: &run, items: items)
      try db.execute(
        sql: "UPDATE orchestrator_runs SET payload = ? WHERE id = ?",
        arguments: [try JSONEncoder().encode(run), run.id.uuidString])
      try Self.recordOrchestratorEvent(event, id: event.id, runID: run.id, in: db)
      return result
    }
  }

  public func applyOrchestratorEvent(_ event: OrchestratorItemEvent) async throws
    -> OrchestratorTransitionResult
  {
    try await dbQueue.write { db in
      guard let run = try Self.orchestratorRun(event.runID, in: db) else {
        throw OrchestratorMetadataError.missingRun(event.runID)
      }
      var item = try Self.orchestratorItem(event.runID, event.itemID, in: db)
      guard try !Self.isOrchestratorEventReplay(event, id: event.id, in: db) else {
        return .duplicate
      }
      let priorAttemptID = item.attempt?.id
      let result = try OrchestratorStateMachine.apply(event, to: &item, run: run)
      guard result == .applied else { return result }

      if let attempt = item.attempt, attempt.id != priorAttemptID {
        let initialOperationID = item.attempts.first?.operationID ?? attempt.operationID
        guard let operation = try Self.orchestratorOperation(initialOperationID, in: db),
          operation.allocated,
          operation.request.runID == item.runID, operation.request.itemID == item.id,
          operation.request.ticketRunID == attempt.ticketRunID,
          operation.request.branchRunID == attempt.branchRunID,
          operation.request.implementerProvider.rawValue.utf8.elementsEqual(attempt.provider.rawValue.utf8)
        else { throw OrchestratorMetadataError.allocationPending(initialOperationID) }

        let activeCount = try Self.orchestratorItems(runID: run.id, in: db)
          .count(where: { $0.id != item.id && $0.state.holdsDispatchSlot })
        guard activeCount < run.policy.maximumConcurrentImplementations else {
          throw OrchestratorTransitionError.dispatchDenied(.concurrencyLimitReached)
        }

        if attempt.operationID != initialOperationID,
          try Self.orchestratorOperation(attempt.operationID, in: db) != nil
        {
          throw OrchestratorMetadataError.allocationConflict(attempt.operationID)
        }

        try Self.claim(item, in: db)
        try db.execute(
          sql: """
            INSERT INTO orchestrator_attempts (id, runID, itemID, operationID)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [
            attempt.id.uuidString, item.runID.uuidString, item.id.uuidString,
            attempt.operationID.uuidString,
          ])
        try Self.recordOrchestratorThread(
          OrchestratorThread(
            id: attempt.id, runID: item.runID, itemID: item.id, role: .implementer,
            provider: attempt.provider, pendingLaunchID: attempt.pendingLaunchID),
          in: db)
      }

      if case .confirmLaunch(_, let pendingLaunchID?, let session) = event.command,
        let attempt = item.attempt
      {
        var thread = try Self.orchestratorThread(attempt.id, in: db)
        try thread.bind(pendingLaunchID: pendingLaunchID, session: session)
        try Self.updateOrchestratorThread(thread, in: db)
      }
      try db.execute(
        sql: "UPDATE orchestrator_queue_items SET payload = ? WHERE runID = ? AND id = ?",
        arguments: [try JSONEncoder().encode(item), item.runID.uuidString, item.id.uuidString])
      try Self.releaseTerminalClaim(item, in: db)
      try Self.recordOrchestratorEvent(event, id: event.id, runID: run.id, in: db)
      return result
    }
  }

  public func reserveWorkflowAllocation(_ request: WorkflowAllocationRequest) async throws {
    try await dbQueue.write { db in
      if let operation = try Self.orchestratorOperation(request.operationID, in: db) {
        guard operation.request == request else {
          throw OrchestratorMetadataError.allocationConflict(request.operationID)
        }
        guard !operation.rejected else {
          throw OrchestratorMetadataError.allocationRejected(request.operationID)
        }
        return
      }
      let item = try Self.orchestratorItem(request.runID, request.itemID, in: db)
      let alreadyAttempted = try Bool.fetchOne(
        db, sql: "SELECT EXISTS (SELECT 1 FROM orchestrator_attempts WHERE operationID = ?)",
        arguments: [request.operationID.uuidString]) ?? false
      guard !alreadyAttempted else {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }
      guard item.issue == request.issue, item.state == .queued else {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }
      guard let run = try Self.orchestratorRun(item.runID, in: db) else {
        throw OrchestratorMetadataError.missingRun(item.runID)
      }
      guard run.providers?.matches(request) == true else {
        throw OrchestratorMetadataError.providerPolicyMismatch(run.id)
      }
      guard run.queueScope != nil else {
        throw OrchestratorTransitionError.dispatchDenied(.queueScopeRequired)
      }
      let selected = run.selection.first { $0.id == item.id }
      if let repository = selected?.repository,
        !repository.repositoryPath.utf8.elementsEqual(request.repositoryPath.utf8)
          || !repository.baseBranch.utf8.elementsEqual(request.baseBranch.utf8)
      {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }
      if let selected, !selected.prerequisites.isEmpty {
        guard item.dependencyVerification?.baseCommitID.utf8.elementsEqual(request.baseCommitID.utf8) == true,
          !run.issuesBlockedByDependencyCycles.contains(item.issue)
        else { throw OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified) }
      }
      let alreadyReserved = try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM orchestrator_operations WHERE runID = ? AND itemID = ? AND rejected = 0
          )
          """,
        arguments: [item.runID.uuidString, item.id.uuidString]) ?? false
      guard !alreadyReserved else {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }

      try Self.claim(item, in: db)
      try db.execute(
        sql: "INSERT INTO orchestrator_operations (id, runID, itemID, request) VALUES (?, ?, ?, ?)",
        arguments: [
          request.operationID.uuidString, item.runID.uuidString, item.id.uuidString,
          try JSONEncoder().encode(request),
        ])
    }
  }

  public func pendingWorkflowAllocations() async throws -> [PendingWorkflowAllocation] {
    try await dbQueue.read { db in
      let decoder = JSONDecoder()
      return try Row.fetchAll(
        db, sql: """
          SELECT id, runID, itemID, request FROM orchestrator_operations
          WHERE allocated = 0 AND rejected = 0 ORDER BY rowid
          """
      ).map { row in
        let rawID: (any DatabaseValueConvertible)? = row["id"]
        let rawRequest: (any DatabaseValueConvertible)? = row["request"]
        let rawRunID: (any DatabaseValueConvertible)? = row["runID"]
        let rawItemID: (any DatabaseValueConvertible)? = row["itemID"]
        let operationID = (rawID as? String).flatMap(UUID.init(uuidString:))
        guard let payload = rawRequest as? Data,
          let request = try? decoder.decode(WorkflowAllocationRequest.self, from: payload),
          request.operationID == operationID,
          request.runID.uuidString == rawRunID as? String,
          request.itemID.uuidString == rawItemID as? String
        else { return .unreadable(operationID: operationID) }
        return .request(request)
      }
    }
  }

  public func acknowledgedWorkflowAllocation(runID: UUID, itemID: UUID) async throws
    -> WorkflowAllocationRequest?
  {
    try await dbQueue.read { database in
      try Data.fetchOne(
        database, sql: """
          SELECT request FROM orchestrator_operations
          WHERE runID = ? AND itemID = ? AND allocated = 1 AND rejected = 0
          """, arguments: [runID.uuidString, itemID.uuidString]
      ).map { try JSONDecoder().decode(WorkflowAllocationRequest.self, from: $0) }
    }
  }

  public func completeWorkflowAllocation(_ receipt: WorkflowAllocationReceipt) async throws {
    try await dbQueue.write { db in
      let request = receipt.request
      guard let operation = try Self.orchestratorOperation(request.operationID, in: db) else {
        throw OrchestratorMetadataError.missingAllocation(request.operationID)
      }
      guard operation.request == request, !operation.rejected else {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }
      try db.execute(
        sql: "UPDATE orchestrator_operations SET allocated = 1 WHERE id = ?",
        arguments: [request.operationID.uuidString])
      let item = try Self.orchestratorItem(request.runID, request.itemID, in: db)
      try Self.releaseTerminalClaim(item, in: db)
    }
  }

  public func rejectWorkflowAllocation(_ request: WorkflowAllocationRequest) async throws {
    try await dbQueue.write { database in
      guard let operation = try Self.orchestratorOperation(request.operationID, in: database) else {
        throw OrchestratorMetadataError.missingAllocation(request.operationID)
      }
      guard operation.request == request, !operation.allocated else {
        throw OrchestratorMetadataError.allocationConflict(request.operationID)
      }
      // A late replay of a rejected request must not release a replacement's claim.
      guard !operation.rejected else { return }
      try database.execute(
        sql: "UPDATE orchestrator_operations SET rejected = 1 WHERE id = ?",
        arguments: [request.operationID.uuidString])
      try database.execute(
        sql: "DELETE FROM orchestrator_claims WHERE runID = ? AND itemID = ?",
        arguments: [request.runID.uuidString, request.itemID.uuidString])
    }
  }

  private static func orchestratorItems(runID: UUID, in database: Database)
    throws -> [OrchestratorQueueItem]
  {
    try Data.fetchAll(
      database, sql: "SELECT payload FROM orchestrator_queue_items WHERE runID = ?",
      arguments: [runID.uuidString]
    ).map { try JSONDecoder().decode(OrchestratorQueueItem.self, from: $0) }
  }

  private static func orchestratorThreads(runID: UUID, in database: Database)
    throws -> [OrchestratorThread]
  {
    let decoder = JSONDecoder()
    return try Data.fetchAll(
      database, sql: "SELECT payload FROM orchestrator_threads WHERE runID = ? ORDER BY rowid",
      arguments: [runID.uuidString]
    ).map { try decoder.decode(OrchestratorThread.self, from: $0) }
  }

  private static func recordOrchestratorThread(_ thread: OrchestratorThread, in database: Database)
    throws
  {
    if let data = try Data.fetchOne(
      database, sql: "SELECT payload FROM orchestrator_threads WHERE id = ?",
      arguments: [thread.id.uuidString])
    {
      let saved = try JSONDecoder().decode(OrchestratorThread.self, from: data)
      guard saved.runID == thread.runID, saved.itemID == thread.itemID, saved.role == thread.role,
        saved.provider.rawValue.utf8.elementsEqual(thread.provider.rawValue.utf8),
        saved.pendingLaunchID == thread.pendingLaunchID
      else { throw OrchestratorThreadError.conflict(thread.id) }
      return
    }
    guard thread.session == nil, thread.closeReason == nil else {
      throw OrchestratorThreadError.bindingMismatch
    }
    if thread.role == .orchestrator,
      try orchestratorThreads(runID: thread.runID, in: database).contains(where: {
        $0.role == .orchestrator && $0.closeReason == nil
      })
    {
      throw OrchestratorThreadError.mainThreadAlreadyOpen(thread.runID)
    }
    try database.execute(
      sql: """
        INSERT INTO orchestrator_threads (id, runID, itemID, pendingLaunchID, providerID, payload)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        thread.id.uuidString, thread.runID.uuidString, thread.itemID?.uuidString,
        thread.pendingLaunchID.uuidString, Data(thread.provider.rawValue.utf8),
        try JSONEncoder().encode(thread),
      ])
  }

  private static func orchestratorThread(_ id: UUID, in database: Database)
    throws -> OrchestratorThread
  {
    guard let data = try Data.fetchOne(
      database, sql: "SELECT payload FROM orchestrator_threads WHERE id = ?",
      arguments: [id.uuidString])
    else { throw OrchestratorThreadError.missing(id) }
    return try JSONDecoder().decode(OrchestratorThread.self, from: data)
  }

  private static func updateOrchestratorThread(_ thread: OrchestratorThread, in database: Database)
    throws
  {
    try database.execute(
      sql: "UPDATE orchestrator_threads SET sessionID = ?, payload = ? WHERE id = ?",
      arguments: [
        thread.session.map { Data($0.sessionID.utf8) }, try JSONEncoder().encode(thread),
        thread.id.uuidString,
      ])
  }

  private static func isOrchestratorEventReplay(
    _ event: some Encodable, id: UUID, in database: Database
  ) throws -> Bool {
    guard let saved = try Data.fetchOne(
      database, sql: "SELECT payload FROM orchestrator_transition_events WHERE id = ?",
      arguments: [id.uuidString])
    else { return false }
    guard try saved == encodeOrchestratorEvent(event) else {
      throw OrchestratorTransitionError.conflictingEvent
    }
    return true
  }

  private static func recordOrchestratorEvent(
    _ event: some Encodable, id: UUID, runID: UUID, in database: Database
  ) throws {
    try database.execute(
      sql: "INSERT INTO orchestrator_transition_events (id, runID, payload) VALUES (?, ?, ?)",
      arguments: [id.uuidString, runID.uuidString, try encodeOrchestratorEvent(event)])
  }

  private static func encodeOrchestratorEvent(_ event: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(event)
  }

  private static func orchestratorRun(_ id: UUID, in db: Database) throws -> OrchestratorRun? {
    try Data.fetchOne(
      db, sql: "SELECT payload FROM orchestrator_runs WHERE id = ?", arguments: [id.uuidString]
    ).map { try JSONDecoder().decode(OrchestratorRun.self, from: $0) }
  }

  private static func orchestratorItem(_ runID: UUID, _ itemID: UUID, in db: Database)
    throws -> OrchestratorQueueItem
  {
    guard let data = try Data.fetchOne(
      db, sql: "SELECT payload FROM orchestrator_queue_items WHERE runID = ? AND id = ?",
      arguments: [runID.uuidString, itemID.uuidString])
    else { throw OrchestratorMetadataError.missingItem(itemID) }
    return try JSONDecoder().decode(OrchestratorQueueItem.self, from: data)
  }

  private static func orchestratorOperation(_ id: UUID, in db: Database)
    throws -> (request: WorkflowAllocationRequest, allocated: Bool, rejected: Bool)?
  {
    guard let row = try Row.fetchOne(
      db, sql: "SELECT request, allocated, rejected FROM orchestrator_operations WHERE id = ?",
      arguments: [id.uuidString])
    else { return nil }
    let request = try JSONDecoder().decode(WorkflowAllocationRequest.self, from: row["request"])
    return (request, row["allocated"], row["rejected"])
  }

  private static func checkExistingProviders(
    run: OrchestratorRun, providers: OrchestratorRunProviders, in database: Database
  ) throws {
    let requests = try Data.fetchAll(
      database, sql: "SELECT request FROM orchestrator_operations WHERE runID = ? AND rejected = 0",
      arguments: [run.id.uuidString])
    let decoder = JSONDecoder()
    for data in requests {
      let request = try decoder.decode(WorkflowAllocationRequest.self, from: data)
      let item = try orchestratorItem(run.id, request.itemID, in: database)
      if item.state.isTerminal {
        if [.failed, .cancelled].contains(item.state), item.retryCount < run.policy.maximumRetries,
          let attempt = item.attempt,
          !providers.implementer.rawValue.utf8.elementsEqual(attempt.provider.rawValue.utf8)
        {
          throw OrchestratorMetadataError.providerPolicyMismatch(run.id)
        }
      } else if !providers.matches(request) {
        throw OrchestratorMetadataError.providerPolicyMismatch(run.id)
      }
    }
    for thread in try orchestratorThreads(runID: run.id, in: database) where thread.closeReason == nil {
      guard providers.provider(for: thread.role).rawValue.utf8.elementsEqual(thread.provider.rawValue.utf8)
      else { throw OrchestratorMetadataError.providerPolicyMismatch(run.id) }
    }
  }

  private static func hasPendingAllocation(runID: UUID, in database: Database) throws -> Bool {
    try Bool.fetchOne(
      database, sql: """
        SELECT EXISTS (
          SELECT 1 FROM orchestrator_operations WHERE runID = ? AND allocated = 0 AND rejected = 0
        )
        """, arguments: [runID.uuidString]) ?? false
  }

  private static func claim(_ item: OrchestratorQueueItem, in db: Database) throws {
    let source = item.issue.source
    let key: StatementArguments = [
      Data(source.trackerID.utf8), Data(source.accountID.utf8),
      Data(source.scopeID.utf8), Data(item.issue.issueID.utf8),
    ]
    if let row = try Row.fetchOne(
      db,
      sql: """
        SELECT runID, itemID FROM orchestrator_claims
        WHERE trackerID = ? AND accountID = ? AND scopeID = ? AND issueID = ?
        """,
      arguments: key)
    {
      guard row["runID"] as String == item.runID.uuidString,
        row["itemID"] as String == item.id.uuidString
      else { throw OrchestratorMetadataError.issueAlreadyClaimed(item.issue) }
      return
    }
    try db.execute(
      sql: """
        INSERT INTO orchestrator_claims (trackerID, accountID, scopeID, issueID, runID, itemID)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: key + [item.runID.uuidString, item.id.uuidString])
  }

  private static func releaseTerminalClaim(_ item: OrchestratorQueueItem, in db: Database) throws {
    guard item.state.isTerminal else { return }
    try db.execute(
      sql: """
        DELETE FROM orchestrator_claims WHERE runID = ? AND itemID = ?
        AND NOT EXISTS (
          SELECT 1 FROM orchestrator_operations
          WHERE runID = ? AND itemID = ? AND allocated = 0 AND rejected = 0
        )
        """,
      arguments: [
        item.runID.uuidString, item.id.uuidString, item.runID.uuidString, item.id.uuidString,
      ])
  }
}
