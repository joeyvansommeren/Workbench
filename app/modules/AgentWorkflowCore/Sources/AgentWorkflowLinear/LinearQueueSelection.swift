import AgentWorkflowCore
import Foundation

public struct LinearQueueEligibility: Sendable {
  /// These must be explicitly chosen workflow state IDs per team.
  public let stateIDsByTeam: [String: Set<String>]
  public let permittedOtherOwnerIssues: Set<OrchestratorIssueIdentity>
  public let activeClaims: Set<OrchestratorIssueIdentity>
  public let repositories: [OrchestratorIssueIdentity: OrchestratorRepositoryBinding]

  public init(
    stateIDsByTeam: [String: Set<String>],
    permittedOtherOwnerIssues: Set<OrchestratorIssueIdentity> = [],
    activeClaims: Set<OrchestratorIssueIdentity> = [],
    repositories: [OrchestratorIssueIdentity: OrchestratorRepositoryBinding]
  ) {
    self.stateIDsByTeam = stateIDsByTeam
    self.permittedOtherOwnerIssues = permittedOtherOwnerIssues
    self.activeClaims = activeClaims
    self.repositories = repositories
  }
}

public enum LinearQueueExclusion: Equatable, Sendable {
  case closed
  case missingWorkflowMapping
  case outsideSelectedWorkflow
  case claimed
  case assignedToAnotherUser
  case missingRepository
  case dependencyCycle
  case unknownDependencies
  case blockedBy([String])
}

public struct LinearQueueCandidate: Equatable, Sendable {
  public let issue: LinearQueueIssue
  public let repository: OrchestratorRepositoryBinding?
  public let exclusion: LinearQueueExclusion?
}

public struct LinearQueueSelection: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Sendable {
    public let id: UUID
    public let source: OrchestratorIssueIdentity
    public let teamID: String
    public let stateID: String
    public let assigneeID: String?
    public let revision: String
    public let prerequisiteIDs: [String]
    public let repository: OrchestratorRepositoryBinding
  }

  public let account: LinearQueueAccount
  public let projectID: String
  public let teamIDs: Set<String>
  public let coverage: LinearQueueCoverage
  public let items: [Item]

  public enum Change: Equatable, Sendable {
    case sourceUnavailable
    case removedOrUnavailable
    case moved
    case closed
    case ownerChanged
    case stateChanged
    case dependencyChanged
    case revisionChanged
  }

  public enum Reconciliation: Equatable, Sendable {
    case unchanged
    case needsReconciliation(Change)
    case pauseAtSafePoint(Change)
  }

  public func selectedIssues() throws -> [OrchestratorSelectedIssue] {
    try items.map { item in
      OrchestratorSelectedIssue(
        id: item.id, issue: item.source,
        prerequisites: try item.prerequisiteIDs.map(account.identity(for:)), repository: item.repository)
    }
  }

  public func recheck(
    issueID: String, current: LinearQueueIssue?, account currentAccount: LinearQueueAccount,
    isActive: Bool
  ) throws -> Reconciliation {
    guard let item = items.first(where: { $0.source.issueID == issueID }) else {
      throw LinearQueueError.invalidSelection
    }
    guard let change = change(for: item, current: current, account: currentAccount) else {
      return .unchanged
    }
    return isActive ? .pauseAtSafePoint(change) : .needsReconciliation(change)
  }

  /// Active work can adopt a status observed and stored by the transition journal.
  /// Its exact revision remains the baseline, so later human edits still conflict.
  public func recheckActiveIssue(
    issueID: String, current: LinearQueueIssue?, account currentAccount: LinearQueueAccount,
    confirmedOperationID: UUID, journal: any LinearQueueTransitionJournaling
  ) async throws -> Reconciliation {
    guard account == currentAccount else { return .pauseAtSafePoint(.sourceUnavailable) }
    guard let item = items.first(where: { $0.source.issueID == issueID }) else {
      throw LinearQueueError.invalidSelection
    }
    let record = try await journal.linearQueueTransitionRecord(
      operationID: confirmedOperationID, account: account)
    let progress: (stateID: String, revision: String)?
    if let record, case .confirmed(let revision) = record.phase,
      record.plan.matches(item: item, in: self) {
      progress = (record.plan.targetStateID, revision)
    } else {
      progress = nil
    }
    guard let change = change(for: item, current: current, account: currentAccount, progress: progress) else {
      return .unchanged
    }
    return .pauseAtSafePoint(change)
  }

  private func change(
    for item: Item, current: LinearQueueIssue?, account currentAccount: LinearQueueAccount,
    progress: (stateID: String, revision: String)? = nil
  ) -> Change? {
    guard account == currentAccount else { return .sourceUnavailable }
    guard let current, current.id == item.source.issueID else { return .removedOrUnavailable }
    guard current.projectID == projectID, current.teamID == item.teamID else { return .moved }
    guard !current.isClosed else { return .closed }
    guard current.assigneeID == item.assigneeID else { return .ownerChanged }
    guard current.state.id == (progress?.stateID ?? item.stateID) else { return .stateChanged }
    guard case .known(let dependencies) = current.dependencies,
      dependencies.allSatisfy({ $0.status == .completed }),
      Set(dependencies.map(\.issueID)) == Set(item.prerequisiteIDs)
    else { return .dependencyChanged }
    return current.revision == (progress?.revision ?? item.revision) ? nil : .revisionChanged
  }

  /// The caller can present new IDs as suggestions, but cannot add them by refreshing.
  public func suggestedAdditions(
    in project: LinearQueueProject, eligibility: LinearQueueEligibility
  ) throws -> [LinearQueueCandidate] {
    guard project.account == account, project.id == projectID else {
      throw LinearQueueError.accountChanged
    }
    guard project.omissions.isEmpty, Set(project.teams.map(\.id)) == teamIDs else {
      throw LinearQueueError.incompleteProject
    }
    let currentIDs = Set(items.map { $0.source.issueID })
    return try project.candidates(eligibility: eligibility)
      .filter { $0.exclusion == nil && !currentIDs.contains($0.issue.id) }
  }
}

