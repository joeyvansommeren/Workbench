import Foundation

/// A local intent to reflect the start of work. A caller supplies its persisted
/// operation ID after confirming that the worker has launched.
public struct LinearQueueTransitionPlan: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let account: LinearQueueAccount
  public let projectID: String
  public let issueID: String
  public let teamID: String
  public let expectedStateID: String
  public let expectedAssigneeID: String?
  public let expectedRevision: String
  public let targetStateID: String

  public init(
    operationID: UUID, account: LinearQueueAccount, projectID: String,
    issue: LinearQueueIssue, targetStateID: String
  ) throws {
    guard issue.projectID == projectID, !issue.isClosed, issue.state.isQueueEntry, !targetStateID.isEmpty,
      !issue.revision.isEmpty, issue.state.id != targetStateID
    else { throw LinearQueueError.invalidSelection }
    self.operationID = operationID
    self.account = account
    self.projectID = projectID
    issueID = issue.id
    teamID = issue.teamID
    expectedStateID = issue.state.id
    expectedAssigneeID = issue.assigneeID
    expectedRevision = issue.revision
    self.targetStateID = targetStateID
  }
}

public enum LinearQueueTransitionConflict: String, Codable, Equatable, Sendable {
  case outsideProject
  case ownerChanged
  case remoteStateChanged
  case revisionChanged
  case unavailableTarget
}

public enum LinearQueueTransitionRejection: String, Codable, Equatable, Error, Sendable {
  case declined
  case unauthorized
  case forbidden
  case rateLimited

  init?(httpStatus: Int) {
    switch httpStatus {
    case 401: self = .unauthorized
    case 403: self = .forbidden
    case 429: self = .rateLimited
    default: return nil
    }
  }
}

public struct LinearQueueTransitionAttempt: Codable, Equatable, Sendable {
  public enum Number: String, Codable, Equatable, Sendable {
    case initial
    case retry
  }

  /// Let an unresolved request settle before a user may choose to try again.
  /// Linear has no compare-and-swap or server-side deduplication guarantee.
  public static let retryDelay: TimeInterval = 120

  public let number: Number
  public let submittedAt: Date

  public init(number: Number, submittedAt: Date) {
    self.number = number
    self.submittedAt = submittedAt
  }

  public func canRetry(at now: Date) -> Bool {
    number == .initial && now.timeIntervalSince(submittedAt) >= Self.retryDelay
  }
}

public enum LinearQueueTransitionPhase: Codable, Equatable, Sendable {
  case prepared
  case submitted(LinearQueueTransitionAttempt)
  case confirmed(revision: String)
  case observedTarget(revision: String)
  case conflict(LinearQueueTransitionConflict)
  case rejected(LinearQueueTransitionRejection)

  public func nextAttempt(at now: Date) -> LinearQueueTransitionAttempt? {
    switch self {
    case .prepared:
      .init(number: .initial, submittedAt: now)
    case .submitted(let attempt) where attempt.canRetry(at: now):
      .init(number: .retry, submittedAt: now)
    default:
      nil
    }
  }
}

public enum LinearQueueTransitionOutcome: Equatable, Sendable {
  case confirmed(stateID: String, revision: String)
  case observedTarget(stateID: String, revision: String)
  case conflict(LinearQueueTransitionConflict)
  case rejected(LinearQueueTransitionRejection)
  case uncertain
}

public struct LinearQueueTransitionRecord: Codable, Equatable, Sendable {
  public let plan: LinearQueueTransitionPlan
  public let phase: LinearQueueTransitionPhase

  public init(plan: LinearQueueTransitionPlan, phase: LinearQueueTransitionPhase) {
    self.plan = plan
    self.phase = phase
  }
}

/// A second active operation for one issue conflicts. The journal changes each
/// phase only if it still matches the phase the caller read.
public protocol LinearQueueTransitionJournaling: Sendable {
  func pendingLinearQueueTransitionIDs(account: LinearQueueAccount) async throws -> [UUID]
  func linearQueueTransitionRecord(operationID: UUID, account: LinearQueueAccount) async throws
    -> LinearQueueTransitionRecord?
  func prepareLinearQueueTransition(_ plan: LinearQueueTransitionPlan) async throws
    -> LinearQueueTransitionPhase
  func beginLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase, at now: Date
  ) async throws -> LinearQueueTransitionAttempt?
  /// Use only when the caller knows it has not invoked the HTTP submission.
  func rollBackUnsentLinearQueueSubmission(
    _ plan: LinearQueueTransitionPlan, attempt: LinearQueueTransitionAttempt,
    to priorPhase: LinearQueueTransitionPhase
  ) async throws
  func resolveLinearQueueTransition(
    _ plan: LinearQueueTransitionPlan, from expected: LinearQueueTransitionPhase,
    phase: LinearQueueTransitionPhase
  ) async throws -> LinearQueueTransitionPhase
}

