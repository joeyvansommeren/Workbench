import AgentWorkflowCore
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Orchestrator queue execution")
struct OrchestratorQueueExecutionTests {
  @Test("The application runtime persists the attempt before launching and starts the run only once")
  func runtimeEntryPoints() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first", "second"])
    try await fixture.metadata.createOrchestratorRun(run)
    let runtime: any OrchestratorQueueExecuting = AgentWorkflowRuntime(
      store: fixture.workflows, metadata: fixture.metadata, source: fixture.source,
      planner: fixture.planner, workers: fixture.workers, clock: fixture.clock)
    try await runtime.start(runID: run.id)
    fixture.clock.advance(by: 7)
    try await runtime.start(runID: run.id)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.startedAt == fixture.start)
    let outcome = try await runtime.executeNext(runID: run.id)
    guard case .attempted(let itemID, let attemptID) = outcome else {
      Issue.record("Expected one attempted dispatch")
      return
    }
    #expect(await fixture.workers.launches == [attemptID])
    #expect(await fixture.workers.attemptWasSavedBeforeLaunch)
    let item = try await fixture.item(run.id, itemID)
    #expect(item.state == .running)
    #expect(try await runtime.executeNext(runID: run.id) == .suspended(.concurrencyLimitReached))
    let binding = try fixture.binding(for: item)
    await #expect(throws: OrchestratorExecutionError.mismatchedHandoff) {
      try await runtime.handOff(runID: run.id, itemID: item.id, attemptID: attemptID,
        binding: .init(pendingLaunchID: UUID(), session: binding.session), eventID: UUID())
    }
    try await runtime.handOff(runID: run.id, itemID: item.id, attemptID: attemptID,
      binding: binding, eventID: UUID())
    #expect(try await fixture.item(run.id, itemID).state == .awaitingReview)
    _ = try await runtime.executeNext(runID: run.id)
    #expect(await fixture.workers.launches.count == 2)
  }

  @Test("Overlapping queues cannot launch the same source issue")
  func competingRuns() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let first = try fixture.makeRun(issueIDs: ["shared"])
    let second = try fixture.makeRun(issueIDs: ["shared", "independent"])
    for run in [first, second] { try await fixture.metadata.createOrchestratorRun(run) }
    let executor = fixture.executor()
    try await executor.start(runID: first.id)
    try await executor.start(runID: second.id)
    _ = try await executor.executeNext(runID: first.id)
    _ = try await executor.executeNext(runID: second.id)
    let items = try await fixture.metadata.orchestratorItems(runID: second.id)
    #expect(items.map(\.state) == [.blocked, .running])
    #expect(await fixture.workers.launches.count == 2)
  }

  @Test("A timeout preserves the intent, and restart identifies the original worker without relaunch")
  func timeoutThenRestart() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first", "second"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    await fixture.workers.setLaunchUncertain()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let pending = try await fixture.item(run.id, run.selection[0].id)
    #expect(pending.state == .reconciling)
    await #expect(throws: OrchestratorTransitionError.invalidItemTransition) {
      try await executor.retry(runID: run.id, itemID: pending.id)
    }

    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let reopenedQueue = await reopened.dbQueue
    defer { try? reopenedQueue.close() }
    let relaunched = fixture.executor(metadata: reopened)
    try await relaunched.recover(runID: run.id)
    #expect(try await reopened.orchestratorRun(id: run.id)?.attention == .reconciliationRequired)
    #expect(await fixture.workers.launches.count == 1)
    let attempt = try #require(pending.attempt)
    let binding = OrchestratorWorkerBinding(pendingLaunchID: attempt.pendingLaunchID,
      session: try .init(provider: attempt.provider, sessionID: "discovered-worker"))
    await fixture.workers.setObservation(.running(binding))
    try await relaunched.resume(runID: run.id)
    #expect(try await reopened.orchestratorItems(runID: run.id).first?.session == binding.session)
    #expect(try await relaunched.executeNext(runID: run.id) == .suspended(.concurrencyLimitReached))
    #expect(await fixture.workers.launches.count == 1)
  }

  @Test("A fresh executor requires resume before dispatching a saved running queue")
  func waitForWakeReconciliation() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first"])
    try await fixture.metadata.createOrchestratorRun(run)
    try await fixture.executor().start(runID: run.id)
    let reopened = try SessionMetadataStore(path: fixture.metadataPath)
    let reopenedQueue = await reopened.dbQueue
    defer { try? reopenedQueue.close() }
    let restarted = fixture.executor(metadata: reopened)
    #expect(try await restarted.executeNext(runID: run.id) == .suspended(.runNeedsAttention))
    #expect(await fixture.workers.launches.isEmpty)
    try await restarted.resume(runID: run.id)
    _ = try await restarted.executeNext(runID: run.id)
    #expect(await fixture.workers.launches.count == 1)
  }

  @Test("A reused PID cannot clear an unresolved stop or trigger a replacement worker")
  func stopWaitsForVerifiedQuiescence() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first", "second"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    // The adapter reports no reliable ownership after an apparent PID reuse.
    await fixture.workers.setCancellation(.uncertain)
    try await executor.stop(runID: run.id)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .stopping)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.attention == .reconciliationRequired)
    #expect(try await fixture.metadata.orchestratorItems(runID: run.id).map(\.state) == [.cancelling, .cancelled])
    #expect(try await executor.executeNext(runID: run.id) == .suspended(.runNotRunning))
    await fixture.workers.setCancellation(.stopped)
    try await executor.recover(runID: run.id)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .stopped)
    #expect(await fixture.workers.launches.count == 1)
  }

  @Test("Pause drains to a safe handoff and resume preserves the wall-clock budget")
  func pauseDrainsAndBudgetDoesNotReset() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first", "second"], wallClockLimit: 20)
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let item = try await fixture.item(run.id, run.selection[0].id)
    let attempt = try #require(item.attempt)
    try await executor.pause(runID: run.id)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .pausing)
    #expect(try await executor.executeNext(runID: run.id) == .suspended(.runNotRunning))
    try await executor.handOff(runID: run.id, itemID: item.id, attemptID: attempt.id,
      binding: fixture.binding(for: item), eventID: UUID())
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .paused)
    fixture.clock.advance(by: 20)
    try await executor.resume(runID: run.id)
    #expect(try await executor.executeNext(runID: run.id) == .suspended(.timeBudgetExhausted))
    #expect(await fixture.workers.launches == [attempt.id])
  }
}

