import AgentWorkflowCore
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Orchestrator metadata persistence")
struct OrchestratorMetadataStoreTests {
  @Test("A real v22 database keeps session metadata, its terminal layout, and its accessory edge")
  func migrationPreservesBaseline() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let donor = try SessionMetadataStore(path: ":memory:")
    let queue = try DatabaseQueue(path: fixture.metadataPath)
    try donor.migrator.migrate(queue, upTo: SessionMetadataStore.MigrationID.createReviewSources)
    let tables = ["session_metadata", "terminal_workspaces", "session_relationships"]
    let before = try await queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO session_metadata (sessionId, customName, isPinned, createdAt, updatedAt)
          VALUES ('parent', 'Kept', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
          INSERT INTO terminal_workspaces (provider, sessionId, backend, snapshotData, updatedAt)
          VALUES ('codex', 'parent', 0, X'7B7D', CURRENT_TIMESTAMP);
          INSERT INTO session_relationships
          (sourceProvider, sourceSessionId, targetProvider, targetSessionId, kind, origin, createdAt, updatedAt)
          VALUES ('codex', 'parent', 'claude', 'child', 'accessoryChild', 'explicit',
                  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
          """)
      return try tables.map { try Row.fetchAll(database, sql: "SELECT * FROM \($0)") }
    }
    _ = try SessionMetadataStore(path: fixture.metadataPath)
    let after = try await queue.read { database in
      #expect(try database.tableExists("orchestrator_runs"))
      return try tables.map { try Row.fetchAll(database, sql: "SELECT * FROM \($0)") }
    }
    #expect(after == before)
  }

  @Test("Only one overlapping run claims an issue, with identities preserved through restart")
  func exclusiveClaims() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let secondConnection = try SessionMetadataStore(path: fixture.metadataPath)
    let (first, firstRequest) = try fixture.run()
    let (second, secondRequest) = try fixture.run()
    try await metadata.createOrchestratorRun(first)
    try await secondConnection.createOrchestratorRun(second)
    try await metadata.reserveWorkflowAllocation(firstRequest)
    await #expect(throws: OrchestratorMetadataError.issueAlreadyClaimed(firstRequest.issue)) {
      try await secondConnection.reserveWorkflowAllocation(secondRequest)
    }

    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    #expect(try await reopened.pendingWorkflowAllocations() == [.request(firstRequest)])
    #expect(try await reopened.orchestratorRun(id: first.id) == first)
    #expect(try await reopened.orchestratorItems(runID: first.id).map(\.issue) == [firstRequest.issue])
    #expect(firstRequest.implementerProvider.rawValue == "future-provider")
  }

  @Test("Reconciliation survives interruptions before and after the workflow store commits")
  func resumeAcrossStores() async throws {
    for workflowWriteFinished in [false, true] {
      let fixture = try Fixture()
      defer { fixture.cleanUp() }
      let metadata = try SessionMetadataStore(path: fixture.metadataPath)
      let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
      let (run, request) = try fixture.run()
      try await metadata.createOrchestratorRun(run)
      try await metadata.reserveWorkflowAllocation(request)
      if workflowWriteFinished {
        _ = try await workflows.ensureWorkflowAllocation(request)
      }

      let reopenedMetadata = try SessionMetadataStore(path: fixture.metadataPath)
      let reopenedWorkflows = try AgentWorkflowStore(path: fixture.workflowPath)
      let coordinator = OrchestratorAllocationCoordinator(
        metadata: reopenedMetadata, workflows: reopenedWorkflows)
      try await coordinator.reconcilePendingAllocations()
      #expect(try await reopenedMetadata.pendingWorkflowAllocations().isEmpty)
      let replay = try await coordinator.allocate(request)
      #expect(replay.receipt.request == request)
      #expect(replay.ticketRun.id == request.ticketRunID)
      #expect(replay.branchRun.id == request.branchRunID)
    }
  }

  @Test("After acknowledgement a fresh process can dispatch using only saved queue identity")
  func dispatchAfterAcknowledgement() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let runID: UUID
    do {
      let metadata = try SessionMetadataStore(path: fixture.metadataPath)
      let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
      let (run, request) = try fixture.run()
      runID = run.id
      try await metadata.createOrchestratorRun(run)
      try await OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows).allocate(request)
    }
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let item = try #require(try await reopened.orchestratorItems(runID: runID).first)
    let allocation = try #require(try await reopened.acknowledgedWorkflowAllocation(
      runID: runID, itemID: item.id))
    #expect(try await reopened.pendingWorkflowAllocations().isEmpty)
    _ = try await reopened.applyOrchestratorEvent(
      .init(id: UUID(), runID: runID, expectedRevision: 0, command: .start(at: allocation.createdAt)))
    let attempt = try OrchestratorDispatchAttempt(
      id: UUID(), operationID: allocation.operationID, runID: runID, itemID: item.id,
      pendingLaunchID: UUID(), provider: allocation.implementerProvider,
      ticketRunID: allocation.ticketRunID, branchRunID: allocation.branchRunID,
      baseCommitID: allocation.baseCommitID)
    #expect(try await reopened.applyOrchestratorEvent(allocation.event(
      .beginDispatch(attempt, at: allocation.createdAt, activeImplementations: 0),
      revision: item.revision)) == .applied)
  }

  @Test("A rejected allocation releases its claim and does not block independent recovery")
  func rejectCollisionDuringRecovery() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (occupiedRun, occupied) = try fixture.run(issueID: "existing")
    let (rejectedRun, rejected) = try fixture.run(ticketRunID: occupied.ticketRunID)
    let (healthyRun, healthy) = try fixture.run(issueID: "independent")
    try await metadata.createOrchestratorRun(occupiedRun)
    try await metadata.createOrchestratorRun(rejectedRun)
    try await metadata.createOrchestratorRun(healthyRun)
    _ = try await workflows.ensureWorkflowAllocation(occupied)
    try await metadata.reserveWorkflowAllocation(rejected)
    try await metadata.reserveWorkflowAllocation(healthy)

    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let coordinator = OrchestratorAllocationCoordinator(metadata: reopened, workflows: workflows)
    let failures = try await coordinator.reconcilePendingAllocations()
    #expect(failures.map(\.operationID) == [rejected.operationID])
    #expect(failures.first?.disposition == .rejected)
    #expect(try await reopened.pendingWorkflowAllocations().isEmpty)
    #expect(try await reopened.acknowledgedWorkflowAllocation(
      runID: healthy.runID, itemID: healthy.itemID) == healthy)
    await #expect(throws: OrchestratorMetadataError.allocationRejected(rejected.operationID)) {
      try await reopened.reserveWorkflowAllocation(rejected)
    }
    let (overlap, corrected) = try fixture.run()
    try await reopened.createOrchestratorRun(overlap)
    #expect(try await coordinator.allocate(corrected).receipt.request == corrected)
  }

}

extension OrchestratorMetadataStoreTests {
  @Test("Unreadable intent and occupied operation ID do not block healthy recovery")
  func isolateJournalFailures() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (_, old) = try fixture.run(issueID: "old-workflow")
    let (unreadableRun, unreadable) = try fixture.run(issueID: "unreadable")
    let (conflictingRun, conflicting) = try fixture.run(operationID: old.operationID)
    let (healthyRun, healthy) = try fixture.run(issueID: "healthy")
    for run in [unreadableRun, conflictingRun, healthyRun] {
      try await metadata.createOrchestratorRun(run)
    }
    for request in [unreadable, conflicting, healthy] {
      try await metadata.reserveWorkflowAllocation(request)
    }
    _ = try await workflows.ensureWorkflowAllocation(old)
    let queue = try DatabaseQueue(path: fixture.metadataPath)
    try await queue.write { database in
      try database.execute(
        sql: "UPDATE orchestrator_operations SET request = 42 WHERE id = ?",
        arguments: [unreadable.operationID.uuidString])
    }
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let coordinator = OrchestratorAllocationCoordinator(metadata: reopened, workflows: workflows)
    let failures = try await coordinator.reconcilePendingAllocations()
    #expect(failures.map(\.operationID) == [unreadable.operationID, conflicting.operationID])
    #expect(failures.map(\.disposition) == [.unreadable, .rejected])
    #expect(try await reopened.pendingWorkflowAllocations() == [.unreadable(operationID: unreadable.operationID)])
    #expect(try await reopened.acknowledgedWorkflowAllocation(
      runID: healthy.runID, itemID: healthy.itemID) == healthy)
    #expect(try await workflows.ensureWorkflowAllocation(old).receipt.request == old)
    let (replacementRun, replacement) = try fixture.run()
    try await reopened.createOrchestratorRun(replacementRun)
    #expect(try await coordinator.allocate(replacement).receipt.request == replacement)
  }

  @Test("A damaged receipt for the same workflow does not release the claim")
  func preserveClaimForAmbiguousReceipt() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (run, request) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    try await metadata.reserveWorkflowAllocation(request)
    _ = try await workflows.ensureWorkflowAllocation(request)
    let workflowDatabase = try DatabaseQueue(path: fixture.workflowPath)
    try await workflowDatabase.write { database in
      try database.execute(
        sql: "UPDATE workflow_allocation_receipts SET requestIdentity = X'FF' WHERE operationID = ?",
        arguments: [request.operationID.uuidString])
    }
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let coordinator = OrchestratorAllocationCoordinator(metadata: reopened, workflows: workflows)
    let failures = try await coordinator.reconcilePendingAllocations()
    #expect(failures.map(\.operationID) == [request.operationID])
    #expect(failures.map(\.disposition) == [.pending])
    let (overlap, otherRequest) = try fixture.run()
    try await reopened.createOrchestratorRun(overlap)
    await #expect(throws: OrchestratorMetadataError.issueAlreadyClaimed(request.issue)) {
      try await reopened.reserveWorkflowAllocation(otherRequest)
    }
  }

  @Test("A differently encoded Git branch cannot replace the approved mapping")
  func gitRefsAreComparedByBytes() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let (run, request) = try fixture.run(
      baseBranch: "release-e\u{0301}", approvedBaseBranch: "release-\u{00E9}")
    try await metadata.createOrchestratorRun(run)
    await #expect(throws: OrchestratorMetadataError.allocationConflict(request.operationID)) {
      try await metadata.reserveWorkflowAllocation(request)
    }
    #expect(try await metadata.pendingWorkflowAllocations().isEmpty)
  }

  @Test("Stop waits for an interrupted allocation to settle before releasing its claim")
  func stopWaitsForPendingAllocation() async throws {
    for workflowWriteFinished in [false, true] {
      let fixture = try Fixture()
      defer { fixture.cleanUp() }
      let metadata = try SessionMetadataStore(path: fixture.metadataPath)
      let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
      let (run, request) = try fixture.run()
      try await metadata.createOrchestratorRun(run)
      try await metadata.reserveWorkflowAllocation(request)
      if workflowWriteFinished { _ = try await workflows.ensureWorkflowAllocation(request) }
      _ = try await metadata.applyOrchestratorEvent(
        .init(id: UUID(), runID: run.id, expectedRevision: 0, command: .stop))
      _ = try await metadata.applyOrchestratorEvent(request.event(.requestCancellation, revision: 0))
      let stopped = OrchestratorRunEvent(
        id: UUID(), runID: run.id, expectedRevision: 1, command: .confirmStopped)
      let reopened = try SessionMetadataStore(path: fixture.metadataPath)
      await #expect(throws: OrchestratorTransitionError.workRemains) {
        try await reopened.applyOrchestratorEvent(stopped)
      }
      let coordinator = OrchestratorAllocationCoordinator(metadata: reopened, workflows: workflows)
      #expect(try await coordinator.reconcilePendingAllocations().isEmpty)
      #expect(try await reopened.applyOrchestratorEvent(stopped) == .applied)
      let (overlap, otherRequest) = try fixture.run()
      try await reopened.createOrchestratorRun(overlap)
      try await reopened.reserveWorkflowAllocation(otherRequest)
    }
  }

  @Test("The allocation disposition migration preserves a v23 receipt and issue claim")
  func migrationPreservesAllocation() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let donor = try SessionMetadataStore(path: ":memory:")
    let queue = try DatabaseQueue(path: fixture.metadataPath)
    try donor.migrator.migrate(queue, upTo: SessionMetadataStore.MigrationID.createOrchestratorRuns)
    let (run, request) = try fixture.run()
    let item = try OrchestratorQueueItem(run: run, itemID: request.itemID)
    try await queue.write { database in
      let encoder = JSONEncoder()
      let runPayload = try encoder.encode(run)
      var legacyRun = try #require(JSONSerialization.jsonObject(with: runPayload) as? [String: Any])
      legacyRun.removeValue(forKey: "providers")
      legacyRun.removeValue(forKey: "queueScope")
      try database.execute(
        sql: "INSERT INTO orchestrator_runs (id, payload) VALUES (?, ?)",
        arguments: [run.id.uuidString, try JSONSerialization.data(withJSONObject: legacyRun)])
      try database.execute(
        sql: "INSERT INTO orchestrator_queue_items (runID, id, payload) VALUES (?, ?, ?)",
        arguments: [run.id.uuidString, item.id.uuidString, try encoder.encode(item)])
      try database.execute(
        sql: """
          INSERT INTO orchestrator_operations (id, runID, itemID, request, allocated)
          VALUES (?, ?, ?, ?, 1)
          """,
        arguments: [request.operationID.uuidString, run.id.uuidString, item.id.uuidString,
                    try encoder.encode(request)])
      try database.execute(
        sql: """
          INSERT INTO orchestrator_claims (trackerID, accountID, scopeID, issueID, runID, itemID)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          Data(request.issue.source.trackerID.utf8), Data(request.issue.source.accountID.utf8),
          Data(request.issue.source.scopeID.utf8), Data(request.issue.issueID.utf8),
          run.id.uuidString, item.id.uuidString,
        ])
    }
    let migrated = try SessionMetadataStore(path: fixture.metadataPath)
    let restored = try #require(try await migrated.orchestratorRun(id: run.id))
    #expect(restored.providers == nil)
    #expect(restored.queueScope == nil)
    #expect(OrchestratorRunSummary(run: restored, items: [item]).providerChoiceRequired)
    #expect(try await migrated.acknowledgedWorkflowAllocation(runID: run.id, itemID: item.id) == request)
    let (overlap, otherRequest) = try fixture.run()
    try await migrated.createOrchestratorRun(overlap)
    await #expect(throws: OrchestratorMetadataError.issueAlreadyClaimed(request.issue)) {
      try await migrated.reserveWorkflowAllocation(otherRequest)
    }
    let providers = try #require(run.providers)
    #expect(try await migrated.applyOrchestratorEvent(.init(
      id: UUID(), runID: run.id, expectedRevision: restored.revision,
      command: .confirmProviders(providers))) == .applied)
    #expect(try await migrated.orchestratorRun(id: run.id)?.providers == providers)
    _ = try await migrated.applyOrchestratorEvent(.init(
      id: UUID(), runID: run.id, expectedRevision: restored.revision + 1,
      command: .confirmQueueScope(.project(id: "project-test"))))
    #expect(try await migrated.orchestratorRun(id: run.id)?.queueScope == .project(id: "project-test"))
  }

  @Test("An identified worker binds after restart without cancelling the stop request")
  func bindWhileCancelling() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (run, request) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    try await OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows).allocate(request)
    _ = try await metadata.applyOrchestratorEvent(.init(
      id: UUID(), runID: run.id, expectedRevision: 0, command: .start(at: request.createdAt)))
    let attempt = try request.attempt()
    _ = try await metadata.applyOrchestratorEvent(request.event(
      .beginDispatch(attempt, at: request.createdAt, activeImplementations: 0), revision: 0))
    _ = try await metadata.applyOrchestratorEvent(request.event(.requestCancellation, revision: 1))
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let session = try OrchestratorSessionIdentity(provider: attempt.provider, sessionID: "late-worker")
    _ = try await reopened.applyOrchestratorEvent(request.event(
      .confirmLaunch(attemptID: attempt.id, pendingLaunchID: attempt.pendingLaunchID, session: session),
      revision: 2))
    let item = try #require(try await reopened.orchestratorItems(runID: run.id).first)
    #expect(item.state == .cancelling)
    #expect(item.session == session)
    #expect(try await reopened.orchestratorThreads(runID: run.id).first?.session == session)
  }

  @Test("A retry cannot consume an allocation ID reserved by another queued item")
  func allocationAndRetryShareAnIDNamespace() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (firstRun, first) = try fixture.run(issueID: "first")
    let (secondRun, second) = try fixture.run(issueID: "second")
    let coordinator = OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows)
    for (run, request) in [(firstRun, first), (secondRun, second)] {
      try await metadata.createOrchestratorRun(run)
      try await coordinator.allocate(request)
      _ = try await metadata.applyOrchestratorEvent(.init(
        id: UUID(), runID: run.id, expectedRevision: 0, command: .start(at: request.createdAt)))
    }
    let firstAttempt = try first.attempt()
    _ = try await metadata.applyOrchestratorEvent(first.event(
      .beginDispatch(firstAttempt, at: first.createdAt, activeImplementations: 0), revision: 0))
    _ = try await metadata.applyOrchestratorEvent(
      first.event(.confirmFailure(attemptID: firstAttempt.id), revision: 1))
    let invalidRetry = try first.attempt(operationID: second.operationID, predecessorID: firstAttempt.id)
    await #expect(throws: OrchestratorMetadataError.allocationConflict(second.operationID)) {
      try await metadata.applyOrchestratorEvent(first.event(
        .retry(invalidRetry, at: first.createdAt, activeImplementations: 0), revision: 2))
    }
    #expect(try await metadata.applyOrchestratorEvent(second.event(
      .beginDispatch(try second.attempt(), at: second.createdAt, activeImplementations: 0),
      revision: 0)) == .applied)
  }

  @Test("A persisted run retains its provider choice and run-wide attention")
  func runPolicyAndAttentionSurviveRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let (run, wrongRequest) = try fixture.run(requestProvider: .codex)
    try await metadata.createOrchestratorRun(run)
    _ = try await metadata.applyOrchestratorEvent(
      .init(id: UUID(), runID: run.id, expectedRevision: 0, command: .start(at: Date())))
    _ = try await metadata.applyOrchestratorEvent(
      .init(id: UUID(), runID: run.id, expectedRevision: 1, command: .requireAttention(.sourceUnavailable)))

    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let restored = try #require(try await reopened.orchestratorRun(id: run.id))
    let items = try await reopened.orchestratorItems(runID: run.id)
    let summary = OrchestratorRunSummary(run: restored, items: items)
    #expect(restored.providers == run.providers)
    #expect(restored.queueScope == run.queueScope)
    #expect(summary.runAttention == .sourceUnavailable)
    #expect(summary.attentionCount == 0)
    #expect(summary.needsAttention)
    let time = try #require(restored.startedAt)
    #expect(restored.dispatchDecision(at: time, activeImplementations: 0) == .runNeedsAttention)
    await #expect(throws: OrchestratorMetadataError.providerPolicyMismatch(run.id)) {
      try await reopened.reserveWorkflowAllocation(wrongRequest)
    }
    _ = try await reopened.applyOrchestratorEvent(
      .init(id: UUID(), runID: run.id, expectedRevision: 2, command: .clearAttention))
    let cleared = try #require(try await reopened.orchestratorRun(id: run.id))
    #expect(cleared.dispatchDecision(at: time, activeImplementations: 0) == .allowed)
  }

  @Test("A dependent item dispatches on a newly verified base without losing its workflow links")
  func dependencyBaseCanAdvance() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (run, request) = try fixture.run(prerequisiteID: "parent")
    let prerequisite = try #require(run.selection.first?.prerequisites.first)
    try await metadata.createOrchestratorRun(run)
    let coordinator = OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows)
    await #expect(throws: OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified)) {
      try await coordinator.allocate(request)
    }
    let initial = try OrchestratorDependencyVerification(
      baseCommitID: request.baseCommitID, integratedIssues: [prerequisite])
    _ = try await metadata.applyOrchestratorEvent(request.event(.verifyDependencies(initial), revision: 0))
    try await coordinator.allocate(request)
    let newer = try OrchestratorDependencyVerification(
      baseCommitID: "base-after-merge", integratedIssues: [prerequisite])
    _ = try await metadata.applyOrchestratorEvent(request.event(.verifyDependencies(newer), revision: 1))
    _ = try await metadata.applyOrchestratorEvent(
      .init(id: UUID(), runID: run.id, expectedRevision: 0, command: .start(at: request.createdAt)))

    for baseCommit in [initial.baseCommitID, newer.baseCommitID] {
      let attempt = try OrchestratorDispatchAttempt(
        id: UUID(), operationID: request.operationID, runID: run.id, itemID: request.itemID,
        pendingLaunchID: UUID(), provider: request.implementerProvider,
        ticketRunID: request.ticketRunID, branchRunID: request.branchRunID, baseCommitID: baseCommit)
      let event = request.event(
        .beginDispatch(attempt, at: request.createdAt, activeImplementations: 0), revision: 2)
      if baseCommit == initial.baseCommitID {
        await #expect(throws: OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified)) {
          try await metadata.applyOrchestratorEvent(event)
        }
      } else {
        #expect(try await metadata.applyOrchestratorEvent(event) == .applied)
      }
    }
    let persisted = try #require(try await metadata.orchestratorItems(runID: run.id).first)
    #expect(persisted.attempt?.baseCommitID == newer.baseCommitID)
    #expect(persisted.attempt?.branchRunID == request.branchRunID)
  }

}