extension LinearQueueTransitionJournaling {
  public func linearQueueTransitionPlan(operationID: UUID, account: LinearQueueAccount) async throws
    -> LinearQueueTransitionPlan? {
    try await linearQueueTransitionRecord(operationID: operationID, account: account)?.plan
  }
}

public protocol LinearQueueTransitioning: Sendable {
  func applyQueueTransition(
    _ plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling
  ) async throws -> LinearQueueTransitionOutcome
  /// Call only for an explicit user retry. A prior submission may still have
  /// reached Linear. A retry needs a fresh matching read and is allowed once.
  func retryQueueTransition(
    _ plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling
  ) async throws -> LinearQueueTransitionOutcome
}

extension LinearAPIClient: LinearQueueTransitioning {
  public func applyQueueTransition(
    _ plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling
  ) async throws -> LinearQueueTransitionOutcome {
    try await transition(plan, journal: journal, explicitRetry: false)
  }

  public func retryQueueTransition(
    _ plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling
  ) async throws -> LinearQueueTransitionOutcome {
    try await transition(plan, journal: journal, explicitRetry: true)
  }

  private func transition(
    _ plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling,
    explicitRetry: Bool
  ) async throws -> LinearQueueTransitionOutcome {
    let authorization = try await queueAuthorization(for: plan.account)
    guard queueTransitionsInFlight.insert(plan.operationID).inserted else { return .uncertain }
    defer { queueTransitionsInFlight.remove(plan.operationID) }
    let phase = try await journal.prepareLinearQueueTransition(plan)
    switch phase {
    case .prepared where !explicitRetry:
      return try await submit(plan, from: phase, journal: journal, authorization: authorization)
    case .submitted(let attempt):
      let observed = try await observe(plan, phase: phase, journal: journal, authorization: authorization)
      guard observed == .uncertain, explicitRetry, attempt.canRetry(at: queueNow()) else { return observed }
      return try await submit(plan, from: phase, journal: journal, authorization: authorization)
    default:
      return outcome(for: plan, phase: phase)
    }
  }

  private func submit(
    _ plan: LinearQueueTransitionPlan, from priorPhase: LinearQueueTransitionPhase,
    journal: any LinearQueueTransitionJournaling, authorization: String
  ) async throws -> LinearQueueTransitionOutcome {
    if let conflict = try await preflight(plan, authorization: authorization) {
      // A failed retry preflight does not resolve the first uncertain request.
      guard priorPhase == .prepared else { return .conflict(conflict) }
      return try await record(.conflict(conflict), from: priorPhase, plan: plan, journal: journal)
    }
    guard let attempt = try await journal.beginLinearQueueSubmission(
      plan, from: priorPhase, at: queueNow()) else {
      return outcome(for: plan, phase: try await journal.prepareLinearQueueTransition(plan))
    }

    do {
      // The user may have changed credentials while SQLite recorded the attempt.
      try validateQueueAuthorization(authorization)
    } catch {
      // The journal still needs the rollback if this task was cancelled.
      try await Task {
        try await journal.rollBackUnsentLinearQueueSubmission(plan, attempt: attempt, to: priorPhase)
      }.value
      throw error
    }
    let phase = LinearQueueTransitionPhase.submitted(attempt)
    switch try await send(plan, authorization: authorization) {
    case .declined(let rejection):
      // A refused retry proves nothing about the previous ambiguous attempt.
      guard attempt.number == .initial else { return .uncertain }
      return try await record(.rejected(rejection), from: phase, plan: plan, journal: journal)
    case .confirmed(let revision):
      return try await record(.confirmed(revision: revision), from: phase, plan: plan, journal: journal)
    case .uncertain:
      return try await observe(plan, phase: phase, journal: journal, authorization: authorization)
    }
  }

  private func preflight(_ plan: LinearQueueTransitionPlan, authorization: String) async throws
    -> LinearQueueTransitionConflict? {
    let targets: QueueTransitionTargets = try await queueRequest(
      Self.queueTransitionTarget, ["stateID": plan.targetStateID], authorization: authorization)
    let connection = targets.workflowStates
    guard !connection.pageInfo.hasNextPage, connection.nodes.count == 1,
      let target = connection.nodes.first, target.id == plan.targetStateID,
      target.team.id == plan.teamID, target.type == "started", target.archivedAt == nil,
      plan.expectedStateID != plan.targetStateID
    else { return .unavailableTarget }

    let current = try await queueReadIssue(id: plan.issueID, authorization: authorization)
    try validateQueueAuthorization(authorization)
    return queueConflict(plan, issue: current)
  }

  private func validateQueueAuthorization(_ authorization: String) throws {
    try Task.checkCancellation()
    guard try authorization == currentAuthorization() else { throw LinearQueueError.accountChanged }
  }

