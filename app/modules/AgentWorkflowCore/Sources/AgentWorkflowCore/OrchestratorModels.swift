import Foundation

/// Opaque tracker identity. Adapters must verify these values against the signed-in source.
/// `scopeID` identifies the site or workspace, never a project filter. Values are not normalized.
public struct OrchestratorSourceIdentity: Codable, Hashable, Sendable {
  public let trackerID: String
  public let accountID: String
  public let scopeID: String

  public init(trackerID: String, accountID: String, scopeID: String) throws {
    try requireOrchestratorIdentifier(trackerID, field: "trackerID")
    try requireOrchestratorIdentifier(accountID, field: "accountID")
    try requireOrchestratorIdentifier(scopeID, field: "scopeID")
    self.trackerID = trackerID
    self.accountID = accountID
    self.scopeID = scopeID
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      trackerID: values.decode(String.self, forKey: .trackerID),
      accountID: values.decode(String.self, forKey: .accountID),
      scopeID: values.decode(String.self, forKey: .scopeID))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.trackerID.utf8.elementsEqual(rhs.trackerID.utf8)
      && lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8)
      && lhs.scopeID.utf8.elementsEqual(rhs.scopeID.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    // Swift String equality folds Unicode canonical equivalents. Opaque IDs must not merge.
    hasher.combine(Data(trackerID.utf8))
    hasher.combine(Data(accountID.utf8))
    hasher.combine(Data(scopeID.utf8))
  }
}

/// Display keys and titles are not claim identity.
public struct OrchestratorIssueIdentity: Codable, Hashable, Sendable {
  public let source: OrchestratorSourceIdentity
  public let issueID: String

  public init(source: OrchestratorSourceIdentity, issueID: String) throws {
    try requireOrchestratorIdentifier(issueID, field: "issueID")
    self.source = source
    self.issueID = issueID
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      source: values.decode(OrchestratorSourceIdentity.self, forKey: .source),
      issueID: values.decode(String.self, forKey: .issueID))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source && lhs.issueID.utf8.elementsEqual(rhs.issueID.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(source)
    hasher.combine(Data(issueID.utf8))
  }
}

/// Limits on new dispatch, not a monetary cap or enforcement of provider/process capabilities.
public struct OrchestratorRunPolicy: Codable, Equatable, Sendable {
  public let maximumTickets: Int
  public let maximumConcurrentImplementations: Int
  public let wallClockLimit: TimeInterval
  public let maximumRetries: Int

  public init(
    maximumTickets: Int,
    maximumConcurrentImplementations: Int = 1,
    wallClockLimit: TimeInterval,
    maximumRetries: Int = 0
  ) throws {
    guard maximumTickets > 0 else { throw OrchestratorContractError.invalidTicketLimit }
    guard maximumConcurrentImplementations > 0,
      maximumConcurrentImplementations <= maximumTickets
    else { throw OrchestratorContractError.invalidConcurrencyLimit }
    guard wallClockLimit.isFinite, wallClockLimit > 0 else {
      throw OrchestratorContractError.invalidTimeLimit
    }
    guard maximumRetries >= 0 else { throw OrchestratorContractError.invalidRetryLimit }
    self.maximumTickets = maximumTickets
    self.maximumConcurrentImplementations = maximumConcurrentImplementations
    self.wallClockLimit = wallClockLimit
    self.maximumRetries = maximumRetries
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maximumTickets: values.decode(Int.self, forKey: .maximumTickets),
      maximumConcurrentImplementations: values.decode(
        Int.self, forKey: .maximumConcurrentImplementations),
      wallClockLimit: values.decode(TimeInterval.self, forKey: .wallClockLimit),
      maximumRetries: values.decode(Int.self, forKey: .maximumRetries))
  }
}

/// A verified mapping for this item. An unresolved mapping can be left absent until setup.
public struct OrchestratorRepositoryBinding: Codable, Equatable, Sendable {
  public let repositoryPath: String
  public let baseBranch: String

