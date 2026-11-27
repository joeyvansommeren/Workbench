import Foundation

public enum OrchestratorRunCommand: Codable, Equatable, Sendable {
  case start(at: Date)
  case pause
  /// The runtime verifies that in-flight work reached a safe waiting point before confirming.
  case confirmPaused
  /// Reconciliation must establish source, claims and session/process identity before this event.
  case resumeAfterReconciliation
  case stop
  /// This records verified cancellation/quiescence, never merely a cancellation request.
  case confirmStopped
  case confirmCompleted
  case confirmProviders(OrchestratorRunProviders)
  case confirmQueueScope(OrchestratorQueueScope)
  case requireAttention(OrchestratorRunAttention)
  case clearAttention
}

public struct OrchestratorRunEvent: Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let expectedRevision: UInt64
  public let command: OrchestratorRunCommand

  public init(id: UUID, runID: UUID, expectedRevision: UInt64, command: OrchestratorRunCommand) {
    self.id = id
    self.runID = runID
    self.expectedRevision = expectedRevision
    self.command = command
  }
}

public enum OrchestratorItemCommand: Codable, Equatable, Sendable {
  case block(reason: String)
  case queueAfterVerification
  /// This transition records intent only. The runtime must verify eligibility and reserve a claim.
  case beginDispatch(OrchestratorDispatchAttempt, at: Date, activeImplementations: Int)
  case requireReconciliation(attemptID: UUID)
  // Optional only so old saved events can decode. New confirmations must supply it.
  case confirmLaunch(attemptID: UUID, pendingLaunchID: UUID?, session: OrchestratorSessionIdentity)
  case handOff(attemptID: UUID, session: OrchestratorSessionIdentity?)
  /// A confirmed failure means the runtime established that the attempt cannot still launch/run.
  case confirmFailure(attemptID: UUID)
  case requestCancellation
  case confirmCancellation(attemptID: UUID)
  case retry(OrchestratorDispatchAttempt, at: Date, activeImplementations: Int)
  case skip
  case verifyDependencies(OrchestratorDependencyVerification)
  /// Records externally verified acceptance and integration. Does not update a tracker.
  case confirmCompletion(attemptID: UUID, evidenceID: UUID)
  case skipAfterReview(attemptID: UUID)
}

public struct OrchestratorItemEvent: Codable, Equatable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let itemID: UUID
  public let expectedRevision: UInt64
  public let command: OrchestratorItemCommand

  public init(
    id: UUID, runID: UUID, itemID: UUID, expectedRevision: UInt64,
    command: OrchestratorItemCommand
  ) {
    self.id = id
    self.runID = runID
    self.itemID = itemID
    self.expectedRevision = expectedRevision
    self.command = command
  }
}

public enum OrchestratorTransitionResult: Equatable, Sendable {
  case applied
  case duplicate
}

public enum OrchestratorTransitionError: Error, Equatable, Sendable {
  case wrongRun
  case wrongItem
  case staleRevision
  case conflictingEvent
  case revisionExhausted
  case invalidRunTransition
  case invalidItemTransition
  case invalidStartTime
  case wrongAttempt
  case wrongProvider
  case wrongPendingLaunch
  case wrongSession
  case invalidRetryLineage
  case retryLimitReached
  case invalidDependencyEvidence
  case workRemains
  case dispatchDenied(OrchestratorDispatchDecision)
}

