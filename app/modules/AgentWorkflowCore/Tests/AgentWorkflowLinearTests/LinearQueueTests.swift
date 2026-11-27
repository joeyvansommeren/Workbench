import AgentWorkflowCore
import Foundation
import Testing

@testable import AgentWorkflowLinear

@Suite("Linear orchestrator queue requests", .serialized)
struct LinearQueueRequestTests {
  @Test("Project pages cover multiple teams and resolve an external prerequisite")
  func paginatedProject() async throws {
    let first = issue("first", team: "alpha", stateID: "alpha-entry", sortOrder: 9,
      relations: page([relation("link-1", source: "external-1", target: "first", state: "completed")], next: "r2"))
    let second = issue("second", team: "beta", stateID: "beta-entry", sortOrder: 1)
    QueueHTTPStub.set([
      .ok(accountResponse),
      .ok(projectPage("teams", [team("alpha")], next: "t2")),
      .ok(projectPage("teams", [team("beta")])),
      .ok(statePage(team: "alpha", states: [state("alpha-entry", name: "New label")], next: "s2")),
      .ok(statePage(team: "alpha", states: [state("alpha-active", type: "started")])),
      .ok(statePage(team: "beta", states: [state("beta-entry", type: "backlog")])),
      .ok(projectPage("issues", [first], next: "i2")),
      .ok(projectPage("issues", [second])),
      .ok(dependencyPage("first", [relation("link-2", source: "external-2", target: "first", state: "completed")]))
    ])
    let project = try await client().queueProject(id: "project", account: account, expectedTeamIDs: ["alpha", "beta"])
    #expect(project.coverage == .expectedTeamsVerified)
    #expect(project.omissions.isEmpty)
    #expect(project.teams.map(\.id) == ["alpha", "beta"])
    #expect(project.workflowStates["alpha"]?.map(\.id) == ["alpha-entry", "alpha-active"])
    let policy = try policyFor(project)
    let candidates = try project.candidates(eligibility: policy)
    #expect(candidates.map { $0.issue.id } == ["second", "first"])
    #expect(candidates.allSatisfy { $0.exclusion == nil })
    let selection = try project.capture(selectedIssueIDs: ["first"], eligibility: policy)
    #expect(try selection.selectedIssues().first?.prerequisites.map(\.issueID) == ["external-1", "external-2"])
    let persisted = try JSONDecoder().decode(LinearQueueSelection.self, from: JSONEncoder().encode(selection))
    #expect(persisted == selection)
    #expect(persisted.teamIDs == ["alpha", "beta"])
    #expect(try persisted.suggestedAdditions(in: project, eligibility: policy).map { $0.issue.id } == ["second"])
    #expect(persisted.items.map { $0.source.issueID } == ["first"])
    let requests = QueueHTTPStub.requests
    #expect(requests[2].variables["after"] == "t2")
    #expect(requests[4].variables["after"] == "s2")
    #expect(requests[7].variables["after"] == "i2")
    #expect(requests[8].variables == ["issueID": "first", "after": "r2"])
    #expect(requests.allSatisfy { $0.authorization == "test-linear-key" })
  }

