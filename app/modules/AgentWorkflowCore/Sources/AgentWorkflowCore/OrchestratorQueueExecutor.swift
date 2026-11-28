import Foundation

/// Executes one dispatch per tick. No task is spawned on a timer by this actor.
/// The app owns the lifetime of the executor and calls recover after wake.
public actor OrchestratorQueueExecutor: OrchestratorQueueExecuting {
  let metadata: any OrchestratorMetadataStoring
  let allocations: OrchestratorAllocationCoordinator
  let source: any OrchestratorDispatchSource
  let planner: any OrchestratorDispatchPreparing
  let workers: any OrchestratorWorkerLaunching
  let clock: any OrchestratorExecutionClock

  private var processing = Set<UUID>()
  private var admittedRuns = Set<UUID>()
  private var admissionEpoch = [UUID: UUID]()
  private var requestedStopDrains = Set<UUID>()
  private var drainingStops = Set<UUID>()

  public init(metadata: any OrchestratorMetadataStoring, workflows: any WorkflowAllocationStoring,
    source: any OrchestratorDispatchSource, planner: any OrchestratorDispatchPreparing,
    workers: any OrchestratorWorkerLaunching,
    clock: any OrchestratorExecutionClock = SystemOrchestratorExecutionClock())
  {
    self.metadata = metadata
    allocations = OrchestratorAllocationCoordinator(metadata: metadata, workflows: workflows)
    self.source = source
    self.planner = planner
    self.workers = workers
    self.clock = clock
  }

  /// Only a newly created draft can start without restart reconciliation.
  public func start(runID: UUID) async throws {
    try await withProcessing(runID: runID) {
      let epoch = admissionEpoch[runID]
      let run = try await run(runID)
      guard run.state == .draft else { return }
      try await apply(.start(at: clock.now()), to: run)
      if admissionEpoch[runID] == epoch { admittedRuns.insert(runID) }
    }
  }

  public func executeNext(runID: UUID) async throws -> OrchestratorDispatchOutcome {
    try await withProcessing(runID: runID) {
      let run = try await run(runID)
      let items = try await metadata.orchestratorItems(runID: runID)
      let decision = dispatchDecision(run, items: items)
      guard decision == .allowed else { return .suspended(decision) }
      let outcome = try await nextEligible(items, run: run)
      try await confirmPauseWhenIdle(runID: runID)
      return outcome
    }
  }

  public func retry(runID: UUID, itemID: UUID) async throws -> OrchestratorDispatchOutcome {
    try await withProcessing(runID: runID) {
      let run = try await run(runID)
      let items = try await metadata.orchestratorItems(runID: runID)
      guard let item = items.first(where: { $0.id == itemID }),
        let attempt = item.attempt, item.state == .failed || item.state == .cancelled
      else { throw OrchestratorTransitionError.invalidItemTransition }
      guard item.retryCount < run.policy.maximumRetries else {
        throw OrchestratorTransitionError.retryLimitReached
      }
      let decision = dispatchDecision(run, items: items)
      guard decision == .allowed else { return .suspended(decision) }
      guard try await workers.observe(attempt: attempt, session: item.session) == .stopped else {
        try await requireAttention(.reconciliationRequired, runID: runID)
        throw OrchestratorExecutionError.unresolvedWork
      }
      let outcome = try await dispatch(item, in: run, retry: true) ?? .noEligibleWork
      try await confirmPauseWhenIdle(runID: runID)
      return outcome
    }
  }

  /// Stops admission immediately. A launch already handed to an adapter must
  /// finish reconciling or hand off before the run can become paused.
  public func pause(runID: UUID) async throws {
    revokeAdmission(runID)
    let run = try await run(runID)
    if run.state == .running { try await apply(.pause, to: run) }
    try await confirmPauseWhenIdle(runID: runID)
  }

  public func stop(runID: UUID) async throws {
    revokeAdmission(runID)
    guard try await persistStop(runID), !drainingStops.contains(runID) else { return }
    requestedStopDrains.insert(runID)
    // Every operation owner checks the queue before releasing its slot. This
    // decision and a potential acquisition occur in the same actor turn.
    guard !processing.contains(runID) else { return }
    try await withProcessing(runID: runID) {}
  }

  private func persistStop(_ runID: UUID) async throws -> Bool {
    for _ in 0..<3 {
      let current = try await run(runID)
      if current.state == .stopping { return true }
      if [.stopped, .completed].contains(current.state) { return false }
      do {
        try await apply(.stop, to: current)
        return true
      } catch OrchestratorTransitionError.staleRevision {
        // A concurrent app decision won this revision. Re-read before retrying.
      }
    }
    throw OrchestratorTransitionError.staleRevision
  }

  /// A wake or relaunch never starts work. A fresh executor has no admitted runs.
  public func recover(runID: UUID) async throws {
    revokeAdmission(runID)
    try await withProcessing(runID: runID) {
      let current = try await run(runID)
      if current.state == .stopping {
        requestedStopDrains.insert(runID)
        return
      }
      guard [.running, .pausing, .paused].contains(current.state) else { return }
      if try await !reconcileOwnedWork(runID: runID) {
        try await requireAttention(.reconciliationRequired, runID: runID)
      }
      try await confirmPauseWhenIdle(runID: runID)
    }
  }

  public func resume(runID: UUID) async throws {
    revokeAdmission(runID)
    try await withProcessing(runID: runID) {
      let epoch = admissionEpoch[runID]
      let current = try await run(runID)
      guard [.running, .paused].contains(current.state) else {
        throw OrchestratorTransitionError.invalidRunTransition
      }
      if let reason = try await checkSourceScope(current) {
        try await requireAttention(reason, runID: runID)
        throw OrchestratorExecutionError.unresolvedWork
      }
      guard try await reconcileOwnedWork(runID: runID) else {
        try await requireAttention(.reconciliationRequired, runID: runID)
        throw OrchestratorExecutionError.unresolvedWork
      }
      var verified = try await run(runID)
      guard admissionEpoch[runID] == epoch, [.running, .paused].contains(verified.state) else {
        throw OrchestratorTransitionError.invalidRunTransition
      }
      if verified.attention != nil {
        try await apply(.clearAttention, to: verified)
        verified = try await run(runID)
      }
      if verified.state == .paused { try await apply(.resumeAfterReconciliation, to: verified) }
      if try await run(runID).state == .running, admissionEpoch[runID] == epoch {
        admittedRuns.insert(runID)
      }
    }
  }

  public func handOff(runID: UUID, itemID: UUID, attemptID: UUID,
    binding: OrchestratorWorkerBinding, eventID: UUID
  ) async throws {
    try await withProcessing(runID: runID) {
      let item = try await item(runID: runID, itemID: itemID)
      guard let attempt = item.attempt, attempt.id == attemptID,
        attempt.pendingLaunchID == binding.pendingLaunchID, item.session == binding.session,
        try await workers.verifyHandoff(attempt: attempt, binding: binding)
      else { throw OrchestratorExecutionError.mismatchedHandoff }
      if item.state == .awaitingReview { return }
      // Stop takes ownership of a worker still awaiting handoff verification.
      guard try await run(runID).state != .stopping else { return }
      try await apply(.handOff(attemptID: attemptID, session: binding.session), to: item, id: eventID)
      try await confirmPauseWhenIdle(runID: runID)
    }
  }

  private func checkSourceScope(_ run: OrchestratorRun) async throws -> OrchestratorRunAttention? {
    do {
      return try await source.checkScope(of: run)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .sourceUnavailable
    }
  }

  private func nextEligible(_ items: [OrchestratorQueueItem], run: OrchestratorRun)
    async throws -> OrchestratorDispatchOutcome
  {
    for item in items where item.state == .queued || item.state == .blocked {
      if let outcome = try await dispatch(item, in: run, retry: false) { return outcome }
    }
    return .noEligibleWork
  }

  func run(_ id: UUID) async throws -> OrchestratorRun {
    guard let run = try await metadata.orchestratorRun(id: id) else {
      throw OrchestratorMetadataError.missingRun(id)
    }
    return run
  }

  func item(runID: UUID, itemID: UUID) async throws -> OrchestratorQueueItem {
    guard let item = try await metadata.orchestratorItems(runID: runID).first(where: {
      $0.id == itemID
    }) else { throw OrchestratorMetadataError.missingItem(itemID) }
    return item
  }

  func dispatchDecision(_ run: OrchestratorRun, items: [OrchestratorQueueItem])
    -> OrchestratorDispatchDecision
  {
    let decision = run.dispatchDecision(
      at: clock.now(), activeImplementations: items.count(where: { $0.state.holdsDispatchSlot }))
    if decision == .allowed, !hasAdmission(run.id) { return .runNeedsAttention }
    return decision
  }

  func requireAttention(_ reason: OrchestratorRunAttention, runID: UUID) async throws {
    revokeAdmission(runID)
    let current = try await run(runID)
    if ![.stopped, .completed].contains(current.state), current.attention != reason {
      try await apply(.requireAttention(reason), to: current)
    }
  }

  func apply(_ command: OrchestratorRunCommand, to run: OrchestratorRun) async throws {
    _ = try await metadata.applyOrchestratorEvent(.init(
      id: UUID(), runID: run.id, expectedRevision: run.revision, command: command))
  }

  func apply(_ command: OrchestratorItemCommand, to item: OrchestratorQueueItem,
    id: UUID = UUID()) async throws
  {
    _ = try await metadata.applyOrchestratorEvent(.init(
      id: id, runID: item.runID, itemID: item.id, expectedRevision: item.revision, command: command))
  }

  func hasAdmission(_ runID: UUID) -> Bool {
    admittedRuns.contains(runID)
  }

  private func revokeAdmission(_ runID: UUID) {
    admittedRuns.remove(runID)
    admissionEpoch[runID] = UUID()
  }

  private func withProcessing<Value: Sendable>(runID: UUID, _ operation: () async throws -> Value)
    async throws -> Value
  {
    guard processing.insert(runID).inserted else { throw OrchestratorExecutionError.busy(runID) }
    defer { processing.remove(runID) }

    let result: Result<Value, Error>
    do { result = .success(try await operation()) } catch { result = .failure(error) }

    // A Stop request can arrive while any operation is awaiting I/O or writing.
    // Check after each suspension and release without yielding once the queue is empty.
    while requestedStopDrains.remove(runID) != nil {
      drainingStops.insert(runID)
      defer { drainingStops.remove(runID) }
      try await drainStopIfRequested(runID: runID)
    }
    return try result.get()
  }
}