/// Pure decisions only. Callers must persist events and verify source/claim/process evidence.
/// A successful transition never launches, cancels, accepts, publishes or completes tracker work.
public enum OrchestratorStateMachine {
  @discardableResult
  public static func apply(
    _ event: OrchestratorRunEvent, to run: inout OrchestratorRun,
    items: [OrchestratorQueueItem] = []
  ) throws -> OrchestratorTransitionResult {
    guard event.runID == run.id else { throw OrchestratorTransitionError.wrongRun }
    if event.id == run.lastEvent?.id {
      guard event == run.lastEvent else { throw OrchestratorTransitionError.conflictingEvent }
      return .duplicate
    }
    try validateRevision(event.expectedRevision, current: run.revision)
    var next = run
    switch (run.state, event.command) {
    case (.draft, .start(let date)):
      guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw OrchestratorTransitionError.invalidStartTime
      }
      next.startedAt = date
      next.state = .running
    case (.running, .pause):
      next.state = .pausing
    case (.pausing, .confirmPaused):
      next.state = .paused
    case (.paused, .resumeAfterReconciliation):
      next.state = .running
    case (.draft, .stop), (.running, .stop), (.pausing, .stop), (.paused, .stop):
      next.state = .stopping
    case (.stopping, .confirmStopped):
      try validateSelectedItems(items, in: run) { $0.isTerminal || $0 == .awaitingReview }
      next.state = .stopped
      next.attention = nil
    case (.running, .confirmCompleted), (.paused, .confirmCompleted):
      try validateSelectedItems(items, in: run) { $0.isTerminal }
      next.state = .completed
      next.attention = nil
    case (.draft, .confirmProviders(let providers)), (.running, .confirmProviders(let providers)),
      (.pausing, .confirmProviders(let providers)), (.paused, .confirmProviders(let providers)):
      guard run.providers == nil else { throw OrchestratorTransitionError.invalidRunTransition }
      next.providers = providers
    case (.draft, .confirmQueueScope(let scope)), (.running, .confirmQueueScope(let scope)),
      (.pausing, .confirmQueueScope(let scope)), (.paused, .confirmQueueScope(let scope)):
      guard run.queueScope == nil else { throw OrchestratorTransitionError.invalidRunTransition }
      try scope.validate()
      next.queueScope = scope
    case (.draft, .requireAttention(let reason)), (.running, .requireAttention(let reason)),
      (.pausing, .requireAttention(let reason)), (.paused, .requireAttention(let reason)),
      (.stopping, .requireAttention(let reason)):
      next.attention = reason
    case (.draft, .clearAttention), (.running, .clearAttention),
      (.pausing, .clearAttention), (.paused, .clearAttention), (.stopping, .clearAttention):
      guard run.attention != nil else { throw OrchestratorTransitionError.invalidRunTransition }
      next.attention = nil
    default:
      throw OrchestratorTransitionError.invalidRunTransition
    }
    next.revision += 1
    next.lastEvent = event
    run = next
    return .applied
  }

  @discardableResult
  public static func apply(
    _ event: OrchestratorItemEvent, to item: inout OrchestratorQueueItem,
    run: OrchestratorRun
  ) throws -> OrchestratorTransitionResult {
    guard event.runID == item.runID, run.id == item.runID else {
      throw OrchestratorTransitionError.wrongRun
    }
    guard event.itemID == item.id,
      run.selection.contains(where: { $0.id == item.id && $0.issue == item.issue })
    else { throw OrchestratorTransitionError.wrongItem }
    if event.id == item.lastEvent?.id {
      guard event == item.lastEvent else { throw OrchestratorTransitionError.conflictingEvent }
      return .duplicate
    }
    try validateRevision(event.expectedRevision, current: item.revision)
    var next = item
    try applyItemCommand(event.command, to: &next, run: run)
    next.revision += 1
    next.lastEvent = event
    item = next
    return .applied
  }

  private static func applyItemCommand(
    _ command: OrchestratorItemCommand, to item: inout OrchestratorQueueItem, run: OrchestratorRun
  ) throws {
    switch command {
    case .block, .queueAfterVerification, .skip, .verifyDependencies:
      try updateEligibility(command, item: &item, prerequisites: prerequisites(of: item, in: run))
    case .beginDispatch(let attempt, let date, let active):
      try beginDispatch(attempt, at: date, active: active, item: &item, run: run)
    case .retry(let attempt, let date, let active):
      try beginRetry(attempt, at: date, active: active, item: &item, run: run)
    case .requestCancellation:
      try requestCancellation(item: &item)
    default:
      try updateAttempt(command, item: &item)
    }
  }

  private static func updateEligibility(
    _ command: OrchestratorItemCommand, item: inout OrchestratorQueueItem,
    prerequisites: Set<OrchestratorIssueIdentity>
  ) throws {
    switch (item.state, command) {
    case (.queued, .block(let reason)):
      try requireOrchestratorIdentifier(reason, field: "blockedReason")
      item.blockedReason = reason
      item.state = .blocked
    case (.blocked, .queueAfterVerification):
      item.blockedReason = nil
      item.state = .queued
    case (.queued, .skip), (.blocked, .skip):
      item.state = .skipped
    case (.queued, .verifyDependencies(let verification)),
      (.blocked, .verifyDependencies(let verification)),
      (.failed, .verifyDependencies(let verification)),
      (.cancelled, .verifyDependencies(let verification)):
      let verified = Set(verification.integratedIssues)
      guard !prerequisites.isEmpty, verified == prerequisites,
        verified.count == verification.integratedIssues.count
      else { throw OrchestratorTransitionError.invalidDependencyEvidence }
      item.dependencyVerification = verification
    default:
      throw OrchestratorTransitionError.invalidItemTransition
    }
  }

  private static func updateAttempt(
    _ command: OrchestratorItemCommand, item: inout OrchestratorQueueItem
  ) throws {
    switch command {
    case .requireReconciliation(let attemptID):
      try advanceAttempt(attemptID, from: [.launching, .running], to: .reconciling, item: &item)
    case .confirmLaunch(let attemptID, let pendingLaunchID, let session):
      try confirmLaunch(attemptID, pendingLaunchID: pendingLaunchID, session: session, item: &item)
    case .handOff(let attemptID, let session):
      guard let session, session == item.session else {
        throw OrchestratorTransitionError.wrongSession
      }
      try advanceAttempt(attemptID, from: [.running], to: .awaitingReview, item: &item)
    case .confirmFailure(let attemptID):
      try advanceAttempt(attemptID, from: [.launching, .running, .reconciling], to: .failed, item: &item)
    case .confirmCancellation(let attemptID):
      try advanceAttempt(attemptID, from: [.cancelling], to: .cancelled, item: &item)
    case .confirmCompletion(let attemptID, let evidenceID):
      try advanceAttempt(attemptID, from: [.awaitingReview], to: .completed, item: &item)
      item.completionEvidenceID = evidenceID
    case .skipAfterReview(let attemptID):
      try advanceAttempt(attemptID, from: [.awaitingReview], to: .skipped, item: &item)
    default:
      throw OrchestratorTransitionError.invalidItemTransition
    }
  }

  private static func beginDispatch(
    _ attempt: OrchestratorDispatchAttempt, at date: Date, active: Int,
    item: inout OrchestratorQueueItem, run: OrchestratorRun
  ) throws {
    guard item.state == .queued, item.attempt == nil else {
      throw OrchestratorTransitionError.invalidItemTransition
    }
    try validateAttempt(attempt, item: item)
    guard attempt.predecessorID == nil else {
      throw OrchestratorTransitionError.invalidRetryLineage
    }
    try validateDispatch(run: run, date: date, active: active)
    try validateLaunchContext(attempt, item: item, run: run)
    item.attempts.append(attempt)
    item.state = .launching
  }

  private static func beginRetry(
    _ attempt: OrchestratorDispatchAttempt, at date: Date, active: Int,
    item: inout OrchestratorQueueItem, run: OrchestratorRun
  ) throws {
    guard [.failed, .cancelled].contains(item.state), let previous = item.attempt else {
      throw OrchestratorTransitionError.invalidItemTransition
    }
    try validateAttempt(attempt, item: item)
    guard attempt.provider.rawValue.utf8.elementsEqual(previous.provider.rawValue.utf8) else {
      throw OrchestratorTransitionError.wrongProvider
    }
    guard attempt.predecessorID == previous.id,
      attempt.ticketRunID == previous.ticketRunID, attempt.branchRunID == previous.branchRunID,
      !item.attempts.contains(where: {
        $0.id == attempt.id || $0.operationID == attempt.operationID
          || $0.pendingLaunchID == attempt.pendingLaunchID
      })
    else { throw OrchestratorTransitionError.invalidRetryLineage }
    guard item.retryCount < run.policy.maximumRetries else {
      throw OrchestratorTransitionError.retryLimitReached
    }
    try validateDispatch(run: run, date: date, active: active)
    try validateLaunchContext(attempt, item: item, run: run)
    item.retryCount += 1
    item.attempts.append(attempt)
    item.session = nil
    item.blockedReason = nil
    item.state = .launching
  }

  private static func confirmLaunch(
    _ attemptID: UUID, pendingLaunchID: UUID?, session: OrchestratorSessionIdentity,
    item: inout OrchestratorQueueItem
  ) throws {
    let stateAfterBinding: OrchestratorQueueState = item.state == .cancelling ? .cancelling : .running
    try advanceAttempt(
      attemptID, from: [.launching, .reconciling, .cancelling], to: stateAfterBinding, item: &item)
    guard let attempt = item.attempt, pendingLaunchID == attempt.pendingLaunchID else {
      throw OrchestratorTransitionError.wrongPendingLaunch
    }
    guard session.provider.rawValue.utf8.elementsEqual(attempt.provider.rawValue.utf8) else {
      throw OrchestratorTransitionError.wrongProvider
    }
    if let existing = item.session, existing != session {
      throw OrchestratorTransitionError.wrongAttempt
    }
    item.session = session
  }

  private static func advanceAttempt(
    _ attemptID: UUID, from states: Set<OrchestratorQueueState>, to state: OrchestratorQueueState,
    item: inout OrchestratorQueueItem
  ) throws {
    try validateCurrentAttempt(attemptID, item: item)
    guard states.contains(item.state) else { throw OrchestratorTransitionError.invalidItemTransition }
    item.state = state
  }

  private static func requestCancellation(item: inout OrchestratorQueueItem) throws {
    switch item.state {
    case .queued, .blocked:
      item.state = .cancelled
    case .launching, .reconciling, .running:
      item.state = .cancelling
    default:
      throw OrchestratorTransitionError.invalidItemTransition
    }
  }

  private static func prerequisites(
    of item: OrchestratorQueueItem, in run: OrchestratorRun
  ) -> Set<OrchestratorIssueIdentity> {
    Set(run.selection.first { $0.id == item.id }?.prerequisites ?? [])
  }

  private static func validateRevision(_ expected: UInt64, current: UInt64) throws {
    guard expected == current else { throw OrchestratorTransitionError.staleRevision }
    guard current < UInt64.max else { throw OrchestratorTransitionError.revisionExhausted }
  }

  private static func validateSelectedItems(
    _ items: [OrchestratorQueueItem], in run: OrchestratorRun,
    where isSettled: (OrchestratorQueueState) -> Bool
  ) throws {
    let expected = Set(run.selection.map(\.id))
    guard items.count == expected.count, Set(items.map(\.id)) == expected,
      items.allSatisfy({ $0.runID == run.id && isSettled($0.state) })
    else { throw OrchestratorTransitionError.workRemains }
  }

  private static func validateAttempt(
    _ attempt: OrchestratorDispatchAttempt, item: OrchestratorQueueItem
  ) throws {
    guard attempt.runID == item.runID else { throw OrchestratorTransitionError.wrongRun }
    guard attempt.itemID == item.id else { throw OrchestratorTransitionError.wrongItem }
  }

  private static func validateCurrentAttempt(_ id: UUID, item: OrchestratorQueueItem) throws {
    guard item.attempt?.id == id else { throw OrchestratorTransitionError.wrongAttempt }
  }

  private static func validateLaunchContext(
    _ attempt: OrchestratorDispatchAttempt, item: OrchestratorQueueItem, run: OrchestratorRun
  ) throws {
    guard let provider = run.providers?.implementer,
      attempt.provider.rawValue.utf8.elementsEqual(provider.rawValue.utf8)
    else { throw OrchestratorTransitionError.wrongProvider }
    guard let base = attempt.baseCommitID, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified) }
    let prerequisites = prerequisites(of: item, in: run)
    guard prerequisites.isEmpty || (
      item.dependencyVerification?.baseCommitID.utf8.elementsEqual(base.utf8) == true
        && Set(item.dependencyVerification?.integratedIssues ?? []) == prerequisites
        && !run.issuesBlockedByDependencyCycles.contains(item.issue)
    ) else { throw OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified) }
  }

  private static func validateDispatch(run: OrchestratorRun, date: Date, active: Int) throws {
    let decision = run.dispatchDecision(at: date, activeImplementations: active)
    guard decision == .allowed else { throw OrchestratorTransitionError.dispatchDenied(decision) }
  }
}