  public init(repositoryPath: String, baseBranch: String) throws {
    try requireOrchestratorIdentifier(repositoryPath, field: "repositoryPath")
    try requireOrchestratorIdentifier(baseBranch, field: "baseBranch")
    self.repositoryPath = repositoryPath
    self.baseBranch = baseBranch
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.repositoryPath.utf8.elementsEqual(rhs.repositoryPath.utf8)
      && lhs.baseBranch.utf8.elementsEqual(rhs.baseBranch.utf8)
  }
}

public struct OrchestratorSelectedIssue: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let issue: OrchestratorIssueIdentity

  public let prerequisites: [OrchestratorIssueIdentity]
  public let repository: OrchestratorRepositoryBinding?

  public init(
    id: UUID, issue: OrchestratorIssueIdentity,
    prerequisites: [OrchestratorIssueIdentity] = [],
    repository: OrchestratorRepositoryBinding? = nil
  ) {
    self.id = id
    self.issue = issue
    self.prerequisites = prerequisites
    self.repository = repository
  }
}

public struct OrchestratorRunProviders: Codable, Equatable, Sendable {
  public let orchestrator: AgentProviderID
  public let coordinator: AgentProviderID
  public let implementer: AgentProviderID
  public let reviewer: AgentProviderID

  public init(
    orchestrator: AgentProviderID, coordinator: AgentProviderID,
    implementer: AgentProviderID, reviewer: AgentProviderID
  ) throws {
    for provider in [orchestrator, coordinator, implementer, reviewer] {
      try requireOrchestratorIdentifier(provider.rawValue, field: "provider")
    }
    self.orchestrator = orchestrator
    self.coordinator = coordinator
    self.implementer = implementer
    self.reviewer = reviewer
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      orchestrator: values.decode(AgentProviderID.self, forKey: .orchestrator),
      coordinator: values.decode(AgentProviderID.self, forKey: .coordinator),
      implementer: values.decode(AgentProviderID.self, forKey: .implementer),
      reviewer: values.decode(AgentProviderID.self, forKey: .reviewer))
  }

  public func provider(for role: OrchestratorThreadRole) -> AgentProviderID {
    switch role {
    case .orchestrator: orchestrator
    case .ticketCoordinator: coordinator
    case .implementer: implementer
    case .reviewer: reviewer
    }
  }

  public func matches(_ request: WorkflowAllocationRequest) -> Bool {
    coordinator.rawValue.utf8.elementsEqual(request.coordinatorProvider.rawValue.utf8)
      && implementer.rawValue.utf8.elementsEqual(request.implementerProvider.rawValue.utf8)
      && reviewer.rawValue.utf8.elementsEqual(request.reviewerProvider.rawValue.utf8)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    [OrchestratorThreadRole.orchestrator, .ticketCoordinator, .implementer, .reviewer]
      .allSatisfy { lhs.provider(for: $0).rawValue.utf8.elementsEqual(rhs.provider(for: $0).rawValue.utf8) }
  }
}

public enum OrchestratorRunAttention: String, Codable, Sendable {
  case sourceUnavailable
  case sourceAuthenticationRequired
  case reconciliationRequired
}

/// The approved queue is distinct from the tracker account used to claim an issue.
public enum OrchestratorQueueScope: Codable, Equatable, Sendable {
  case project(id: String)
  case sprint(boardID: String, sprintID: String)

  func validate() throws {
    switch self {
    case .project(let id):
      try requireOrchestratorIdentifier(id, field: "projectID")
    case .sprint(let boardID, let sprintID):
      try requireOrchestratorIdentifier(boardID, field: "boardID")
      try requireOrchestratorIdentifier(sprintID, field: "sprintID")
    }
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.project(let first), .project(let second)):
      first.utf8.elementsEqual(second.utf8)
    case (.sprint(let firstBoard, let firstSprint), .sprint(let secondBoard, let secondSprint)):
      firstBoard.utf8.elementsEqual(secondBoard.utf8)
        && firstSprint.utf8.elementsEqual(secondSprint.utf8)
    default:
      false
    }
  }
}