extension OrchestratorQueueExecutionTests {
  @Test("Launch rechecks remote revision after allocation without starting a changed ticket")
  func changedRevision() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["moving", "eligible"])
    try await fixture.metadata.createOrchestratorRun(run)
    await fixture.source.changeRevisionAfterFirstRead(issue: run.selection[0].issue)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let items = try await fixture.metadata.orchestratorItems(runID: run.id)
    #expect(items.map(\.state) == [.blocked, .running])
    #expect(await fixture.workers.launches.count == 1)
  }

  @Test("A blocked prerequisite does not prevent unrelated dispatch")
  func independentWorkContinues() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["dependent", "independent"], firstHasDependency: true)
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let items = try await fixture.metadata.orchestratorItems(runID: run.id)
    #expect(items.map(\.state) == [.blocked, .running])
    #expect(await fixture.workers.launches.count == 1)
  }

  @Test("A positively stopped worker permits exactly one retry with a new attempt and original links")
  func retriesRetainLineage() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let live = try await fixture.item(run.id, run.selection[0].id)
    let first = try #require(live.attempt)
    await fixture.workers.setObservation(.stopped)
    try await executor.recover(runID: run.id)
    try await executor.resume(runID: run.id)
    _ = try await executor.retry(runID: run.id, itemID: live.id)
    let retried = try await fixture.item(run.id, live.id)
    let second = try #require(retried.attempt)
    #expect(second.predecessorID == first.id)
    #expect(second.ticketRunID == first.ticketRunID)
    #expect(second.branchRunID == first.branchRunID)
    #expect(second.pendingLaunchID != first.pendingLaunchID)
    try await executor.recover(runID: run.id)
    try await executor.resume(runID: run.id)
    await #expect(throws: OrchestratorTransitionError.retryLimitReached) {
      try await executor.retry(runID: run.id, itemID: live.id)
    }
    #expect(await fixture.workers.launches.count == 2)
  }

  @Test("Authentication loss blocks dispatch until the approved source is available")
  func sourceLoss() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    await fixture.source.setAttention(.sourceAuthenticationRequired)
    try await executor.start(runID: run.id)
    #expect(try await executor.executeNext(runID: run.id) == .suspended(.runNeedsAttention))
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.attention == .sourceAuthenticationRequired)
    await #expect(throws: OrchestratorExecutionError.unresolvedWork) {
      try await executor.resume(runID: run.id)
    }
    await fixture.source.setAttention(nil)
    try await executor.resume(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    #expect(await fixture.workers.launches.count == 1)
  }
}

