import Foundation
import Testing

@testable import AgentWorkflowLinear

extension LinearQueueRequestTests {
  @Test("Visible teams require approval and a changed expected team set blocks capture")
  func visibleScopeApproval() async throws {
    let visibleReplies: [QueueHTTPStub.Reply] = [
      .ok(accountResponse), .ok(projectPage("teams", [team("alpha")])),
      .ok(statePage(team: "alpha", states: [state("entry")])),
      .ok(projectPage("issues", [issue("selected", team: "alpha")]))
    ]
    QueueHTTPStub.set(visibleReplies + visibleReplies)
    let api = client()
    let visible = try await api.queueProject(id: "project", account: account)
    let policy = try policyFor(visible, states: ["alpha": ["entry"]])
    #expect(visible.coverage == .accountVisible)
    #expect(throws: LinearQueueError.visibleScopeApprovalRequired) {
      try visible.capture(selectedIssueIDs: ["selected"], eligibility: policy)
    }
    let selection = try visible.capture(
      selectedIssueIDs: ["selected"], eligibility: policy, approveAccountVisibleScope: true)
    #expect(selection.coverage == .accountVisible)
    #expect(selection.teamIDs == ["alpha"])

    let changed = try await api.queueProject(id: "project", account: account, expectedTeamIDs: ["private"])
    #expect(changed.coverage == .accountVisible)
    #expect(changed.omissions.map(\.scope) == [.missingTeam(teamID: "private"), .addedTeam(teamID: "alpha")])
    #expect(throws: LinearQueueError.incompleteProject) {
      try changed.capture(selectedIssueIDs: ["selected"], eligibility: policy, approveAccountVisibleScope: true)
    }
  }

  @Test("A transport error in the last preflight leaves the first submission available")
  func failingPreflightCanResume() async throws {
    let original = issue("selected", team: "alpha")
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .offline,
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)), .http(429)
    ])
    await #expect(throws: LinearAPIError.self) {
      try await client().applyQueueTransition(plan, journal: journal)
    }
    #expect(await journal.phase == .prepared)
    #expect(QueueHTTPStub.requests.allSatisfy { !$0.query.hasPrefix("mutation") })
    #expect(try await client().applyQueueTransition(plan, journal: journal) == .rejected(.rateLimited))
    #expect(await journal.phase == .rejected(.rateLimited))
    #expect(QueueHTTPStub.requests.filter { $0.query.hasPrefix("mutation") }.count == 1)
  }

  @Test("An explicit API refusal resolves an intent without a readback or repeated mutation")
  func unsuccessfulMutationIsRejected() async throws {
    let original = issue("selected", team: "alpha")
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)),
      .ok(["data": ["issueUpdate": ["success": false]]]), .ok(accountResponse)
    ])
    #expect(try await client().applyQueueTransition(plan, journal: journal) == .rejected(.declined))
    #expect(try await client().applyQueueTransition(plan, journal: journal) == .rejected(.declined))
    #expect(await journal.phase == .rejected(.declined))
    #expect(QueueHTTPStub.requests.count == 5)
  }

  @Test("An ambiguous write allows one explicit retry after fresh verification and the cooldown")
  func boundedExplicitRetry() async throws {
    let original = issue("selected", team: "alpha")
    let initial = Date(timeIntervalSince1970: 1_000)
    let ready = initial.addingTimeInterval(LinearQueueTransitionAttempt.retryDelay)
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)),
      .offline, .ok(singleIssue(original)),
      .ok(accountResponse), .ok(singleIssue(original)),
      .ok(accountResponse), .ok(singleIssue(original)),
      .ok(accountResponse), .ok(singleIssue(original)),
      .ok(targetStateResponse), .ok(singleIssue(original)), .http(429),
      .ok(accountResponse), .ok(singleIssue(original))
    ])
    #expect(try await client(now: { initial }).applyQueueTransition(plan, journal: journal) == .uncertain)
    #expect(try await client(now: { ready }).applyQueueTransition(plan, journal: journal) == .uncertain)
    #expect(try await client(now: { initial }).retryQueueTransition(plan, journal: journal) == .uncertain)
    #expect(QueueHTTPStub.requests.filter { $0.query.hasPrefix("mutation") }.count == 1)
    #expect(try await client(now: { ready }).retryQueueTransition(plan, journal: journal) == .uncertain)
    #expect(try await client(now: { ready }).retryQueueTransition(plan, journal: journal) == .uncertain)
    #expect(QueueHTTPStub.requests.filter { $0.query.hasPrefix("mutation") }.count == 2)
    guard case .submitted(let attempt) = await journal.phase else {
      Issue.record("The first POST remains ambiguous despite a definite refusal of the retry")
      return
    }
    #expect(attempt.number == .retry)
  }

  @Test("Explicit retry leaves a concurrent human edit untouched")
  func retryRechecksRemoteRevision() async throws {
    let original = issue("selected", team: "alpha")
    let changed = issue("selected", team: "alpha", revision: "human-change")
    let initial = Date(timeIntervalSince1970: 1_000)
    let ready = initial.addingTimeInterval(LinearQueueTransitionAttempt.retryDelay)
    let plan = try makeTransition(original)
    let submitted = try #require(LinearQueueTransitionPhase.prepared.nextAttempt(at: initial))
    let journal = QueueTestJournal(phase: .submitted(submitted), plan: plan)
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(singleIssue(original)), .ok(targetStateResponse), .ok(singleIssue(changed))
    ])
    let outcome = try await client(now: { ready }).retryQueueTransition(plan, journal: journal)
    #expect(outcome == .conflict(.revisionChanged))
    #expect(await journal.phase == .submitted(submitted))
    #expect(QueueHTTPStub.requests.allSatisfy { !$0.query.hasPrefix("mutation") })
  }

  @Test("An overlapping call does not attempt readback while the adapter is submitting")
  func keepsInFlightReceiptAuthoritative() async throws {
    let original = issue("selected", team: "alpha")
    let mutationIssue = issue(
      "selected", team: "alpha", stateID: "active", stateType: "started", revision: "mutation")
    let plan = try makeTransition(original)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let journal = QueueTestJournal(submissionBarrier: {
      entered.continuation.yield(())
      _ = await release.stream.first { _ in true }
    })
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)),
      .ok(accountResponse), .ok(["data": ["issueUpdate": ["success": true, "issue": mutationIssue]]])
    ])
    let api = client()
    async let first = api.applyQueueTransition(plan, journal: journal)
    defer { release.continuation.finish() }
    _ = await entered.stream.first { _ in true }
    let overlap = try await api.applyQueueTransition(plan, journal: journal)
    release.continuation.yield(())
    #expect(overlap == .uncertain)
    #expect(try await first == .confirmed(stateID: "active", revision: "mutation"))
    #expect(await journal.phase == .confirmed(revision: "mutation"))
    #expect(QueueHTTPStub.requests.count == 5)
  }

  @Test("Active reconciliation accepts the scoped mutation receipt and detects later human edits")
  func trustedActiveProgress() async throws {
    let original = issue("selected", team: "alpha")
    let mutationIssue = issue(
      "selected", team: "alpha", stateID: "active", stateType: "started", revision: "mutation")
    let laterEdit = issue(
      "selected", team: "alpha", stateID: "active", stateType: "started", revision: "human-edit")
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(projectPage("teams", [team("alpha")])),
      .ok(statePage(team: "alpha", states: [state("entry")])), .ok(projectPage("issues", [original])),
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)),
      .ok(["data": ["issueUpdate": ["success": true, "issue": mutationIssue]]]),
      .ok(accountResponse), .ok(singleIssue(mutationIssue)), .ok(dependencyPage("selected", [])),
      .ok(accountResponse), .ok(singleIssue(laterEdit)), .ok(dependencyPage("selected", []))
    ])
    let api = client()
    let project = try await api.queueProject(id: "project", account: account, expectedTeamIDs: ["alpha"])
    let scope = try policyFor(project, states: ["alpha": ["entry"]])
    let selection = try project.capture(selectedIssueIDs: ["selected"], eligibility: scope)
    #expect(try await api.applyQueueTransition(plan, journal: journal)
      == .confirmed(stateID: "active", revision: "mutation"))
    let started = try await api.queueIssue(id: "selected", account: account)
    let changed = try await api.queueIssue(id: "selected", account: account)
    #expect(try await selection.recheckActiveIssue(
      issueID: "selected", current: started, account: account, confirmedOperationID: plan.operationID, journal: journal)
      == .unchanged)
    #expect(try await selection.recheckActiveIssue(
      issueID: "selected", current: changed, account: account, confirmedOperationID: plan.operationID, journal: journal)
      == .pauseAtSafePoint(.revisionChanged))
    let observed = QueueTestJournal(phase: .observedTarget(revision: "mutation"), plan: plan)
    #expect(try await selection.recheckActiveIssue(
      issueID: "selected", current: started, account: account,
      confirmedOperationID: plan.operationID, journal: observed) == .pauseAtSafePoint(.stateChanged))
  }
}