/// This slice models control and dispatch only. It cannot mark accepted work or a tracker Done.
/// Attention is an independent projection; it must not replace a run's activity state.
public enum OrchestratorRunState: String, Codable, CaseIterable, Sendable {
  case draft, running, pausing, paused, stopping, stopped, completed
}

public enum OrchestratorDispatchDecision: Equatable, Sendable {
  case allowed
  case runNotRunning
  case invalidActivityCount
  case clockUnavailable
  case timeBudgetExhausted
  case concurrencyLimitReached
  case dependenciesUnverified
  case providerChoiceRequired
  case queueScopeRequired
  case runNeedsAttention
}

public struct OrchestratorRun: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let policy: OrchestratorRunPolicy
  public let source: OrchestratorSourceIdentity
  /// Captured order. New remote issues and board filter changes cannot change this selection.
  public let selection: [OrchestratorSelectedIssue]
  public internal(set) var queueScope: OrchestratorQueueScope?
  /// Legacy saved runs must confirm their providers before dispatch can resume.
  public internal(set) var providers: OrchestratorRunProviders?
  public internal(set) var attention: OrchestratorRunAttention?
  public internal(set) var state: OrchestratorRunState = .draft
  public internal(set) var revision: UInt64 = 0
  public internal(set) var startedAt: Date?
  internal var lastEvent: OrchestratorRunEvent?

  public init(
    id: UUID, policy: OrchestratorRunPolicy, providers: OrchestratorRunProviders,
    queueScope: OrchestratorQueueScope,
    selection: [OrchestratorSelectedIssue]
  ) throws {
    try self.init(id: id, policy: policy, selection: selection)
    try queueScope.validate()
    self.providers = providers
    self.queueScope = queueScope
  }

  private init(
    id: UUID, policy: OrchestratorRunPolicy, selection: [OrchestratorSelectedIssue]
  ) throws {
    guard !selection.isEmpty, selection.count <= policy.maximumTickets else {
      throw OrchestratorContractError.invalidSelectionCount
    }
    guard Set(selection.map(\.id)).count == selection.count else {
      throw OrchestratorContractError.duplicateItem
    }
    guard Set(selection.map(\.issue)).count == selection.count else {
      throw OrchestratorContractError.duplicateIssue
    }
    guard let source = selection.first?.issue.source,
      selection.allSatisfy({ $0.issue.source == source })
    else { throw OrchestratorContractError.selectionSourceMismatch }
    guard selection.allSatisfy({ selected in
      Set(selected.prerequisites).count == selected.prerequisites.count
    }) else { throw OrchestratorContractError.invalidDependencies }
    self.id = id
    self.policy = policy
    self.source = source
    self.selection = selection
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(UUID.self, forKey: .id),
      policy: values.decode(OrchestratorRunPolicy.self, forKey: .policy),
      selection: values.decode([OrchestratorSelectedIssue].self, forKey: .selection))
    guard try values.decode(OrchestratorSourceIdentity.self, forKey: .source) == source else {
      throw OrchestratorContractError.selectionSourceMismatch
    }
    providers = try values.decodeIfPresent(OrchestratorRunProviders.self, forKey: .providers)
    queueScope = try values.decodeIfPresent(OrchestratorQueueScope.self, forKey: .queueScope)
    try queueScope?.validate()
    attention = try values.decodeIfPresent(OrchestratorRunAttention.self, forKey: .attention)
    state = try values.decode(OrchestratorRunState.self, forKey: .state)
    revision = try values.decode(UInt64.self, forKey: .revision)
    startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
    lastEvent = try values.decodeIfPresent(OrchestratorRunEvent.self, forKey: .lastEvent)
  }

  /// A cycle also blocks items that depend on that cycle. Unselected prerequisites
  /// are verified against the base commit and do not participate in this local graph.
  public var issuesBlockedByDependencyCycles: Set<OrchestratorIssueIdentity> {
    let selected = Set(selection.map(\.issue))
    var unmetCounts = [OrchestratorIssueIdentity: Int]()
    var dependents = [OrchestratorIssueIdentity: [OrchestratorIssueIdentity]]()
    var ready = [OrchestratorIssueIdentity]()
    for item in selection {
      let prerequisites = item.prerequisites.filter { selected.contains($0) }
      unmetCounts[item.issue] = prerequisites.count
      if prerequisites.isEmpty { ready.append(item.issue) }
      for prerequisite in prerequisites {
        dependents[prerequisite, default: []].append(item.issue)
      }
    }
    var waiting = selected
    while let issue = ready.popLast() {
      waiting.remove(issue)
      for dependent in dependents[issue, default: []] {
        unmetCounts[dependent, default: 0] -= 1
        if unmetCounts[dependent] == 0 { ready.append(dependent) }
      }
    }
    return waiting
  }

  /// The runtime must obtain activity counts atomically with its claim. This value does not lock.
  public func dispatchDecision(
    at date: Date, activeImplementations: Int
  ) -> OrchestratorDispatchDecision {
    guard state == .running else { return .runNotRunning }
    guard providers != nil else { return .providerChoiceRequired }
    guard queueScope != nil else { return .queueScopeRequired }
    guard attention == nil else { return .runNeedsAttention }
    guard activeImplementations >= 0 else { return .invalidActivityCount }
    guard let startedAt, date.timeIntervalSinceReferenceDate.isFinite,
      date >= startedAt
    else { return .clockUnavailable }
    guard date.timeIntervalSince(startedAt) < policy.wallClockLimit else {
      return .timeBudgetExhausted
    }
    guard activeImplementations < policy.maximumConcurrentImplementations else {
      return .concurrencyLimitReached
    }
    return .allowed
  }
}

