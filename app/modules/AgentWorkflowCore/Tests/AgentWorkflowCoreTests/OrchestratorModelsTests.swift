import Foundation
import Testing

@testable import AgentWorkflowCore

@Suite("Orchestrator contracts")
struct OrchestratorModelsTests {
  @Test("Canonically equivalent Unicode tokens remain distinct opaque identities")
  func unicodeIdentity() throws {
    let composed = "caf\u{00e9}"
    let decomposed = "cafe\u{0301}"
    #expect(composed == decomposed)
    let first = try makeIssue(account: composed)
    let second = try makeIssue(account: decomposed)
    #expect(first != second)
    #expect(Set([first.source, second.source]).count == 2)
    let firstIssue = try makeIssue(id: composed)
    let secondIssue = try makeIssue(id: decomposed)
    #expect(Set([firstIssue, secondIssue]).count == 2)
    let restored = try JSONDecoder().decode(
      OrchestratorIssueIdentity.self, from: JSONEncoder().encode(secondIssue))
    #expect(Array(restored.issueID.utf8) == Array(decomposed.utf8))
  }

  @Test("Source identity preserves opaque values without merging accounts or workspaces")
  func sourceIdentity() throws {
    let identity = try OrchestratorSourceIdentity(
      trackerID: "FutureTracker", accountID: " Account-A ", scopeID: "Workspace-A")
    let issue = try OrchestratorIssueIdentity(source: identity, issueID: "opaque-1")
    let restored = try JSONDecoder().decode(
      OrchestratorIssueIdentity.self, from: JSONEncoder().encode(issue))
    #expect(restored == issue)
    #expect(restored.source.accountID == " Account-A ")
    let otherAccount = try OrchestratorIssueIdentity(
      source: OrchestratorSourceIdentity(
        trackerID: "FutureTracker", accountID: "Account-A", scopeID: "Workspace-A"),
      issueID: "opaque-1")
    let otherScope = try OrchestratorIssueIdentity(
      source: OrchestratorSourceIdentity(
        trackerID: "FutureTracker", accountID: " Account-A ", scopeID: "Workspace-B"),
      issueID: "opaque-1")
    #expect(issue != otherAccount)
    #expect(issue != otherScope)
  }