  @Test("Permission-limited pages and malformed cursors leave visible scope explicitly incomplete")
  func incompleteCoverage() async throws {
    QueueHTTPStub.set([
      .ok(accountResponse),
      .ok(projectPage("teams", [team("alpha")], next: "t2")),
      .ok(["data": NSNull(), "errors": [["message": "Team permission denied"]]]),
      .ok(statePage(team: "alpha", states: [state("entry")])),
      .ok(projectPage("issues", [issue("one", team: "alpha")], next: "repeat")),
      .ok(projectPage("issues", [issue("two", team: "alpha")], next: "repeat"))
    ])
    let project = try await client().queueProject(id: "project", account: account, expectedTeamIDs: ["alpha", "gone"])
    #expect(project.issues.map(\.id) == ["one", "two"])
    #expect(project.omissions.map(\.scope) == [.projectTeams, .projectIssues, .missingTeam(teamID: "gone")])
    let policy = try policyFor(project, states: ["alpha": ["entry"]])
    #expect(throws: LinearQueueError.incompleteProject) {
      try project.capture(selectedIssueIDs: ["one"], eligibility: policy)
    }
  }

  @Test("Unavailable dependency details do not block other candidates")
  func isolateUnreadableDependencies() async throws {
    let independent = issue("independent", team: "alpha", relations: nil)
    let unknown = issue("unknown", team: "alpha", relations: nil)
    QueueHTTPStub.set([
      .ok(accountResponse),
      .ok(projectPage("teams", [team("alpha")])),
      .ok(statePage(team: "alpha", states: [state("entry")])),
      .ok(["data": NSNull(), "errors": [["message": "Hidden dependency"]]]),
      .ok(projectPage("issues", [unknown, independent])),
      .ok(["data": NSNull(), "errors": [["message": "Hidden dependency"]]]),
      .ok(dependencyPage("independent", []))
    ])
    let project = try await client().queueProject(id: "project", account: account)
    let policy = try policyFor(project, states: ["alpha": ["entry"]])
    let candidates = try project.candidates(eligibility: policy)
    #expect(project.omissions.isEmpty)
    #expect(candidates.first(where: { $0.issue.id == "unknown" })?.exclusion == .unknownDependencies)
    #expect(try project.capture(
      selectedIssueIDs: ["independent"], eligibility: policy, approveAccountVisibleScope: true).items.count == 1)
    #expect(QueueHTTPStub.requests[4].query.contains("inverseRelations") == false)
  }

  @Test("Dependency cycles, closed states and invalid workflow mappings have explicit exclusions")
  func eligibilityReasons() async throws {
    let rows = [
      issue("cycle-a", team: "alpha", relations: page([
        relation("link-a", source: "cycle-b", target: "cycle-a", state: "unstarted")
      ])),
      issue("cycle-b", team: "alpha", relations: page([
        relation("link-b", source: "cycle-a", target: "cycle-b", state: "unstarted")
      ])),
      issue("blocked", team: "alpha", relations: page([
        relation("external", source: "external-issue", target: "blocked", state: "started")
      ])),
      issue("closed", team: "alpha", stateID: "canceled", stateType: "canceled"),
      issue("unmapped", team: "beta"),
      issue("other-owner", team: "alpha", owner: "other-user"),
      issue("claimed", team: "alpha"),
      issue("no-repo", team: "alpha"),
      issue("independent", team: "alpha")
    ]
    QueueHTTPStub.set([
      .ok(accountResponse),
      .ok(projectPage("teams", [team("alpha"), team("beta")])),
      .ok(statePage(team: "alpha", states: [state("entry")])),
      .ok(statePage(team: "beta", states: [state("renamed-entry")])),
      .ok(projectPage("issues", rows))
    ])
    let project = try await client().queueProject(id: "project", account: account)
    let basePolicy = try policyFor(project, states: ["alpha": ["entry"], "beta": ["obsolete"]])
    var repositories = basePolicy.repositories
    repositories.removeValue(forKey: try account.identity(for: "no-repo"))
    let policy = LinearQueueEligibility(
      stateIDsByTeam: basePolicy.stateIDsByTeam,
      activeClaims: [try account.identity(for: "claimed")], repositories: repositories)
    let candidates = try project.candidates(eligibility: policy)
    func exclusion(_ id: String) -> LinearQueueExclusion? {
      candidates.first(where: { $0.issue.id == id })?.exclusion
    }
    #expect(exclusion("cycle-a") == .dependencyCycle)
    #expect(exclusion("cycle-b") == .dependencyCycle)
    #expect(exclusion("blocked") == .blockedBy(["external-issue"]))
    #expect(exclusion("closed") == .closed)
    #expect(exclusion("unmapped") == .missingWorkflowMapping)
    #expect(exclusion("other-owner") == .assignedToAnotherUser)
    #expect(exclusion("claimed") == .claimed)
    #expect(exclusion("no-repo") == .missingRepository)
    #expect(exclusion("independent") == nil)
  }

  @Test("Fresh reads distinguish removed, moved and reassigned issues before dispatch")
  func reconcileFreshIssue() async throws {
    let row = issue("selected", team: "alpha")
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(projectPage("teams", [team("alpha")])),
      .ok(statePage(team: "alpha", states: [state("entry")])),
      .ok(projectPage("issues", [row])),
      .ok(accountResponse), .ok(["data": ["issues": page([])]]),
      .ok(accountResponse), .ok(singleIssue(issue("selected", team: "alpha", project: "another-project"))),
      .ok(dependencyPage("selected", [])),
      .ok(accountResponse), .ok(singleIssue(issue("selected", team: "alpha", owner: "another-owner"))),
      .ok(dependencyPage("selected", []))
    ])
    let api = client()
    let project = try await api.queueProject(id: "project", account: account)
    let policy = try policyFor(project, states: ["alpha": ["entry"]])
    let selection = try project.capture(
      selectedIssueIDs: ["selected"], eligibility: policy, approveAccountVisibleScope: true)
    let deleted = try await api.queueIssue(id: "selected", account: account)
    let moved = try await api.queueIssue(id: "selected", account: account)
    let reassigned = try await api.queueIssue(id: "selected", account: account)
    #expect(try selection.recheck(issueID: "selected", current: deleted, account: account, isActive: false)
      == .needsReconciliation(.removedOrUnavailable))
    #expect(try selection.recheck(issueID: "selected", current: moved, account: account, isActive: false)
      == .needsReconciliation(.moved))
    #expect(try selection.recheck(issueID: "selected", current: reassigned, account: account, isActive: true)
      == .pauseAtSafePoint(.ownerChanged))
    #expect(QueueHTTPStub.requests[5].variables["issueID"] == "selected")
  }

  @Test("Rate limiting, offline transport and wrong accounts are distinct outcomes")
  func sourceFailures() async {
    QueueHTTPStub.set([.ok(accountResponse), .http(429)])
    await #expect(throws: LinearAPIError.rateLimited) {
      try await client().queueProject(id: "project", account: account)
    }
    #expect(QueueHTTPStub.requests.count == 2)
    QueueHTTPStub.set([.http(401)])
    await #expect(throws: LinearAPIError.unauthorized) { try await client().queueAccount() }
    QueueHTTPStub.set([.offline])
    await #expect(throws: LinearAPIError.self) { try await client().queueAccount() }
    QueueHTTPStub.set([.ok(accountResponse)])
    await #expect(throws: LinearQueueError.accountChanged) {
      try await client().queueProject(
        id: "project", account: LinearQueueAccount(workspaceID: "different", userID: "viewer"))
    }
    #expect(QueueHTTPStub.requests.count == 1)
  }
}