/// Attention is independent from control and active work.
public struct OrchestratorRunSummary: Equatable, Sendable {
  public let state: OrchestratorRunState
  public let activeCount: Int
  public let attentionCount: Int
  public let runAttention: OrchestratorRunAttention?
  public let providerChoiceRequired: Bool
  public let queueScopeRequired: Bool
  public var needsAttention: Bool {
    attentionCount > 0 || runAttention != nil || providerChoiceRequired || queueScopeRequired
  }

  public init(run: OrchestratorRun, items: [OrchestratorQueueItem]) {
    let ownedItems = items.filter { $0.runID == run.id }
    state = run.state
    activeCount = ownedItems.count(where: { $0.state.holdsDispatchSlot })
    attentionCount = ownedItems.count(where: { $0.state.needsAttention })
    runAttention = run.attention
    providerChoiceRequired = run.providers == nil && run.state != .stopped && run.state != .completed
    queueScopeRequired = run.queueScope == nil && run.state != .stopped && run.state != .completed
  }
}

/// Existing workflow IDs remain the authority for branch, test, review and approval facts.
public struct OrchestratorDispatchAttempt: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let operationID: UUID
  public let runID: UUID
  public let itemID: UUID
  public let predecessorID: UUID?
  public let pendingLaunchID: UUID
  public let provider: AgentProviderID
  public let ticketRunID: UUID
  public let branchRunID: UUID
  /// Absent only in attempts recorded before the base was tracked per launch.
  public let baseCommitID: String?

  public init(
    id: UUID, operationID: UUID, runID: UUID, itemID: UUID, predecessorID: UUID? = nil,
    pendingLaunchID: UUID, provider: AgentProviderID, ticketRunID: UUID, branchRunID: UUID,
    baseCommitID: String
  ) throws {
    try requireOrchestratorIdentifier(provider.rawValue, field: "provider")
    try requireOrchestratorIdentifier(baseCommitID, field: "baseCommitID")
    guard predecessorID != id else { throw OrchestratorContractError.invalidRetryLineage }
    self.id = id
    self.operationID = operationID
    self.runID = runID
    self.itemID = itemID
    self.predecessorID = predecessorID
    self.pendingLaunchID = pendingLaunchID
    self.provider = provider
    self.ticketRunID = ticketRunID
    self.branchRunID = branchRunID
    self.baseCommitID = baseCommitID
  }
}