  @Test("Empty identifiers are rejected during creation and decoding")
  func emptyIdentity() throws {
    #expect(throws: OrchestratorContractError.emptyIdentifier("accountID")) {
      try OrchestratorSourceIdentity(trackerID: "linear", accountID: " \n", scopeID: "workspace")
    }
    let invalid = Data(#"{"trackerID":"linear","accountID":"","scopeID":"workspace"}"#.utf8)
    #expect(throws: OrchestratorContractError.emptyIdentifier("accountID")) {
      try JSONDecoder().decode(OrchestratorSourceIdentity.self, from: invalid)
    }
    #expect(throws: OrchestratorContractError.emptyIdentifier("issueID")) {
      try OrchestratorIssueIdentity(source: makeIssue().source, issueID: "")
    }
  }

  @Test("Unknown provider identity round-trips without a launch-support assertion")
  func unknownProvider() throws {
    let unknown = AgentProviderID(rawValue: "future-provider-v7")
    let session = try OrchestratorSessionIdentity(provider: unknown, sessionID: "same-id")
    let restored = try JSONDecoder().decode(
      OrchestratorSessionIdentity.self, from: JSONEncoder().encode(session))
    #expect(restored == session)
    #expect(restored.provider.rawValue == "future-provider-v7")
    let otherProvider = try OrchestratorSessionIdentity(provider: .codex, sessionID: "same-id")
    #expect(session != otherProvider)
  }

  @Test("Policy requires finite positive limits and defaults to one implementation and no retry")
  func policyValidation() throws {
    let policy = try OrchestratorRunPolicy(maximumTickets: 3, wallClockLimit: 600)
    #expect(policy.maximumConcurrentImplementations == 1)
    #expect(policy.maximumRetries == 0)
    #expect(throws: OrchestratorContractError.invalidTicketLimit) {
      try OrchestratorRunPolicy(maximumTickets: 0, wallClockLimit: 600)
    }
    for count in [0, -1, 4] {
      #expect(throws: OrchestratorContractError.invalidConcurrencyLimit) {
        try OrchestratorRunPolicy(
          maximumTickets: 3, maximumConcurrentImplementations: count, wallClockLimit: 600)
      }
    }
    for limit in [0.0, -1.0, .infinity, .nan] {
      #expect(throws: OrchestratorContractError.invalidTimeLimit) {
        try OrchestratorRunPolicy(maximumTickets: 3, wallClockLimit: limit)
      }
    }
    #expect(throws: OrchestratorContractError.invalidRetryLimit) {
      try OrchestratorRunPolicy(maximumTickets: 3, wallClockLimit: 600, maximumRetries: -1)
    }
    let invalid = Data(
      #"{"maximumTickets":3,"maximumConcurrentImplementations":0,"wallClockLimit":600,"maximumRetries":0}"#
        .utf8)
    #expect(throws: OrchestratorContractError.invalidConcurrencyLimit) {
      try JSONDecoder().decode(OrchestratorRunPolicy.self, from: invalid)
    }
  }

  @Test(
    "Selection retains explicit order and rejects duplicate, empty, oversized or foreign-source items"
  )
  func selectionValidation() throws {
    let policy = try OrchestratorRunPolicy(maximumTickets: 2, wallClockLimit: 600)
    let first = OrchestratorSelectedIssue(id: orchestrationID(1), issue: try makeIssue(id: "first"))
    let second = OrchestratorSelectedIssue(
      id: orchestrationID(2), issue: try makeIssue(id: "second"))
    let run = try OrchestratorRun(
      id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [second, first])
    #expect(run.selection.map(\.id) == [second.id, first.id])
    #expect(throws: OrchestratorContractError.invalidSelectionCount) {
      try OrchestratorRun(id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [])
    }
    #expect(throws: OrchestratorContractError.invalidSelectionCount) {
      try OrchestratorRun(
        id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [first, second, first])
    }
    #expect(throws: OrchestratorContractError.duplicateItem) {
      try OrchestratorRun(id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [first, first])
    }
    #expect(throws: OrchestratorContractError.duplicateIssue) {
      try OrchestratorRun(
        id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"),
        selection: [first, OrchestratorSelectedIssue(id: second.id, issue: first.issue)])
    }
    #expect(throws: OrchestratorContractError.selectionSourceMismatch) {
      try OrchestratorRun(
        id: orchestrationID(3), policy: policy, providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"),
        selection: [
          first, OrchestratorSelectedIssue(id: second.id, issue: makeIssue(account: "other")),
        ])
    }
    #expect(throws: OrchestratorContractError.itemNotSelected) {
      try OrchestratorQueueItem(run: run, itemID: orchestrationID(99))
    }
  }

  @Test("Dependency cycles do not block another selected issue with no pending prerequisites")
  func dependencyCycles() throws {
    let first = try makeIssue(id: "first")
    let second = try makeIssue(id: "second")
    let downstream = try makeIssue(id: "downstream")
    let independent = try makeIssue(id: "independent")
    let selfDependent = try makeIssue(id: "self-dependent")
    let run = try OrchestratorRun(
      id: orchestrationID(1), policy: OrchestratorRunPolicy(maximumTickets: 5, wallClockLimit: 60),
      providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"), selection: [
        OrchestratorSelectedIssue(id: orchestrationID(2), issue: first, prerequisites: [second]),
        OrchestratorSelectedIssue(id: orchestrationID(3), issue: second, prerequisites: [first]),
        OrchestratorSelectedIssue(id: orchestrationID(4), issue: downstream, prerequisites: [second]),
        OrchestratorSelectedIssue(id: orchestrationID(5), issue: independent),
        OrchestratorSelectedIssue(id: orchestrationID(6), issue: selfDependent, prerequisites: [selfDependent]),
      ])
    #expect(run.issuesBlockedByDependencyCycles == [first, second, downstream, selfDependent])
  }

  @Test("Reading a saved run enforces its selection limits and source")
  func decodedSelectionValidation() throws {
    let run = try makeOrchestratorRun()
    let encoded = try JSONEncoder().encode(run)
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload["selection"] = []
    #expect(throws: OrchestratorContractError.invalidSelectionCount) {
      try JSONDecoder().decode(
        OrchestratorRun.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    let selection = [
      run.selection[0],
      OrchestratorSelectedIssue(id: orchestrationID(500), issue: try makeIssue(account: "other")),
    ]
    payload["selection"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection))
    #expect(throws: OrchestratorContractError.selectionSourceMismatch) {
      try JSONDecoder().decode(
        OrchestratorRun.self, from: JSONSerialization.data(withJSONObject: payload))
    }
  }

  @Test("Dispatch decisions use a supplied clock and count without claiming to reserve a slot")
  func boundedDispatch() throws {
    var run = try makeOrchestratorRun()
    #expect(
      run.dispatchDecision(at: orchestrationStart, activeImplementations: 0) == .runNotRunning)
    try applyRun(.start(at: orchestrationStart), to: &run)
    #expect(run.dispatchDecision(at: orchestrationStart, activeImplementations: 0) == .allowed)
    #expect(
      run.dispatchDecision(at: orchestrationStart, activeImplementations: -1)
        == .invalidActivityCount)
    #expect(
      run.dispatchDecision(at: orchestrationStart, activeImplementations: 1)
        == .concurrencyLimitReached)
    #expect(
      run.dispatchDecision(at: orchestrationStart.addingTimeInterval(-1), activeImplementations: 0)
        == .clockUnavailable)
    #expect(
      run.dispatchDecision(at: orchestrationStart.addingTimeInterval(599), activeImplementations: 0)
        == .allowed)
    #expect(
      run.dispatchDecision(at: orchestrationStart.addingTimeInterval(600), activeImplementations: 0)
        == .timeBudgetExhausted)
  }
}