extension OrchestratorQueueExecutionTests {
  @Test("Wake during the final source read prevents an operation from reaching the launcher")
  func wakeWhileVerifyingSource() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["ticket"])
    try await fixture.metadata.createOrchestratorRun(run)
    let gate = FixtureAwaitGate()
    await fixture.source.holdSecondRead(at: gate)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)

    let dispatch = Task { try await executor.executeNext(runID: run.id) }
    await gate.waitForArrival()
    await #expect(throws: OrchestratorExecutionError.busy(run.id)) {
      try await executor.recover(runID: run.id)
    }
    await gate.open()

    #expect(try await dispatch.value == .suspended(.runNeedsAttention))
    #expect(try await fixture.item(run.id, run.selection[0].id).attempt == nil)
    #expect(await fixture.workers.launches.isEmpty)
  }

  @Test("A durable Stop drains while a suspended control owns the run", arguments: [true, false])
  func stopDuringRecoveryOrResume(whileResuming: Bool) async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first", "second"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let active = try await fixture.item(run.id, run.selection[0].id)
    let binding = try fixture.binding(for: active)
    let gate = FixtureAwaitGate()
    await fixture.workers.setObservation(.running(binding))
    await fixture.workers.holdObservation(at: gate)

    let control = Task {
      if whileResuming {
        try await executor.resume(runID: run.id)
      } else {
        try await executor.recover(runID: run.id)
      }
    }
    await gate.waitForArrival()
    try await executor.stop(runID: run.id)
    try await executor.stop(runID: run.id)
    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .stopping)
    #expect(await fixture.workers.cancelledAttempts.isEmpty)
    await gate.open()
    if whileResuming {
      await #expect(throws: OrchestratorTransitionError.invalidRunTransition) { try await control.value }
    } else {
      try await control.value
    }

    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .stopped)
    #expect(await fixture.workers.cancelledAttempts == [active.attempt?.id])
  }

  @Test("Stop takes a worker while handoff verification is pending")
  func stopDuringHandoff() async throws {
    let fixture = try DispatchFixture()
    defer { fixture.cleanUp() }
    let run = try fixture.makeRun(issueIDs: ["first"])
    try await fixture.metadata.createOrchestratorRun(run)
    let executor = fixture.executor()
    try await executor.start(runID: run.id)
    _ = try await executor.executeNext(runID: run.id)
    let active = try await fixture.item(run.id, run.selection[0].id)
    let attempt = try #require(active.attempt)
    let binding = try fixture.binding(for: active)
    let gate = FixtureAwaitGate()
    await fixture.workers.holdHandoff(at: gate)

    let handoff = Task {
      try await executor.handOff(runID: run.id, itemID: active.id, attemptID: attempt.id,
        binding: binding, eventID: UUID())
    }
    await gate.waitForArrival()
    try await executor.stop(runID: run.id)
    await gate.open()
    try await handoff.value

    #expect(try await fixture.metadata.orchestratorRun(id: run.id)?.state == .stopped)
    #expect(try await fixture.item(run.id, active.id).state == .cancelled)
    #expect(await fixture.workers.cancelledAttempts == [attempt.id])
  }
}

