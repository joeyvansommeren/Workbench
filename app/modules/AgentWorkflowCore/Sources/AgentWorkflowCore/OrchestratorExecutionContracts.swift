import Foundation

public struct OrchestratorSourceRevision: Equatable, Sendable {
  public let issue: OrchestratorIssueIdentity
  public let queueScope: OrchestratorQueueScope
  public let revision: String
  public let ticketKey: String

  public init(issue: OrchestratorIssueIdentity, queueScope: OrchestratorQueueScope,
    revision: String, ticketKey: String)
  {
    self.issue = issue
    self.queueScope = queueScope
    self.revision = revision
    self.ticketKey = ticketKey
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.issue == rhs.issue && lhs.queueScope == rhs.queueScope
      && lhs.revision.utf8.elementsEqual(rhs.revision.utf8)
      && lhs.ticketKey.utf8.elementsEqual(rhs.ticketKey.utf8)
  }
}

public enum OrchestratorEligibilityBlock: Sendable, Equatable {
  case issueUnavailable
  case notEligible
  case revisionChanged
  case repositoryUnverified
  case dependencyUnverified
  case dependencyCycle
  case issueClaimed

  var message: String {
    switch self {
    case .issueUnavailable: "The ticket is unavailable or outside the approved queue."
    case .notEligible: "The ticket is no longer eligible under the approved queue policy."
    case .revisionChanged: "The ticket changed during launch preparation."
    case .repositoryUnverified: "The approved repository or worktree could not be verified."
    case .dependencyUnverified: "A prerequisite has not been verified on the approved base."
    case .dependencyCycle: "A prerequisite has a dependency cycle."
    case .issueClaimed: "Another Workbench run already owns this ticket."
    }
  }
}

public enum OrchestratorSourceCheck: Sendable, Equatable {
  /// A trusted tracker adapter verifies state, ownership, scope and implementation context
  /// against the configured policy before returning an eligible snapshot.
  case eligible(OrchestratorSourceRevision)
  case blocked(OrchestratorEligibilityBlock)
  case unavailable(OrchestratorRunAttention)
}

public protocol OrchestratorDispatchSource: Sendable {
  func eligibility(of selection: OrchestratorSelectedIssue, in run: OrchestratorRun) async throws
    -> OrchestratorSourceCheck
  /// Verifies that the approved source can still be read before resuming work.
  func checkScope(of run: OrchestratorRun) async throws -> OrchestratorRunAttention?
}

/// A read-only preparation result. Worktree creation and branch approval still
/// belong to the launch adapter and occur after the attempt is saved.
public struct OrchestratorWorktreePlan: Equatable, Sendable {
  public let repository: OrchestratorRepositoryBinding
  public let worktreePath: String
  public let launchPath: String?
  public let branchName: String
  public let baseCommitID: String
  public let dependencies: OrchestratorDependencyVerification?

  public init(repository: OrchestratorRepositoryBinding, worktreePath: String,
    launchPath: String? = nil, branchName: String, baseCommitID: String,
    dependencies: OrchestratorDependencyVerification? = nil)
  {
    self.repository = repository
    self.worktreePath = worktreePath
    self.launchPath = launchPath
    self.branchName = branchName
    self.baseCommitID = baseCommitID
    self.dependencies = dependencies
  }
}

public enum OrchestratorWorktreeCheck: Sendable, Equatable {
  case ready(OrchestratorWorktreePlan)
  case blocked(OrchestratorEligibilityBlock)
}

public protocol OrchestratorDispatchPreparing: Sendable {
  /// Resolve the approved base and prove integration, checkout ownership and a
  /// unique worktree target. A matching recovered allocation may be reused.
  func prepare(
    selection: OrchestratorSelectedIssue, snapshot: OrchestratorSourceRevision,
    existingAllocation: WorkflowAllocationRequest?
  ) async throws -> OrchestratorWorktreeCheck
}

public struct OrchestratorWorkerLaunch: Equatable, Sendable {
  public let attempt: OrchestratorDispatchAttempt
  public let plan: OrchestratorWorktreePlan
  public let snapshot: OrchestratorSourceRevision

  public init(attempt: OrchestratorDispatchAttempt, plan: OrchestratorWorktreePlan,
    snapshot: OrchestratorSourceRevision)
  {
    self.attempt = attempt
    self.plan = plan
    self.snapshot = snapshot
  }
}

public struct OrchestratorWorkerBinding: Equatable, Sendable {
  public let pendingLaunchID: UUID
  public let session: OrchestratorSessionIdentity

  public init(pendingLaunchID: UUID, session: OrchestratorSessionIdentity) {
    self.pendingLaunchID = pendingLaunchID
    self.session = session
  }
}

public enum OrchestratorWorkerObservation: Equatable, Sendable {
  /// Both the provider session and the app-owned process have been verified.
  case running(OrchestratorWorkerBinding)
  /// The adapter positively established that the attempt cannot start or be live.
  /// An empty list of processes, a timeout or a stale PID alone is insufficient.
  case stopped
  /// Launch was denied before any provider process could start.
  case requiresAttention(OrchestratorRunAttention)
  case uncertain
}

public protocol OrchestratorWorkerLaunching: Sendable {
  /// Starts at most once for the pending launch ID. Verify the approval, exact
  /// checkout, base and ownership again just before launch. Never fall back to a
  /// different provider or borrow another active workspace.
  func launch(_ launch: OrchestratorWorkerLaunch) async throws -> OrchestratorWorkerObservation

  /// Reconcile durable provider and process identity without restarting the worker.
  func observe(
    attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?
  ) async throws -> OrchestratorWorkerObservation

  /// Cancel only a positively matched process for this pending attempt. A
  /// stopped result must also exclude a later spawn for the same attempt.
  func cancel(
    attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?
  ) async throws -> OrchestratorWorkerObservation

  /// Validate a structured handoff from the original bound worker, outside the
  /// transcript. Its text cannot grant approval or establish eligibility.
  func verifyHandoff(attempt: OrchestratorDispatchAttempt, binding: OrchestratorWorkerBinding)
    async throws -> Bool
}

public protocol OrchestratorExecutionClock: Sendable {
  func now() -> Date
}

public struct SystemOrchestratorExecutionClock: OrchestratorExecutionClock {
  public init() {}
  public func now() -> Date { Date() }
}

public enum OrchestratorDispatchOutcome: Equatable, Sendable {
  case noEligibleWork
  case suspended(OrchestratorDispatchDecision)
  case attempted(itemID: UUID, attemptID: UUID)
}

public protocol OrchestratorQueueExecuting: Sendable {
  func start(runID: UUID) async throws
  func executeNext(runID: UUID) async throws -> OrchestratorDispatchOutcome
  func retry(runID: UUID, itemID: UUID) async throws -> OrchestratorDispatchOutcome
  func pause(runID: UUID) async throws
  func stop(runID: UUID) async throws
  func recover(runID: UUID) async throws
  func resume(runID: UUID) async throws
  func handOff(runID: UUID, itemID: UUID, attemptID: UUID,
    binding: OrchestratorWorkerBinding, eventID: UUID) async throws
}

public enum OrchestratorExecutionError: Error, Equatable, Sendable {
  case busy(UUID)
  case missingSelection(UUID)
  case mismatchedHandoff
  case unresolvedWork
  case unavailable
}