let orchestrationStart = Date(timeIntervalSince1970: 1_000)

func orchestrationID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

func makeIssue(
  account: String = "account", scope: String = "workspace", id: String = "opaque-1"
) throws -> OrchestratorIssueIdentity {
  try OrchestratorIssueIdentity(
    source: OrchestratorSourceIdentity(trackerID: "linear", accountID: account, scopeID: scope),
    issueID: id)
}

func makeOrchestratorRun(retries: Int = 1) throws -> OrchestratorRun {
  try OrchestratorRun(
    id: orchestrationID(100),
    policy: OrchestratorRunPolicy(maximumTickets: 3, wallClockLimit: 600, maximumRetries: retries),
    providers: makeOrchestratorProviders(), queueScope: .project(id: "test-project"),
    selection: [OrchestratorSelectedIssue(id: orchestrationID(101), issue: makeIssue())])
}

@discardableResult
func applyRun(_ command: OrchestratorRunCommand, to run: inout OrchestratorRun) throws
  -> OrchestratorTransitionResult
{
  var items: [OrchestratorQueueItem] = []
  if command == .confirmStopped {
    items = try run.selection.map {
      var item = try OrchestratorQueueItem(run: run, itemID: $0.id)
      item.state = .cancelled
      return item
    }
  }
  return try OrchestratorStateMachine.apply(
    OrchestratorRunEvent(
      id: orchestrationID(1_000 + Int(run.revision)), runID: run.id,
      expectedRevision: run.revision, command: command), to: &run, items: items)
}

func makeOrchestratorProviders(_ provider: AgentProviderID = .codex) throws -> OrchestratorRunProviders {
  try OrchestratorRunProviders(
    orchestrator: provider, coordinator: provider, implementer: provider, reviewer: provider)
}