/// A raw provider ID can round-trip without asserting that a launch adapter exists.
public struct OrchestratorSessionIdentity: Codable, Equatable, Sendable {
  public let provider: AgentProviderID
  public let sessionID: String

  public init(provider: AgentProviderID, sessionID: String) throws {
    try requireOrchestratorIdentifier(provider.rawValue, field: "provider")
    try requireOrchestratorIdentifier(sessionID, field: "sessionID")
    self.provider = provider
    self.sessionID = sessionID
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.provider.rawValue.utf8.elementsEqual(rhs.provider.rawValue.utf8)
      && lhs.sessionID.utf8.elementsEqual(rhs.sessionID.utf8)
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      provider: values.decode(AgentProviderID.self, forKey: .provider),
      sessionID: values.decode(String.self, forKey: .sessionID))
  }
}

/// A review handoff frees a dispatch slot and retains the claim until explicit resolution.
public enum OrchestratorQueueState: String, Codable, CaseIterable, Sendable {
  case queued, blocked, launching, reconciling, running, awaitingReview
  case failed, cancelling, cancelled, skipped, completed

  public var holdsDispatchSlot: Bool {
    switch self {
    case .launching, .reconciling, .running, .cancelling: true
    default: false
    }
  }

  public var needsAttention: Bool {
    switch self {
    case .blocked, .reconciling, .awaitingReview, .failed: true
    default: false
    }
  }

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .skipped: true
    default: false
    }
  }
}

/// A caller verifies these prerequisites on the named base commit before allowing dispatch.
public struct OrchestratorDependencyVerification: Codable, Equatable, Sendable {
  public let baseCommitID: String
  public let integratedIssues: [OrchestratorIssueIdentity]

  public init(baseCommitID: String, integratedIssues: [OrchestratorIssueIdentity]) throws {
    try requireOrchestratorIdentifier(baseCommitID, field: "baseCommitID")
    self.baseCommitID = baseCommitID
    self.integratedIssues = integratedIssues
  }
}

public struct OrchestratorQueueItem: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let issue: OrchestratorIssueIdentity
  public internal(set) var state: OrchestratorQueueState = .queued
  public internal(set) var revision: UInt64 = 0
  public internal(set) var attempts: [OrchestratorDispatchAttempt] = []
  public var attempt: OrchestratorDispatchAttempt? { attempts.last }
  public internal(set) var retryCount = 0
  public internal(set) var session: OrchestratorSessionIdentity?
  public internal(set) var blockedReason: String?
  public internal(set) var dependencyVerification: OrchestratorDependencyVerification?
  public internal(set) var completionEvidenceID: UUID?
  internal var lastEvent: OrchestratorItemEvent?

  public init(run: OrchestratorRun, itemID: UUID) throws {
    guard let selected = run.selection.first(where: { $0.id == itemID }) else {
      throw OrchestratorContractError.itemNotSelected
    }
    id = selected.id
    runID = run.id
    issue = selected.issue
  }
}

public enum OrchestratorContractError: Error, Equatable, Sendable {
  case emptyIdentifier(String)
  case invalidTicketLimit
  case invalidConcurrencyLimit
  case invalidTimeLimit
  case invalidRetryLimit
  case invalidSelectionCount
  case duplicateItem
  case duplicateIssue
  case selectionSourceMismatch
  case itemNotSelected
  case invalidRetryLineage
  case invalidDependencies
}

internal func requireOrchestratorIdentifier(_ value: String, field: String) throws {
  guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw OrchestratorContractError.emptyIdentifier(field)
  }
}