extension LinearQueueRequestTests {
  @Test("An uncertain mutation is read back once, then reconciled without sending it twice")
  func uncertainMutation() async throws {
    let original = issue("selected", team: "alpha")
    let updated = issue("selected", team: "alpha", stateID: "active", stateType: "started", revision: "changed")
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(original)),
      .offline, .ok(singleIssue(original)),
      .ok(accountResponse), .ok(singleIssue(updated))
    ])
    let first = try await client().applyQueueTransition(plan, journal: journal)
    #expect(first == .uncertain)
    guard case .submitted = await journal.phase else {
      Issue.record("Ambiguous POST must stay submitted")
      return
    }
    let recovered = try await client().applyQueueTransition(plan, journal: journal)
    #expect(recovered == .observedTarget(stateID: "active", revision: "changed"))
    #expect(await journal.phase == .observedTarget(revision: "changed"))
    let writes = QueueHTTPStub.requests.filter { $0.query.hasPrefix("mutation") }
    #expect(writes.count == 1)
    #expect(writes.first?.variables == ["issueID": "selected", "stateID": "active"])
    #expect(writes.first?.query.contains("input: { stateId: $stateID }") == true)
  }

  @Test("A human edit during the last preflight prevents the mutation")
  func newerRemoteEdit() async throws {
    let original = issue("selected", team: "alpha")
    let changed = issue("selected", team: "alpha", revision: "new-edit")
    let plan = try makeTransition(original)
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse), .ok(targetStateResponse), .ok(singleIssue(changed))
    ])
    let result = try await client().applyQueueTransition(plan, journal: journal)
    #expect(result == .conflict(.revisionChanged))
    #expect(QueueHTTPStub.requests.allSatisfy { !$0.query.hasPrefix("mutation") })
    #expect(await journal.phase == .conflict(.revisionChanged))
  }

  @Test("This transition path cannot request Done")
  func completionRejected() async throws {
    let plan = try makeTransition(issue("selected", team: "alpha"))
    let journal = QueueTestJournal()
    QueueHTTPStub.set([
      .ok(accountResponse),
      .ok(["data": ["workflowStates": page([["id": "active", "team": ["id": "alpha"], "type": "completed"]])]])
    ])
    let result = try await client().applyQueueTransition(plan, journal: journal)
    #expect(result == .conflict(.unavailableTarget))
    #expect(QueueHTTPStub.requests.count == 2)
    #expect(QueueHTTPStub.requests.allSatisfy { !$0.query.hasPrefix("mutation") })
  }
}

actor QueueTestJournal: LinearQueueTransitionJournaling {
  private(set) var phase: LinearQueueTransitionPhase
  private var plan: LinearQueueTransitionPlan?
  private let submissionBarrier: (@Sendable () async -> Void)?

  init(
    phase: LinearQueueTransitionPhase = .prepared, plan: LinearQueueTransitionPlan? = nil,
    submissionBarrier: (@Sendable () async -> Void)? = nil
  ) {
    self.phase = phase
    self.plan = plan
    self.submissionBarrier = submissionBarrier
  }

  func pendingLinearQueueTransitionIDs(account: LinearQueueAccount) -> [UUID] { [] }

  func linearQueueTransitionRecord(operationID: UUID, account: LinearQueueAccount) -> LinearQueueTransitionRecord? {
    guard let plan, plan.operationID == operationID, plan.account == account else { return nil }
    return LinearQueueTransitionRecord(plan: plan, phase: phase)
  }

  func prepareLinearQueueTransition(_ plan: LinearQueueTransitionPlan) -> LinearQueueTransitionPhase {
    self.plan = plan
    return phase
  }

  func beginLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase, at now: Date
  ) async -> LinearQueueTransitionAttempt? {
    guard phase == expected, let attempt = expected.nextAttempt(at: now) else { return nil }
    phase = .submitted(attempt)
    await submissionBarrier?()
    return attempt
  }

  func rollBackUnsentLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, attempt: LinearQueueTransitionAttempt, to priorPhase: LinearQueueTransitionPhase
  ) {
    guard phase == .submitted(attempt) else { return }
    phase = priorPhase
  }

  func resolveLinearQueueTransition(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase,
    phase: LinearQueueTransitionPhase
  ) -> LinearQueueTransitionPhase {
    guard self.phase == expected else { return self.phase }
    self.phase = phase
    return phase
  }
}
