import Foundation

extension OrchestratorQueueExecutor {
  private struct Preparation {
    let snapshot: OrchestratorSourceRevision
    let plan: OrchestratorWorktreePlan
    let allocation: WorkflowAllocationRequest?
  }

  func dispatch(_ original: OrchestratorQueueItem, in run: OrchestratorRun, retry: Bool)
    async throws -> OrchestratorDispatchOutcome?
  {
    guard let selected = run.selection.first(where: { $0.id == original.id }) else {
      throw OrchestratorExecutionError.missingSelection(original.id)
    }
    guard let preparation = try await prepare(original, selected: selected, run: run) else {
      let updated = try await self.run(run.id)
      return updated.attention == nil ? nil : .suspended(.runNeedsAttention)
    }
    // A stop, pause or clock change can occur while the tracker and planner are suspended.
    var items = try await metadata.orchestratorItems(runID: run.id)
    let current = try await self.run(run.id)
    let decision = dispatchDecision(current, items: items)
    guard decision == .allowed else { return .suspended(decision) }

    var item = try await refreshEligibility(original, preparation: preparation, retry: retry)
    let allocation: WorkflowAllocationRequest
    do {
      allocation = try await ensureAllocation(for: item, run: current, preparation: preparation)
    } catch OrchestratorMetadataError.issueAlreadyClaimed {
      try await block(item, because: .issueClaimed)
      return nil
    } catch OrchestratorMetadataError.allocationConflict {
      try await requireAttention(.reconciliationRequired, runID: current.id)
      return .suspended(.runNeedsAttention)
    }
    items = try await metadata.orchestratorItems(runID: run.id)
    let latest = try await self.run(run.id)
    let latestDecision = dispatchDecision(latest, items: items)
    guard latestDecision == .allowed else { return .suspended(latestDecision) }
    item = try await self.item(runID: run.id, itemID: item.id)
    // Re-read authorization after allocating. Scope and revision can change while
    // the second database is being written.
    guard try await verifySource(preparation.snapshot, selected: selected, run: latest, item: item)
    else { return nil }
    // Wake can close local admission while the durable state is still Running.
    guard hasAdmission(run.id) else { return .suspended(.runNeedsAttention) }

    let attempt = try OrchestratorDispatchAttempt(
      id: UUID(), operationID: retry ? UUID() : allocation.operationID,
      runID: item.runID, itemID: item.id, predecessorID: retry ? item.attempt?.id : nil,
      pendingLaunchID: UUID(), provider: allocation.implementerProvider,
      ticketRunID: allocation.ticketRunID, branchRunID: allocation.branchRunID,
      baseCommitID: preparation.plan.baseCommitID)
    let active = items.count(where: { $0.state.holdsDispatchSlot })
    // The metadata transaction validates revision, claim, and the live dispatch
    // count again before granting this operation the launch slot.
    try await apply(
      retry ? .retry(attempt, at: clock.now(), activeImplementations: active)
        : .beginDispatch(attempt, at: clock.now(), activeImplementations: active), to: item)
    try await launch(
      .init(attempt: attempt, plan: preparation.plan, snapshot: preparation.snapshot))
    return .attempted(itemID: item.id, attemptID: attempt.id)
  }

  private func prepare(_ item: OrchestratorQueueItem, selected: OrchestratorSelectedIssue,
    run: OrchestratorRun) async throws -> Preparation?
  {
    if run.issuesBlockedByDependencyCycles.contains(selected.issue) {
      try await block(item, because: .dependencyCycle)
      return nil
    }
    guard let snapshot = try await readSource(selected, run: run, item: item) else { return nil }
    let allocation = try await metadata.acknowledgedWorkflowAllocation(runID: run.id, itemID: item.id)
    switch try await planner.prepare(selection: selected, snapshot: snapshot, existingAllocation: allocation) {
    case .ready(let plan):
      guard Self.matches(plan, selected: selected, allocation: allocation) else {
        try await block(item, because: .repositoryUnverified)
        return nil
      }
      guard Self.dependenciesMatch(plan, selected: selected) else {
        try await block(item, because: .dependencyUnverified)
        return nil
      }
      return Preparation(snapshot: snapshot, plan: plan, allocation: allocation)
    case .blocked(let reason):
      try await block(item, because: reason)
      return nil
    }
  }

  private func refreshEligibility(_ original: OrchestratorQueueItem, preparation: Preparation,
    retry: Bool) async throws -> OrchestratorQueueItem
  {
    var item = try await self.item(runID: original.runID, itemID: original.id)
    guard item.revision == original.revision else { throw OrchestratorTransitionError.staleRevision }
    if item.state == .blocked, !retry {
      try await apply(.queueAfterVerification, to: item)
      item = try await self.item(runID: item.runID, itemID: item.id)
    }
    if let dependencies = preparation.plan.dependencies, dependencies != item.dependencyVerification {
      try await apply(.verifyDependencies(dependencies), to: item)
      item = try await self.item(runID: item.runID, itemID: item.id)
    }
    return item
  }