private struct DispatchFixture {
  let directory: URL
  let metadata: SessionMetadataStore
  private let metadataQueue: DatabaseQueue
  let workflows: AgentWorkflowStore
  let source = FixtureDispatchSource()
  let planner = FixtureDispatchPlanner()
  let workers: FixtureDispatchWorkers
  let start = Date(timeIntervalSince1970: 10_000)
  let clock: FixtureDispatchClock

  var metadataPath: String { directory.appending(path: "metadata.sqlite").path }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    metadataQueue = try DatabaseQueue(path: directory.appending(path: "metadata.sqlite").path,
      configuration: configuration)
    metadata = try SessionMetadataStore(databaseQueue: metadataQueue)
    workflows = try AgentWorkflowStore(path: ":memory:")
    clock = FixtureDispatchClock(start)
    workers = FixtureDispatchWorkers(metadata: metadata)
  }

  func cleanUp() {
    try? metadataQueue.close()
    try? FileManager.default.removeItem(at: directory)
  }

  func executor(metadata: SessionMetadataStore? = nil) -> OrchestratorQueueExecutor {
    OrchestratorQueueExecutor(metadata: metadata ?? self.metadata, workflows: workflows,
      source: source, planner: planner, workers: workers, clock: clock)
  }

  func makeRun(issueIDs: [String], wallClockLimit: TimeInterval = 300,
    firstHasDependency: Bool = false) throws -> OrchestratorRun
  {
    let source = try OrchestratorSourceIdentity(trackerID: "linear",
      accountID: "fixture-account", scopeID: "fixture-workspace")
    let repository = try OrchestratorRepositoryBinding(repositoryPath: "/repos/original", baseBranch: "main")
    let prerequisite = try OrchestratorIssueIdentity(source: source, issueID: "prerequisite")
    let selection = try issueIDs.enumerated().map { index, issueID in
      OrchestratorSelectedIssue(id: UUID(), issue: try .init(source: source, issueID: issueID),
        prerequisites: firstHasDependency && index == 0 ? [prerequisite] : [], repository: repository)
    }
    return try OrchestratorRun(id: UUID(),
      policy: OrchestratorRunPolicy(maximumTickets: selection.count, wallClockLimit: wallClockLimit,
        maximumRetries: 1),
      providers: .init(orchestrator: .codex, coordinator: .claude, implementer: .codex, reviewer: .claude),
      queueScope: .project(id: "fixture-project"), selection: selection)
  }

  func item(_ runID: UUID, _ itemID: UUID) async throws -> OrchestratorQueueItem {
    try #require(try await metadata.orchestratorItems(runID: runID).first { $0.id == itemID })
  }

  func binding(for item: OrchestratorQueueItem) throws -> OrchestratorWorkerBinding {
    let attempt = try #require(item.attempt)
    return .init(pendingLaunchID: attempt.pendingLaunchID, session: try #require(item.session))
  }
}

private final class FixtureDispatchClock: OrchestratorExecutionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var time: Date

  init(_ time: Date) { self.time = time }
  func now() -> Date { lock.withLock { time } }
  func advance(by seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
}

