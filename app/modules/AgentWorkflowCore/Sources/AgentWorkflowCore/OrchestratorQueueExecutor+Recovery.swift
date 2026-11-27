import Foundation

extension OrchestratorQueueExecutor {
  func reconcileOwnedWork(runID: UUID) async throws -> Bool {
    var resolved = try await settleAllocations(runID: runID)
    let items = try await metadata.orchestratorItems(runID: runID)
    for item in items where item.state.holdsDispatchSlot {
      guard let attempt = item.attempt else {
        resolved = false
        continue
      }
      let observation = await observe(attempt, item: item, cancelling: item.state == .cancelling)
      let latest = try await self.item(runID: runID, itemID: item.id)
      let matched = try await record(observation, for: latest, attempt: attempt)
      if !matched || (item.state == .cancelling && observation != .stopped) { resolved = false }
    }
    return resolved
  }

  func drainStopIfRequested(runID: UUID) async throws {
    guard try await run(runID).state == .stopping else { return }
    let items = try await metadata.orchestratorItems(runID: runID)
    for item in items where [.queued, .blocked, .launching, .reconciling, .running].contains(item.state) {
      try await apply(.requestCancellation, to: item)
    }
    guard try await reconcileOwnedWork(runID: runID) else {
      try await requireAttention(.reconciliationRequired, runID: runID)
      return
    }
    do {
      try await apply(.confirmStopped, to: run(runID))
    } catch OrchestratorTransitionError.workRemains {
      // The store may still hold an unreadable or unresolved journal row.
      try await requireAttention(.reconciliationRequired, runID: runID)
    }
  }

  func confirmPauseWhenIdle(runID: UUID) async throws {
    let current = try await run(runID)
    if current.state == .pausing,
      try await !metadata.orchestratorItems(runID: runID).contains(where: { $0.state.holdsDispatchSlot })
    {
      try await apply(.confirmPaused, to: current)
    }
  }

  @discardableResult
  func record(_ observation: OrchestratorWorkerObservation, for item: OrchestratorQueueItem,
    attempt: OrchestratorDispatchAttempt) async throws -> Bool
  {
    guard item.attempt?.id == attempt.id, item.state.holdsDispatchSlot else { return false }
    switch observation {
    case .running(let binding):
      guard binding.pendingLaunchID == attempt.pendingLaunchID,
        binding.session.provider.rawValue.utf8.elementsEqual(attempt.provider.rawValue.utf8),
        item.session == nil || item.session == binding.session
      else { return try await recordUncertainty(item, attempt: attempt) }
      if item.state != .running, item.session == nil || item.state == .reconciling {
        try await apply(
          .confirmLaunch(attemptID: attempt.id, pendingLaunchID: binding.pendingLaunchID,
            session: binding.session), to: item)
      }
      return true
    case .stopped:
      if item.state == .cancelling {
        try await apply(.confirmCancellation(attemptID: attempt.id), to: item)
      } else {
        try await apply(.confirmFailure(attemptID: attempt.id), to: item)
      }
      return true
    case .requiresAttention(let reason):
      if item.state == .launching { try await apply(.confirmFailure(attemptID: attempt.id), to: item) }
      try await requireAttention(reason, runID: item.runID)
      return false
    case .uncertain:
      return try await recordUncertainty(item, attempt: attempt)
    }
  }

  private func recordUncertainty(_ item: OrchestratorQueueItem,
    attempt: OrchestratorDispatchAttempt) async throws -> Bool
  {
    if item.state == .launching || item.state == .running {
      try await apply(.requireReconciliation(attemptID: attempt.id), to: item)
    }
    return false
  }

  private func observe(_ attempt: OrchestratorDispatchAttempt, item: OrchestratorQueueItem,
    cancelling: Bool) async -> OrchestratorWorkerObservation
  {
    do {
      if cancelling { return try await workers.cancel(attempt: attempt, session: item.session) }
      return try await workers.observe(attempt: attempt, session: item.session)
    } catch {
      return .uncertain
    }
  }

  private func settleAllocations(runID: UUID) async throws -> Bool {
    var resolved = true
    for pending in try await metadata.pendingWorkflowAllocations() {
      guard case .request(let request) = pending, request.runID == runID else { continue }
      do {
        try await allocations.allocate(request)
      } catch OrchestratorMetadataError.allocationRejected {
        // This request was definitely rejected and its claim was released.
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        resolved = false
      }
    }
    return resolved
  }
}