  private func ensureAllocation(for item: OrchestratorQueueItem, run: OrchestratorRun,
    preparation: Preparation) async throws -> WorkflowAllocationRequest
  {
    if let allocation = preparation.allocation { return allocation }
    guard let providers = run.providers else { throw OrchestratorExecutionError.unavailable }
    let plan = preparation.plan
    let request = try WorkflowAllocationRequest(
      operationID: UUID(), runID: run.id, itemID: item.id, issue: item.issue,
      ticketRunID: UUID(), branchRunID: UUID(), ticketCreatedEventID: UUID(),
      branchCreatedEventID: UUID(), ticketKey: preparation.snapshot.ticketKey,
      repositoryPath: plan.repository.repositoryPath, worktreePath: plan.worktreePath,
      branchName: plan.branchName, baseBranch: plan.repository.baseBranch,
      baseCommitID: plan.baseCommitID, coordinatorProvider: providers.coordinator,
      implementerProvider: providers.implementer, reviewerProvider: providers.reviewer,
      createdAt: clock.now())
    try await allocations.allocate(request)
    return request
  }

  private func verifySource(_ expected: OrchestratorSourceRevision, selected: OrchestratorSelectedIssue,
    run: OrchestratorRun, item: OrchestratorQueueItem) async throws -> Bool
  {
    guard let actual = try await readSource(selected, run: run, item: item) else { return false }
    guard actual == expected else {
      try await block(item, because: .revisionChanged)
      return false
    }
    return true
  }

  private func readSource(_ selected: OrchestratorSelectedIssue, run: OrchestratorRun,
    item: OrchestratorQueueItem) async throws -> OrchestratorSourceRevision?
  {
    let check: OrchestratorSourceCheck
    do {
      check = try await source.eligibility(of: selected, in: run)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      check = .unavailable(.sourceUnavailable)
    }
    switch check {
    case .eligible(let snapshot):
      guard snapshot.issue == selected.issue, snapshot.queueScope == run.queueScope,
        !snapshot.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !snapshot.ticketKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        try await block(item, because: .issueUnavailable)
        return nil
      }
      return snapshot
    case .blocked(let reason):
      try await block(item, because: reason)
      return nil
    case .unavailable(let reason):
      try await requireAttention(reason, runID: run.id)
      return nil
    }
  }

  private func block(_ item: OrchestratorQueueItem, because reason: OrchestratorEligibilityBlock)
    async throws
  {
    if item.state == .queued { try await apply(.block(reason: reason.message), to: item) }
  }

  private func launch(_ launch: OrchestratorWorkerLaunch) async throws {
    let attempt = launch.attempt
    let current = try await run(attempt.runID)
    guard current.state == .running, current.attention == nil,
      hasAdmission(attempt.runID), !Task.isCancelled
    else {
      // The adapter was not called for this attempt, so there is no live worker.
      let currentItem = try await item(runID: attempt.runID, itemID: attempt.itemID)
      try await record(.stopped, for: currentItem, attempt: attempt)
      return
    }
    let observation: OrchestratorWorkerObservation
    do {
      observation = try await workers.launch(launch)
    } catch {
      observation = .uncertain
    }
    let currentItem = try await item(runID: attempt.runID, itemID: attempt.itemID)
    try await record(observation, for: currentItem, attempt: attempt)
  }

  private static func matches(_ plan: OrchestratorWorktreePlan,
    selected: OrchestratorSelectedIssue, allocation: WorkflowAllocationRequest?) -> Bool
  {
    guard let approved = selected.repository, plan.repository == approved,
      absoluteStandardPath(approved.repositoryPath), absoluteStandardPath(plan.worktreePath)
    else { return false }
    let repo = URL(fileURLWithPath: approved.repositoryPath)
    let worktree = URL(fileURLWithPath: plan.worktreePath)
    guard !plan.worktreePath.utf8.elementsEqual(approved.repositoryPath.utf8),
      repo.deletingLastPathComponent().path.utf8.elementsEqual(
        worktree.deletingLastPathComponent().path.utf8)
    else { return false }
    if let launchPath = plan.launchPath {
      guard absoluteStandardPath(launchPath),
        launchPath.utf8.elementsEqual(plan.worktreePath.utf8)
          || launchPath.utf8.starts(with: (plan.worktreePath + "/").utf8)
      else { return false }
    }
    guard let allocation else { return true }
    return allocation.repositoryPath.utf8.elementsEqual(approved.repositoryPath.utf8)
      && allocation.baseBranch.utf8.elementsEqual(approved.baseBranch.utf8)
      && allocation.worktreePath.utf8.elementsEqual(plan.worktreePath.utf8)
      && allocation.branchName.utf8.elementsEqual(plan.branchName.utf8)
  }

  private static func absoluteStandardPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(0)
      && URL(fileURLWithPath: path).standardizedFileURL.path.utf8.elementsEqual(path.utf8)
  }

  private static func dependenciesMatch(_ plan: OrchestratorWorktreePlan,
    selected: OrchestratorSelectedIssue) -> Bool
  {
    guard !plan.baseCommitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !plan.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    if selected.prerequisites.isEmpty { return plan.dependencies == nil }
    guard let evidence = plan.dependencies else { return false }
    return evidence.baseCommitID.utf8.elementsEqual(plan.baseCommitID.utf8)
      && Set(evidence.integratedIssues) == Set(selected.prerequisites)
      && evidence.integratedIssues.count == selected.prerequisites.count
  }
}
