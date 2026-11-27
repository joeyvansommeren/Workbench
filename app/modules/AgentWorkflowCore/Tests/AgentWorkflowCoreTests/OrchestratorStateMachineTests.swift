import Foundation
import Testing

@testable import AgentWorkflowCore

@Suite("Orchestrator dispatch decisions")
struct OrchestratorStateMachineTests {
  @Test("Retry cannot silently change its provider or existing workflow bindings")
  func retryBindings() throws {
    let run = try runningRun()
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: item)
    try applyItem(
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    try applyItem(.confirmFailure(attemptID: first.id), to: &item, run: run)
    let before = item
    for (provider, ticketID, branchID) in [
      (AgentProviderID.claude, first.ticketRunID, first.branchRunID),
      (.codex, orchestrationID(601), first.branchRunID),
      (.codex, first.ticketRunID, orchestrationID(701)),
    ] {
      var candidate = before
      let changed = try OrchestratorDispatchAttempt(
        id: orchestrationID(202), operationID: orchestrationID(302), runID: item.runID,
        itemID: item.id, predecessorID: first.id, pendingLaunchID: orchestrationID(402),
        provider: provider, ticketRunID: ticketID, branchRunID: branchID, baseCommitID: "base")
      #expect(throws: OrchestratorTransitionError.self) {
        try applyItem(
          .retry(changed, at: orchestrationStart, activeImplementations: 0), to: &candidate,
          run: run)
      }
      #expect(candidate == before)
    }
  }

  @Test("Queue transition table rejects every undefined pair without mutation")
  func queueTransitions() throws {
    let run = try runningRun()
    let selected = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: selected)
    let second = try attempt(2, item: selected, predecessor: first.id)
    let session = try OrchestratorSessionIdentity(provider: .codex, sessionID: "real")
    let commands: [OrchestratorItemCommand] = [
      .block(reason: "Dependency unavailable"), .queueAfterVerification,
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0),
      .requireReconciliation(attemptID: first.id),
      .confirmLaunch(attemptID: first.id, pendingLaunchID: first.pendingLaunchID, session: session), .handOff(attemptID: first.id, session: session),
      .confirmFailure(attemptID: first.id), .requestCancellation,
      .confirmCancellation(attemptID: first.id),
      .retry(second, at: orchestrationStart, activeImplementations: 0), .skip,
      .confirmCompletion(attemptID: first.id, evidenceID: orchestrationID(88)),
      .skipAfterReview(attemptID: first.id),
    ]
    let allowed: [OrchestratorQueueState: [Int: OrchestratorQueueState]] = [
      .queued: [0: .blocked, 2: .launching, 7: .cancelled, 10: .skipped],
      .blocked: [1: .queued, 7: .cancelled, 10: .skipped],
      .launching: [3: .reconciling, 4: .running, 6: .failed, 7: .cancelling],
      .reconciling: [4: .running, 6: .failed, 7: .cancelling],
      .running: [3: .reconciling, 5: .awaitingReview, 6: .failed, 7: .cancelling],
      .awaitingReview: [11: .completed, 12: .skipped],
      .failed: [9: .launching], .cancelling: [4: .cancelling, 8: .cancelled], .cancelled: [9: .launching],
    ]
    for state in OrchestratorQueueState.allCases {
      for (index, command) in commands.enumerated() {
        var item = selected
        item.state = state
        if ![.queued, .blocked, .skipped].contains(state) { item.attempts = [first] }
        if state == .running { item.session = session }
        let before = item
        if let target = allowed[state]?[index] {
          #expect(try applyItem(command, to: &item, run: run) == .applied)
          #expect(item.state == target)
          #expect(item.revision == 1)
        } else {
          #expect(throws: OrchestratorTransitionError.self) {
            try applyItem(command, to: &item, run: run)
          }
          #expect(item == before)
        }
      }
    }
  }

  @Test("Run control transition table rejects every undefined pair without mutation")
  func runTransitions() throws {
    let commands: [OrchestratorRunCommand] = [
      .start(at: orchestrationStart), .pause, .confirmPaused, .resumeAfterReconciliation,
      .stop, .confirmStopped,
    ]
    let allowed: [OrchestratorRunState: [Int: OrchestratorRunState]] = [
      .draft: [0: .running, 4: .stopping],
      .running: [1: .pausing, 4: .stopping],
      .pausing: [2: .paused, 4: .stopping],
      .paused: [3: .running, 4: .stopping],
      .stopping: [5: .stopped],
    ]
    for state in OrchestratorRunState.allCases {
      for (index, command) in commands.enumerated() {
        var run = try makeOrchestratorRun()
        run.state = state
        run.startedAt = state == .draft ? nil : orchestrationStart
        let before = run
        if let target = allowed[state]?[index] {
          #expect(try applyRun(command, to: &run) == .applied)
          #expect(run.state == target)
          #expect(run.revision == 1)
        } else {
          #expect(throws: OrchestratorTransitionError.invalidRunTransition) {
            try applyRun(command, to: &run)
          }
          #expect(run == before)
        }
      }
    }
  }

  @Test("Pause and stop retain uncertainty; resume retains the original time budget")
  func pauseAndStop() throws {
    var run = try makeOrchestratorRun()
    try applyRun(.start(at: orchestrationStart), to: &run)
    try applyRun(.pause, to: &run)
    #expect(run.state == .pausing)
    #expect(
      run.dispatchDecision(at: orchestrationStart, activeImplementations: 0) == .runNotRunning)
    #expect(throws: OrchestratorTransitionError.invalidRunTransition) {
      try applyRun(.resumeAfterReconciliation, to: &run)
    }
    try applyRun(.confirmPaused, to: &run)
    try applyRun(.resumeAfterReconciliation, to: &run)
    #expect(run.startedAt == orchestrationStart)
    #expect(
      run.dispatchDecision(at: orchestrationStart.addingTimeInterval(600), activeImplementations: 0)
        == .timeBudgetExhausted)
    try applyRun(.stop, to: &run)
    #expect(run.state == .stopping)
    try applyRun(.confirmStopped, to: &run)
    #expect(run.state == .stopped)
    #expect(throws: OrchestratorTransitionError.invalidRunTransition) {
      try applyRun(.resumeAfterReconciliation, to: &run)
    }
  }

  @Test("Duplicate, conflicting, foreign and out-of-order run events do not regress control")
  func runEventIdentity() throws {
    var run = try makeOrchestratorRun()
    let start = OrchestratorRunEvent(
      id: orchestrationID(500), runID: run.id, expectedRevision: 0,
      command: .start(at: orchestrationStart))
    try OrchestratorStateMachine.apply(start, to: &run)
    #expect(try OrchestratorStateMachine.apply(start, to: &run) == .duplicate)
    #expect(run.revision == 1)
    #expect(throws: OrchestratorTransitionError.conflictingEvent) {
      try OrchestratorStateMachine.apply(
        OrchestratorRunEvent(id: start.id, runID: run.id, expectedRevision: 1, command: .stop),
        to: &run)
    }
    #expect(throws: OrchestratorTransitionError.wrongRun) {
      try OrchestratorStateMachine.apply(
        OrchestratorRunEvent(
          id: start.id, runID: orchestrationID(999), expectedRevision: 1, command: .stop), to: &run)
    }
    try applyRun(.pause, to: &run)
    let before = run
    #expect(throws: OrchestratorTransitionError.staleRevision) {
      try OrchestratorStateMachine.apply(start, to: &run)
    }
    #expect(run == before)
  }

  @Test("Launch uncertainty cannot retry; exact session binding and handoff preserve workflow IDs")
  func uncertainLaunch() throws {
    let run = try runningRun()
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: item)
    try applyItem(
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    try applyItem(.requireReconciliation(attemptID: first.id), to: &item, run: run)
    let before = item
    #expect(throws: OrchestratorTransitionError.invalidItemTransition) {
      try applyItem(
        .retry(
          attempt(2, item: item, predecessor: first.id), at: orchestrationStart,
          activeImplementations: 0), to: &item, run: run)
    }
    #expect(item == before)
    #expect(throws: OrchestratorTransitionError.wrongProvider) {
      try applyItem(
        .confirmLaunch(
          attemptID: first.id, pendingLaunchID: first.pendingLaunchID,
          session: OrchestratorSessionIdentity(provider: .claude, sessionID: "real")), to: &item,
        run: run)
    }
    let session = try OrchestratorSessionIdentity(provider: .codex, sessionID: "real")
    try applyItem(.confirmLaunch(attemptID: first.id, pendingLaunchID: first.pendingLaunchID, session: session), to: &item, run: run)
    try applyItem(.handOff(attemptID: first.id, session: session), to: &item, run: run)
    #expect(item.state == .awaitingReview)
    #expect(item.session == session)
    #expect(item.attempt?.ticketRunID == first.ticketRunID)
    #expect(item.attempt?.branchRunID == first.branchRunID)
    #expect(run.state == .running)
  }

  @Test("Retry is explicit, bounded, linked and cannot reuse any earlier attempt operation")
  func retryLineage() throws {
    let run = try runningRun(retries: 2)
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: item)
    try applyItem(
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    try applyItem(.confirmFailure(attemptID: first.id), to: &item, run: run)
    #expect(throws: OrchestratorTransitionError.invalidRetryLineage) {
      try applyItem(
        .retry(attempt(2, item: item), at: orchestrationStart, activeImplementations: 0), to: &item,
        run: run)
    }
    let second = try attempt(2, item: item, predecessor: first.id)
    try applyItem(
      .retry(second, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    #expect(item.retryCount == 1)
    #expect(item.attempt?.predecessorID == first.id)
    #expect(throws: OrchestratorTransitionError.wrongAttempt) {
      try applyItem(.confirmFailure(attemptID: first.id), to: &item, run: run)
    }
    try applyItem(.confirmFailure(attemptID: second.id), to: &item, run: run)
    let reused = try attempt(1, item: item, predecessor: second.id)
    #expect(throws: OrchestratorTransitionError.invalidRetryLineage) {
      try applyItem(
        .retry(reused, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    }
    let third = try attempt(3, item: item, predecessor: second.id)
    try applyItem(
      .retry(third, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    try applyItem(.confirmFailure(attemptID: third.id), to: &item, run: run)
    #expect(throws: OrchestratorTransitionError.retryLimitReached) {
      try applyItem(
        .retry(
          attempt(4, item: item, predecessor: third.id), at: orchestrationStart,
          activeImplementations: 0), to: &item, run: run)
    }
    #expect(item.retryCount == 2)
    #expect(item.attempts.map(\.id) == [first.id, second.id, third.id])
  }

  @Test("Cancellation stays pending until explicit confirmation and never cancels workflow handoff")
  func cancellation() throws {
    let run = try runningRun()
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: item)
    try applyItem(
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &item, run: run)
    try applyItem(.requestCancellation, to: &item, run: run)
    #expect(item.state == .cancelling)
    #expect(throws: OrchestratorTransitionError.invalidItemTransition) {
      try applyItem(
        .retry(
          attempt(2, item: item, predecessor: first.id), at: orchestrationStart,
          activeImplementations: 0), to: &item, run: run)
    }
    let lateSession = try OrchestratorSessionIdentity(provider: .codex, sessionID: "late")
    try applyItem(
      .confirmLaunch(attemptID: first.id, pendingLaunchID: first.pendingLaunchID, session: lateSession),
      to: &item, run: run)
    #expect(item.state == .cancelling)
    #expect(item.session == lateSession)
    try applyItem(.confirmCancellation(attemptID: first.id), to: &item, run: run)
    #expect(item.state == .cancelled)
    try applyItem(
      .retry(
        attempt(2, item: item, predecessor: first.id), at: orchestrationStart,
        activeImplementations: 0), to: &item, run: run)
  }

  @Test("Queue identity rejects wrong run/item and replays without changing the current attempt")
  func itemEventIdentity() throws {
    let run = try runningRun()
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let block = OrchestratorItemEvent(
      id: orchestrationID(500), runID: run.id, itemID: item.id, expectedRevision: 0,
      command: .block(reason: "Dependency integration is unknown"))
    try OrchestratorStateMachine.apply(block, to: &item, run: run)
    #expect(try OrchestratorStateMachine.apply(block, to: &item, run: run) == .duplicate)
    #expect(item.revision == 1)
    let before = item
    #expect(throws: OrchestratorTransitionError.wrongItem) {
      try OrchestratorStateMachine.apply(
        OrchestratorItemEvent(
          id: orchestrationID(501), runID: run.id, itemID: orchestrationID(99), expectedRevision: 1,
          command: .skip), to: &item, run: run)
    }
    #expect(throws: OrchestratorTransitionError.wrongRun) {
      try OrchestratorStateMachine.apply(
        OrchestratorItemEvent(
          id: orchestrationID(501), runID: orchestrationID(99), itemID: item.id,
          expectedRevision: 1, command: .skip), to: &item, run: run)
    }
    #expect(item == before)
    try applyItem(.queueAfterVerification, to: &item, run: run)
    let queued = item
    #expect(throws: OrchestratorTransitionError.staleRevision) {
      try OrchestratorStateMachine.apply(block, to: &item, run: run)
    }
    #expect(item == queued)
  }

  @Test("Dispatch observes run pause, time and concurrency limits before recording an attempt")
  func dispatchLimits() throws {
    var run = try runningRun()
    var item = try OrchestratorQueueItem(run: run, itemID: orchestrationID(101))
    let first = try attempt(1, item: item)
    for (date, active, reason) in [
      (orchestrationStart, 1, OrchestratorDispatchDecision.concurrencyLimitReached),
      (orchestrationStart.addingTimeInterval(600), 0, .timeBudgetExhausted),
    ] {
      #expect(throws: OrchestratorTransitionError.dispatchDenied(reason)) {
        try applyItem(
          .beginDispatch(first, at: date, activeImplementations: active), to: &item, run: run)
      }
      #expect(item.attempt == nil)
      #expect(item.revision == 0)
    }
    try applyRun(.pause, to: &run)
    #expect(throws: OrchestratorTransitionError.dispatchDenied(.runNotRunning)) {
      try applyItem(
        .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &item, run: run
      )
    }
  }
}