  private func send(_ plan: LinearQueueTransitionPlan, authorization: String) async throws -> QueueSubmissionReceipt {
    do {
      let response: LinearGraphQLResponse<QueueTransitionResponse> = try await execute(
        query: Self.queueTransitionMutation,
        variables: ["issueID": plan.issueID, "stateID": plan.targetStateID],
        authorization: authorization, isQueueMutation: true)
      guard let payload = response.data?.issueUpdate else { return .uncertain }
      guard payload.success else { return .declined(.declined) }
      guard response.errors?.isEmpty != false, let issue = payload.issue,
        issue.id == plan.issueID, issue.state.id == plan.targetStateID,
        issue.project?.id == plan.projectID, issue.team.id == plan.teamID,
        issue.assignee?.id == plan.expectedAssigneeID, !issue.updatedAt.isEmpty
      else { return .uncertain }
      return .confirmed(revision: issue.updatedAt)
    } catch let rejection as LinearQueueTransitionRejection {
      return .declined(rejection)
    } catch is LinearAPIError {
      try Task.checkCancellation()
      return .uncertain
    }
  }

  private func observe(
    _ plan: LinearQueueTransitionPlan, phase: LinearQueueTransitionPhase,
    journal: any LinearQueueTransitionJournaling, authorization: String
  ) async throws -> LinearQueueTransitionOutcome {
    let current: LinearQueueIssue?
    do {
      current = try await queueReadIssue(id: plan.issueID, authorization: authorization)
    } catch is LinearAPIError {
      try Task.checkCancellation()
      return .uncertain
    }
    try validateQueueAuthorization(authorization)
    if let current, current.state.id == plan.targetStateID,
      current.projectID == plan.projectID, current.teamID == plan.teamID,
      current.assigneeID == plan.expectedAssigneeID, !current.isArchived {
      return try await record(.observedTarget(revision: current.revision), from: phase, plan: plan, journal: journal)
    }
    // A conflicting read alone cannot prove the request failed.
    if let conflict = queueConflict(plan, issue: current) { return .conflict(conflict) }
    return .uncertain
  }

  private func queueConflict(
    _ plan: LinearQueueTransitionPlan, issue: LinearQueueIssue?
  ) -> LinearQueueTransitionConflict? {
    guard let issue, issue.projectID == plan.projectID, issue.teamID == plan.teamID,
      !issue.isArchived
    else { return .outsideProject }
    guard issue.assigneeID == plan.expectedAssigneeID else { return .ownerChanged }
    guard issue.state.id == plan.expectedStateID, issue.state.isQueueEntry else { return .remoteStateChanged }
    guard issue.revision == plan.expectedRevision else { return .revisionChanged }
    return nil
  }

  private func record(
    _ phase: LinearQueueTransitionPhase, from expected: LinearQueueTransitionPhase,
    plan: LinearQueueTransitionPlan, journal: any LinearQueueTransitionJournaling
  ) async throws -> LinearQueueTransitionOutcome {
    let recorded = try await journal.resolveLinearQueueTransition(plan, from: expected, phase: phase)
    return outcome(for: plan, phase: recorded)
  }

  private func outcome(
    for plan: LinearQueueTransitionPlan, phase: LinearQueueTransitionPhase
  ) -> LinearQueueTransitionOutcome {
    switch phase {
    case .confirmed(let revision): .confirmed(stateID: plan.targetStateID, revision: revision)
    case .observedTarget(let revision): .observedTarget(stateID: plan.targetStateID, revision: revision)
    case .conflict(let reason): .conflict(reason)
    case .rejected(let reason): .rejected(reason)
    case .prepared, .submitted: .uncertain
    }
  }

  private static let queueTransitionTarget = """
    query QueueTransitionTarget($stateID: ID!) {
      workflowStates(first: 2, filter: { id: { eq: $stateID } }, includeArchived: true) {
        nodes { id type archivedAt team { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

  private static let queueTransitionMutation = """
    mutation QueueTransition($issueID: String!, $stateID: String!) {
      issueUpdate(id: $issueID, input: { stateId: $stateID }) {
        success
        issue { id updatedAt state { id } project { id } team { id } assignee { id } }
      }
    }
    """
}

private struct QueueTransitionTargets: Decodable, Sendable {
  let workflowStates: Connection

  struct Connection: Decodable, Sendable {
    let nodes: [State]
    let pageInfo: LinearPageInfo
  }

  struct State: Decodable, Sendable {
    let id: String
    let type: String
    let team: LinearQueueReference
    let archivedAt: String?
  }
}

private enum QueueSubmissionReceipt {
  case declined(LinearQueueTransitionRejection)
  case confirmed(revision: String)
  case uncertain
}

private struct QueueTransitionResponse: Decodable, Sendable {
  let issueUpdate: Payload?

  struct Payload: Decodable, Sendable {
    let success: Bool
    let issue: Issue?
  }

  struct Issue: Decodable, Sendable {
    let id: String
    let updatedAt: String
    let state: LinearQueueReference
    let project: LinearQueueReference?
    let team: LinearQueueReference
    let assignee: LinearQueueReference?
  }
}