extension LinearQueueProject {
  public func candidates(eligibility: LinearQueueEligibility) throws -> [LinearQueueCandidate] {
    let blockedByCycles = cycleAffectedIssues()
    return try issues.sorted(by: LinearQueueIssue.sourceOrder).map { issue in
      let identity = try account.identity(for: issue.id)
      let repository = eligibility.repositories[identity]
      let exclusion = exclusion(
        for: issue, identity: identity, eligibility: eligibility, blockedByCycles: blockedByCycles)
      return LinearQueueCandidate(issue: issue, repository: repository, exclusion: exclusion)
    }
  }

  public func capture(
    selectedIssueIDs: [String], eligibility: LinearQueueEligibility,
    approveAccountVisibleScope: Bool = false
  ) throws -> LinearQueueSelection {
    guard omissions.isEmpty else { throw LinearQueueError.incompleteProject }
    guard coverage == .expectedTeamsVerified || approveAccountVisibleScope else {
      throw LinearQueueError.visibleScopeApprovalRequired
    }
    guard !selectedIssueIDs.isEmpty, Set(selectedIssueIDs).count == selectedIssueIDs.count else {
      throw LinearQueueError.invalidSelection
    }
    let available = Dictionary(
      try candidates(eligibility: eligibility).map { ($0.issue.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let items = try selectedIssueIDs.map { id -> LinearQueueSelection.Item in
      guard let entry = available[id], entry.exclusion == nil, let repository = entry.repository,
        case .known(let dependencies) = entry.issue.dependencies
      else { throw LinearQueueError.invalidSelection }
      return LinearQueueSelection.Item(
        id: UUID(), source: try account.identity(for: id), teamID: entry.issue.teamID,
        stateID: entry.issue.state.id, assigneeID: entry.issue.assigneeID,
        revision: entry.issue.revision, prerequisiteIDs: dependencies.map(\.issueID),
        repository: repository)
    }
    return LinearQueueSelection(
      account: account, projectID: id, teamIDs: Set(teams.map(\.id)), coverage: coverage, items: items)
  }

  private func exclusion(
    for issue: LinearQueueIssue, identity: OrchestratorIssueIdentity,
    eligibility: LinearQueueEligibility, blockedByCycles: Set<String>
  ) -> LinearQueueExclusion? {
    if issue.isClosed { return .closed }
    guard let selectedStates = eligibility.stateIDsByTeam[issue.teamID], !selectedStates.isEmpty,
      let states = workflowStates[issue.teamID],
      selectedStates.isSubset(of: Set(states.filter(\.isQueueEntry).map(\.id)))
    else { return .missingWorkflowMapping }
    guard selectedStates.contains(issue.state.id), issue.state.isQueueEntry else {
      return .outsideSelectedWorkflow
    }
    if eligibility.activeClaims.contains(identity) { return .claimed }
    if let owner = issue.assigneeID, owner != account.userID,
      !eligibility.permittedOtherOwnerIssues.contains(identity) {
      return .assignedToAnotherUser
    }
    guard eligibility.repositories[identity] != nil else { return .missingRepository }
    if blockedByCycles.contains(issue.id) { return .dependencyCycle }
    guard case .known(let dependencies) = issue.dependencies,
      !dependencies.contains(where: { $0.status == .unknown })
    else { return .unknownDependencies }
    let blockers = dependencies.filter { $0.status != .completed }.map(\.issueID)
    return blockers.isEmpty ? nil : .blockedBy(blockers)
  }

  private func cycleAffectedIssues() -> Set<String> {
    let issueIDs = Set(issues.filter { !$0.isClosed }.map(\.id))
    var incoming: [String: Int] = [:]
    var downstream: [String: [String]] = [:]
    for issue in issues where issueIDs.contains(issue.id) {
      let activePrerequisites: Set<String>
      if case .known(let dependencies) = issue.dependencies {
        activePrerequisites = Set(dependencies.filter { $0.status == .active }.map(\.issueID))
          .intersection(issueIDs)
      } else {
        activePrerequisites = []
      }
      incoming[issue.id] = activePrerequisites.count
      for prerequisite in activePrerequisites { downstream[prerequisite, default: []].append(issue.id) }
    }
    var ready = incoming.compactMap { $0.value == 0 ? $0.key : nil }
    var remaining = issueIDs
    while let id = ready.popLast() {
      remaining.remove(id)
      for dependent in downstream[id, default: []] {
        incoming[dependent, default: 0] -= 1
        if incoming[dependent] == 0 { ready.append(dependent) }
      }
    }
    return remaining
  }
}

extension LinearQueueIssue {
  var isClosed: Bool { isArchived || state.type == "completed" || state.type == "canceled" }

  static func sourceOrder(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.sortOrder != rhs.sortOrder {
      return (lhs.sortOrder ?? .infinity) < (rhs.sortOrder ?? .infinity)
    }
    return lhs.id < rhs.id
  }
}

extension LinearWorkflowState {
  var isQueueEntry: Bool { type == "backlog" || type == "unstarted" }
}

private extension LinearQueueTransitionPlan {
  func matches(item: LinearQueueSelection.Item, in selection: LinearQueueSelection) -> Bool {
    account == selection.account && projectID == selection.projectID
      && issueID == item.source.issueID && teamID == item.teamID
      && expectedStateID == item.stateID && expectedAssigneeID == item.assigneeID
      && expectedRevision == item.revision
  }
}