extension OrchestratorStateMachineTests {
  @Test("Dependency verification applies to the selected prerequisite and is durable")
  func dependencyEvidence() throws {
    let prerequisite = try makeIssue(id: "prerequisite")
    let decisionID = orchestrationID(101)
    let selected = OrchestratorSelectedIssue(
      id: decisionID, issue: try makeIssue(), prerequisites: [prerequisite])
    var run = try OrchestratorRun(
      id: orchestrationID(100),
      policy: OrchestratorRunPolicy(maximumTickets: 1, wallClockLimit: 600),
      providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [selected])
    try applyRun(.start(at: orchestrationStart), to: &run)
    var item = try OrchestratorQueueItem(run: run, itemID: decisionID)
    let first = try attempt(1, item: item)
    let dispatch = OrchestratorItemCommand.beginDispatch(
      first, at: orchestrationStart, activeImplementations: 0)
    #expect(throws: OrchestratorTransitionError.dispatchDenied(.dependenciesUnverified)) {
      try applyItem(dispatch, to: &item, run: run)
    }
    let missingEvidence = try OrchestratorDependencyVerification(
      baseCommitID: "base", integratedIssues: [])
    #expect(throws: OrchestratorTransitionError.invalidDependencyEvidence) {
      try applyItem(.verifyDependencies(missingEvidence), to: &item, run: run)
    }
    let evidence = try OrchestratorDependencyVerification(
      baseCommitID: "base", integratedIssues: [prerequisite])
    try applyItem(.verifyDependencies(evidence), to: &item, run: run)
    item = try JSONDecoder().decode(OrchestratorQueueItem.self, from: JSONEncoder().encode(item))
    try applyItem(dispatch, to: &item, run: run)
    #expect(item.state == .launching)
    #expect(item.dependencyVerification == evidence)
  }

  @Test("Attention does not replace running work, and review does not complete the run")
  func aggregateState() throws {
    let activeSelection = OrchestratorSelectedIssue(
      id: orchestrationID(101), issue: try makeIssue(id: "active"))
    let blockedSelection = OrchestratorSelectedIssue(
      id: orchestrationID(102), issue: try makeIssue(id: "blocked"))
    var run = try OrchestratorRun(
      id: orchestrationID(100),
      policy: OrchestratorRunPolicy(maximumTickets: 2, wallClockLimit: 600),
      providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [activeSelection, blockedSelection])
    try applyRun(.start(at: orchestrationStart), to: &run)
    var active = try OrchestratorQueueItem(run: run, itemID: activeSelection.id)
    var blocked = try OrchestratorQueueItem(run: run, itemID: blockedSelection.id)
    let first = try attempt(1, item: active)
    try applyItem(
      .beginDispatch(first, at: orchestrationStart, activeImplementations: 0), to: &active,
      run: run)
    try applyItem(.block(reason: "Needs input"), to: &blocked, run: run)
    let summary = OrchestratorRunSummary(run: run, items: [active, blocked])
    #expect(summary.state == .running)
    #expect(summary.activeCount == 1)
    #expect(summary.attentionCount == 1)
    let complete = OrchestratorRunEvent(
      id: orchestrationID(877), runID: run.id, expectedRevision: run.revision,
      command: .confirmCompleted)
    #expect(throws: OrchestratorTransitionError.workRemains) {
      try OrchestratorStateMachine.apply(complete, to: &run, items: [active, blocked])
    }
    try applyItem(.confirmFailure(attemptID: first.id), to: &active, run: run)
    try applyItem(.skip, to: &blocked, run: run)
    #expect(try OrchestratorStateMachine.apply(complete, to: &run, items: [active, blocked]) == .applied)
    #expect(run.state == .completed)
  }
}

private func runningRun(retries: Int = 1) throws -> OrchestratorRun {
  var run = try makeOrchestratorRun(retries: retries)
  try applyRun(.start(at: orchestrationStart), to: &run)
  return run
}

private func attempt(
  _ number: Int, item: OrchestratorQueueItem, predecessor: UUID? = nil
) throws -> OrchestratorDispatchAttempt {
  try OrchestratorDispatchAttempt(
    id: orchestrationID(200 + number), operationID: orchestrationID(300 + number),
    runID: item.runID, itemID: item.id, predecessorID: predecessor,
    pendingLaunchID: orchestrationID(400 + number), provider: .codex,
    ticketRunID: orchestrationID(600), branchRunID: orchestrationID(700), baseCommitID: "base")
}

@discardableResult
private func applyItem(
  _ command: OrchestratorItemCommand, to item: inout OrchestratorQueueItem, run: OrchestratorRun
) throws -> OrchestratorTransitionResult {
  try OrchestratorStateMachine.apply(
    OrchestratorItemEvent(
      id: orchestrationID(2_000 + Int(item.revision)), runID: run.id, itemID: item.id,
      expectedRevision: item.revision, command: command), to: &item, run: run)
}