private actor FixtureDispatchSource: OrchestratorDispatchSource {
  private var attention: OrchestratorRunAttention?
  private var changingIssue: OrchestratorIssueIdentity?
  private var reads: [OrchestratorIssueIdentity: Int] = [:]
  private var secondReadGate: FixtureAwaitGate?

  func holdSecondRead(at gate: FixtureAwaitGate) { secondReadGate = gate }
  func setAttention(_ reason: OrchestratorRunAttention?) { attention = reason }
  func changeRevisionAfterFirstRead(issue: OrchestratorIssueIdentity) { changingIssue = issue }

  func eligibility(of selection: OrchestratorSelectedIssue, in run: OrchestratorRun) async throws
    -> OrchestratorSourceCheck
  {
    if let attention { return .unavailable(attention) }
    let scope = try #require(run.queueScope)
    reads[selection.issue, default: 0] += 1
    if reads[selection.issue] == 2 { await secondReadGate?.arrive() }
    let revision = changingIssue == selection.issue
      ? String(reads[selection.issue, default: 0]) : "stable"
    return .eligible(.init(issue: selection.issue, queueScope: scope, revision: revision,
      ticketKey: selection.issue.issueID))
  }

  func checkScope(of run: OrchestratorRun) -> OrchestratorRunAttention? { attention }
}

private struct FixtureDispatchPlanner: OrchestratorDispatchPreparing {
  func prepare(selection: OrchestratorSelectedIssue, snapshot: OrchestratorSourceRevision,
    existingAllocation: WorkflowAllocationRequest?) throws -> OrchestratorWorktreeCheck
  {
    let repository = try #require(selection.repository)
    return .ready(.init(repository: repository,
      worktreePath: existingAllocation?.worktreePath ?? "/repos/worker-\(selection.id.uuidString)",
      branchName: existingAllocation?.branchName ?? "worker/\(selection.id.uuidString)",
      baseCommitID: "base"))
  }
}

private actor FixtureDispatchWorkers: OrchestratorWorkerLaunching {
  let metadata: SessionMetadataStore
  private(set) var launches: [UUID] = []
  private(set) var cancelledAttempts: [UUID] = []
  private(set) var attemptWasSavedBeforeLaunch = false
  private var launchUncertain = false
  private var observation: OrchestratorWorkerObservation = .uncertain
  private var cancellation: OrchestratorWorkerObservation = .stopped
  private var observationGate: FixtureAwaitGate?
  private var handoffGate: FixtureAwaitGate?

  init(metadata: SessionMetadataStore) { self.metadata = metadata }
  func setLaunchUncertain() { launchUncertain = true }
  func holdObservation(at gate: FixtureAwaitGate) { observationGate = gate }
  func holdHandoff(at gate: FixtureAwaitGate) { handoffGate = gate }
  func setObservation(_ observation: OrchestratorWorkerObservation) { self.observation = observation }
  func setCancellation(_ cancellation: OrchestratorWorkerObservation) { self.cancellation = cancellation }

  func launch(_ launch: OrchestratorWorkerLaunch) async throws -> OrchestratorWorkerObservation {
    let attempt = launch.attempt
    let persisted = try await metadata.orchestratorItems(runID: attempt.runID).first { $0.id == attempt.itemID }
    attemptWasSavedBeforeLaunch = persisted?.attempt == attempt && persisted?.state == .launching
    launches.append(attempt.id)
    if launchUncertain { return .uncertain }
    return .running(.init(pendingLaunchID: attempt.pendingLaunchID,
      session: try .init(provider: attempt.provider, sessionID: attempt.id.uuidString)))
  }

  func observe(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?) async
    -> OrchestratorWorkerObservation
  {
    await observationGate?.arrive()
    return observation
  }

  func cancel(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    -> OrchestratorWorkerObservation
  {
    cancelledAttempts.append(attempt.id)
    return cancellation
  }

  func verifyHandoff(attempt: OrchestratorDispatchAttempt, binding: OrchestratorWorkerBinding) async
    -> Bool
  {
    await handoffGate?.arrive()
    return launches.contains(attempt.id)
  }
}

private actor FixtureAwaitGate {
  private var hasArrived = false
  private var isOpen = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func arrive() async {
    hasArrived = true
    for waiter in arrivalWaiters { waiter.resume() }
    arrivalWaiters.removeAll()
    if !isOpen { await withCheckedContinuation { openWaiters.append($0) } }
  }

  func waitForArrival() async {
    if !hasArrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
  }

  func open() {
    isOpen = true
    for waiter in openWaiters { waiter.resume() }
    openWaiters.removeAll()
  }
}