extension OrchestratorMetadataStoreTests {
  @Test("A persisted transition accepts a duplicate and rejects an old conflicting event")
  func replayDoesNotRegressState() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let (run, _) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    let started = OrchestratorRunEvent(
      id: UUID(), runID: run.id, expectedRevision: 0, command: .start(at: Date()))
    #expect(try await metadata.applyOrchestratorEvent(started) == .applied)
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    #expect(try await reopened.applyOrchestratorEvent(started) == .duplicate)
    await #expect(throws: OrchestratorTransitionError.staleRevision) {
      try await reopened.applyOrchestratorEvent(
        OrchestratorRunEvent(id: UUID(), runID: run.id, expectedRevision: 0, command: .stop))
    }
    #expect(try await reopened.orchestratorRun(id: run.id)?.state == .running)
  }
  @Test("Thread binding survives restart, keeps the pending identity, and requires fresh activity")
  func threadBinding() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let (run, request) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    let thread = try OrchestratorThread(
      id: UUID(), runID: run.id, role: .orchestrator,
      provider: request.implementerProvider, pendingLaunchID: UUID())
    try await metadata.recordOrchestratorThread(thread)
    let duplicateMain = try OrchestratorThread(
      id: UUID(), runID: run.id, role: .orchestrator,
      provider: request.implementerProvider, pendingLaunchID: UUID())
    await #expect(throws: OrchestratorThreadError.mainThreadAlreadyOpen(run.id)) {
      try await metadata.recordOrchestratorThread(duplicateMain)
    }
    #expect(thread.visibility(currentActivity: .verifiedWorking) == .open)
    let session = try OrchestratorSessionIdentity(provider: thread.provider, sessionID: "session-1")
    await #expect(throws: OrchestratorThreadError.bindingMismatch) {
      try await metadata.bindOrchestratorThread(id: thread.id, pendingLaunchID: UUID(), session: session)
    }
    try await metadata.bindOrchestratorThread(
      id: thread.id, pendingLaunchID: thread.pendingLaunchID, session: session)
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    try await reopened.recordOrchestratorThread(thread)
    let loaded = try #require(try await reopened.orchestratorThreads(runID: run.id).first)
    #expect(loaded.session == session)
    #expect(loaded.pendingLaunchID == thread.pendingLaunchID)
    #expect(loaded.visibility(currentActivity: .verifiedWorking) == .active)
    #expect(loaded.visibility(currentActivity: .unknown) == .open)
    try await reopened.closeOrchestratorThread(id: thread.id, reason: .cancelled)
    let closed = try #require(try await metadata.orchestratorThreads(runID: run.id).first)
    #expect(closed.visibility(currentActivity: .verifiedWorking) == .closed(.cancelled))
    #expect(try await metadata.orchestratorRuns() == [run])
  }

  @Test("Old event identities remain reserved after intervening events and restarts")
  func oldEventIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let (run, _) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    let started = OrchestratorRunEvent(id: UUID(), runID: run.id, expectedRevision: 0,
      command: .start(at: Date()))
    _ = try await metadata.applyOrchestratorEvent(started)
    _ = try await metadata.applyOrchestratorEvent(
      OrchestratorRunEvent(id: UUID(), runID: run.id, expectedRevision: 1, command: .pause))
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    #expect(try await reopened.applyOrchestratorEvent(started) == .duplicate)
    await #expect(throws: OrchestratorTransitionError.conflictingEvent) {
      try await reopened.applyOrchestratorEvent(
        OrchestratorRunEvent(id: started.id, runID: run.id, expectedRevision: 2, command: .stop))
    }
    #expect(try await reopened.orchestratorRun(id: run.id)?.state == .pausing)
  }

  @Test("Review keeps its claim until completion and never advances on an old worker event")
  func reviewAndCompletion() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let metadata = try SessionMetadataStore(path: fixture.metadataPath)
    let workflows = try AgentWorkflowStore(path: fixture.workflowPath)
    let (run, request) = try fixture.run()
    let (overlap, otherRequest) = try fixture.run()
    try await metadata.createOrchestratorRun(run)
    try await metadata.createOrchestratorRun(overlap)
    let coordinator = OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows)
    _ = try await coordinator.allocate(request)
    _ = try await metadata.applyOrchestratorEvent(
      OrchestratorRunEvent(id: UUID(), runID: run.id, expectedRevision: 0,
        command: .start(at: request.createdAt)))
    let attempt = try OrchestratorDispatchAttempt(
      id: UUID(), operationID: request.operationID, runID: run.id, itemID: request.itemID,
      pendingLaunchID: UUID(), provider: request.implementerProvider,
      ticketRunID: request.ticketRunID, branchRunID: request.branchRunID,
      baseCommitID: request.baseCommitID)
    let session = try OrchestratorSessionIdentity(provider: attempt.provider, sessionID: "worker")
    let launched = request.event(
      .confirmLaunch(attemptID: attempt.id, pendingLaunchID: attempt.pendingLaunchID, session: session), revision: 1)
    let handoff = request.event(.handOff(attemptID: attempt.id, session: session), revision: 2)
    _ = try await metadata.applyOrchestratorEvent(
      request.event(.beginDispatch(attempt, at: request.createdAt, activeImplementations: 0), revision: 0))
    await #expect(throws: OrchestratorTransitionError.wrongPendingLaunch) {
      try await metadata.applyOrchestratorEvent(request.event(
        .confirmLaunch(attemptID: attempt.id, pendingLaunchID: UUID(), session: session), revision: 1))
    }
    #expect(try await metadata.orchestratorThreads(runID: run.id).first?.session == nil)
    _ = try await metadata.applyOrchestratorEvent(launched)
    let unrelatedSession = try OrchestratorSessionIdentity(provider: attempt.provider, sessionID: "other-worker")
    await #expect(throws: OrchestratorTransitionError.wrongSession) {
      try await metadata.applyOrchestratorEvent(request.event(
        .handOff(attemptID: attempt.id, session: unrelatedSession), revision: 2))
    }
    _ = try await metadata.applyOrchestratorEvent(handoff)
    #expect(try await metadata.orchestratorThreads(runID: run.id).first?.session == session)
    await #expect(throws: OrchestratorMetadataError.issueAlreadyClaimed(request.issue)) {
      try await metadata.reserveWorkflowAllocation(otherRequest)
    }
    let completed = OrchestratorRunEvent(
      id: UUID(), runID: run.id, expectedRevision: 1, command: .confirmCompleted)
    await #expect(throws: OrchestratorTransitionError.workRemains) {
      try await metadata.applyOrchestratorEvent(completed)
    }
    let evidenceID = UUID()
    _ = try await metadata.applyOrchestratorEvent(
      request.event(.confirmCompletion(attemptID: attempt.id, evidenceID: evidenceID), revision: 3))
    #expect(try await metadata.applyOrchestratorEvent(launched) == .duplicate)
    #expect(try await metadata.applyOrchestratorEvent(completed) == .applied)
    let final = try #require(try await metadata.orchestratorItems(runID: run.id).first)
    #expect(final.state == .completed)
    #expect(final.completionEvidenceID == evidenceID)
    try await metadata.reserveWorkflowAllocation(otherRequest)
  }

}

private struct Fixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  var metadataPath: String { directory.appending(path: "metadata.sqlite").path }
  var workflowPath: String { directory.appending(path: "workflows.sqlite").path }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }

  func run(
    issueID: String = "immutable-id", ticketRunID: UUID = UUID(),
    prerequisiteID: String? = nil, requestProvider: AgentProviderID? = nil, operationID: UUID = UUID(),
    baseBranch: String = "main", approvedBaseBranch: String? = nil
  ) throws -> (OrchestratorRun, WorkflowAllocationRequest) {
    let source = try OrchestratorSourceIdentity(
      trackerID: "future-tracker", accountID: "opaque-account", scopeID: "workspace")
    let issue = try OrchestratorIssueIdentity(source: source, issueID: issueID)
    let prerequisites = try prerequisiteID.map {
      [try OrchestratorIssueIdentity(source: source, issueID: $0)]
    } ?? []
    let repository = try approvedBaseBranch.map {
      try OrchestratorRepositoryBinding(repositoryPath: "/repo", baseBranch: $0)
    }
    let selection = OrchestratorSelectedIssue(
      id: UUID(), issue: issue, prerequisites: prerequisites, repository: repository)
    let policy = try OrchestratorRunPolicy(maximumTickets: 1, wallClockLimit: 60, maximumRetries: 1)
    let provider = AgentProviderID(rawValue: "future-provider")
    let providers = try OrchestratorRunProviders(
      orchestrator: provider, coordinator: provider, implementer: provider, reviewer: provider)
    let run = try OrchestratorRun(id: UUID(), policy: policy, providers: providers, queueScope: .project(id: "project-test"), selection: [selection])
    let request = try WorkflowAllocationRequest(
      operationID: operationID, runID: run.id, itemID: selection.id, issue: issue,
      ticketRunID: ticketRunID, branchRunID: UUID(), ticketCreatedEventID: UUID(),
      branchCreatedEventID: UUID(), ticketKey: "TES-308", repositoryPath: "/repo",
      worktreePath: "/worktree", branchName: "topic", baseBranch: baseBranch, baseCommitID: "abc123",
      coordinatorProvider: provider, implementerProvider: requestProvider ?? provider, reviewerProvider: provider,
      createdAt: Date(timeIntervalSince1970: 100))
    return (run, request)
  }
}

private extension WorkflowAllocationRequest {
  func attempt(operationID: UUID? = nil, predecessorID: UUID? = nil) throws
    -> OrchestratorDispatchAttempt
  {
    try OrchestratorDispatchAttempt(
      id: UUID(), operationID: operationID ?? self.operationID, runID: runID, itemID: itemID,
      predecessorID: predecessorID, pendingLaunchID: UUID(), provider: implementerProvider,
      ticketRunID: ticketRunID, branchRunID: branchRunID, baseCommitID: baseCommitID)
  }

  func event(_ command: OrchestratorItemCommand, revision: UInt64) -> OrchestratorItemEvent {
    OrchestratorItemEvent(
      id: UUID(), runID: runID, itemID: itemID, expectedRevision: revision, command: command)
  }
}
