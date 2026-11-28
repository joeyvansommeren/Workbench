import AgentHubCLIKit
import AgentWorkflowCore
import Foundation

public struct OrchestratorWorkerAuthorization: Sendable {
  public let origin: SessionLaunchOrigin
  /// In memory only. Neither routing store nor process registry stores the prompt.
  public let initialPrompt: String?
  public let reuseOwnedWorktree: Bool

  public init(origin: SessionLaunchOrigin, initialPrompt: String? = nil, reuseOwnedWorktree: Bool = false) {
    self.origin = origin
    self.initialPrompt = initialPrompt
    self.reuseOwnedWorktree = reuseOwnedWorktree
  }
}

public protocol OrchestratorWorkerAuthorizing: Sendable {
  /// Host code grants the exact operation, source revision, branch, base, and
  /// checkout. Returning nil denies it. Agent reports are not authorizations.
  /// A reuse grant must verify current Workbench ownership and an idle checkout.
  func authorizeWorker(_ launch: OrchestratorWorkerLaunch) async throws
    -> OrchestratorWorkerAuthorization?
}

public protocol OrchestratorProviderWorkerDriving: Sendable {
  var provider: AgentProviderID { get }

  /// Uses the supplied pending ID in the existing durable provider launch
  /// registry. It must deduplicate that ID before starting a process.
  func start(attempt: OrchestratorDispatchAttempt, worktree: WorktreeBranch,
    launchPath: String, authorization: OrchestratorWorkerAuthorization) async throws
    -> OrchestratorWorkerObservation

  /// A .running result requires both the durable pending-to-real session binding
  /// and live, matching managed_processes ownership. Unknown ownership is uncertain.
  func observe(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    async throws -> OrchestratorWorkerObservation

  /// Only verified managed processes for this pending launch may be stopped.
  func cancel(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    async throws -> OrchestratorWorkerObservation

  func verifyHandoff(attempt: OrchestratorDispatchAttempt, binding: OrchestratorWorkerBinding)
    async throws -> Bool
}

/// Hand off physical worktree creation to the same service as other Workbench
/// launches. No default authorizer is installed. Run setup supplies the trusted
/// approval boundary and provider drivers before the feature can execute.
public actor WorkbenchOrchestratorWorker: OrchestratorWorkerLaunching {
  private let worktrees: any WorktreeManagementServiceProtocol
  private let git: any CommitGitRunning = CommitGitRunner(timeout: 5)
  private let authorizer: any OrchestratorWorkerAuthorizing
  private let providers: [any OrchestratorProviderWorkerDriving]
  private var launching = Set<UUID>()

  public init(worktrees: any WorktreeManagementServiceProtocol,
    authorizer: any OrchestratorWorkerAuthorizing,
    providers: [any OrchestratorProviderWorkerDriving])
  {
    self.worktrees = worktrees
    self.authorizer = authorizer
    self.providers = providers
  }

  public func launch(_ launch: OrchestratorWorkerLaunch) async throws -> OrchestratorWorkerObservation {
    let pendingID = launch.attempt.pendingLaunchID
    guard launching.insert(pendingID).inserted else { return .uncertain }
    defer { launching.remove(pendingID) }
    guard let provider = driver(for: launch.attempt.provider) else {
      return .requiresAttention(.providerUnavailable)
    }
    guard let authorization = try await authorizer.authorizeWorker(launch),
      Self.originMatches(authorization.origin, snapshot: launch.snapshot)
    else { return .requiresAttention(.worktreeApprovalRequired) }
    let plan = launch.plan
    guard Self.validCommit(plan.baseCommitID),
      launch.attempt.baseCommitID?.utf8.elementsEqual(plan.baseCommitID.utf8) == true
    else { return .requiresAttention(.worktreeApprovalRequired) }

    let path = try await resolvedLaunchPath(
      plan, reuse: authorization.reuseOwnedWorktree, isRetry: launch.attempt.predecessorID != nil)
    guard try currentCheckoutContainsBase(plan) else {
      return .requiresAttention(.worktreeApprovalRequired)
    }
    let branch = WorktreeBranch(name: plan.branchName, path: plan.worktreePath, isWorktree: true)
    try Task.checkCancellation()
    return try await provider.start(attempt: launch.attempt, worktree: branch,
      launchPath: path, authorization: authorization)
  }

  public func observe(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    async throws -> OrchestratorWorkerObservation
  {
    guard !launching.contains(attempt.pendingLaunchID),
      let provider = driver(for: attempt.provider)
    else { return .uncertain }
    return try await provider.observe(attempt: attempt, session: session)
  }

  public func cancel(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    async throws -> OrchestratorWorkerObservation
  {
    guard !launching.contains(attempt.pendingLaunchID),
      let provider = driver(for: attempt.provider)
    else { return .uncertain }
    return try await provider.cancel(attempt: attempt, session: session)
  }

  public func verifyHandoff(attempt: OrchestratorDispatchAttempt, binding: OrchestratorWorkerBinding)
    async throws -> Bool
  {
    guard let provider = driver(for: attempt.provider) else { return false }
    return try await provider.verifyHandoff(attempt: attempt, binding: binding)
  }

  private func driver(for id: AgentProviderID) -> (any OrchestratorProviderWorkerDriving)? {
    let matches = providers.filter { $0.provider.rawValue.utf8.elementsEqual(id.rawValue.utf8) }
    return matches.count == 1 ? matches.first : nil
  }

  private func resolvedLaunchPath(_ plan: OrchestratorWorktreePlan, reuse: Bool, isRetry: Bool)
    async throws -> String
  {
    let approvedRoot = plan.repository.repositoryPath
    let actualRoot = try await worktrees.findMainRepositoryRoot(at: approvedRoot)
    guard actualRoot.utf8.elementsEqual(approvedRoot.utf8) else {
      throw OrchestratorWorktreeLaunchError.mappingChanged
    }
    let directory = try await worktrees.worktreesDirectory(at: approvedRoot)
    let checkout = URL(fileURLWithPath: plan.worktreePath)
    guard checkout.deletingLastPathComponent().path.utf8.elementsEqual(directory.utf8) else {
      throw OrchestratorWorktreeLaunchError.mappingChanged
    }
    let expectedLaunch = plan.launchPath ?? plan.worktreePath
    let sourceStart = try Self.sourceStartPath(
      launchPath: expectedLaunch, worktreeRoot: plan.worktreePath, repoRoot: approvedRoot)
    let result: String
    if reuse {
      guard isRetry else { throw OrchestratorWorktreeLaunchError.mappingChanged }
      let registered = try await worktrees.listWorktrees(at: approvedRoot)
      guard registered.contains(where: {
        $0.isWorktree && $0.path.utf8.elementsEqual(plan.worktreePath.utf8)
          && $0.branch?.utf8.elementsEqual(plan.branchName.utf8) == true
      }) else { throw OrchestratorWorktreeLaunchError.mappingChanged }
      result = try await worktrees.launchPath(
        forStartPath: sourceStart, repoPath: approvedRoot, worktreePath: plan.worktreePath)
    } else {
      let created = try await worktrees.createAgentWorktreeWithNewBranch(
        at: approvedRoot, startPath: sourceStart, newBranchName: plan.branchName,
        directoryName: checkout.lastPathComponent, startPoint: plan.baseCommitID,
        sparseProfile: nil, fullCheckout: false)
      guard created.worktreePath.utf8.elementsEqual(plan.worktreePath.utf8) else {
        throw OrchestratorWorktreeLaunchError.mappingChanged
      }
      result = created.launchPath
    }
    guard result.utf8.elementsEqual(expectedLaunch.utf8) else {
      throw OrchestratorWorktreeLaunchError.mappingChanged
    }
    return result
  }

  private func currentCheckoutContainsBase(_ plan: OrchestratorWorktreePlan) throws -> Bool {
    let branch = try git.run(at: plan.worktreePath, arguments: ["symbolic-ref", "--quiet", "HEAD"],
      environment: [:], input: nil)
    let expectedRef = "refs/heads/" + plan.branchName + "\n"
    guard branch.status == 0, branch.stdout == Data(expectedRef.utf8) else { return false }
    // Inspect live HEAD instead of the intended branch tip. Disable replace refs
    // so local replacement objects cannot make a divergent checkout look safe.
    let ancestry = try git.run(at: plan.worktreePath,
      arguments: ["--no-replace-objects", "merge-base", "--is-ancestor", plan.baseCommitID, "HEAD"],
      environment: [:], input: nil)
    return ancestry.status == 0
  }

  private static func sourceStartPath(launchPath: String, worktreeRoot: String, repoRoot: String)
    throws -> String
  {
    if launchPath.utf8.elementsEqual(worktreeRoot.utf8) { return repoRoot }
    let prefix = worktreeRoot + "/"
    guard launchPath.utf8.starts(with: prefix.utf8),
      URL(fileURLWithPath: launchPath).standardizedFileURL.path.utf8.elementsEqual(launchPath.utf8)
    else { throw OrchestratorWorktreeLaunchError.mappingChanged }
    let relativePath = String(decoding: launchPath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    return URL(fileURLWithPath: repoRoot).appending(path: relativePath).path
  }

  private static func validCommit(_ commit: String) -> Bool {
    [40, 64].contains(commit.utf8.count) && commit.utf8.allSatisfy {
      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
  }

  private static func originMatches(_ origin: SessionLaunchOrigin, snapshot: OrchestratorSourceRevision)
    -> Bool
  {
    let source = snapshot.issue.source
    return origin.source.rawValue.utf8.elementsEqual(source.trackerID.utf8)
      && origin.accountID.utf8.elementsEqual(source.accountID.utf8)
      && origin.sourceID.utf8.elementsEqual(snapshot.issue.issueID.utf8)
      && origin.key.utf8.elementsEqual(snapshot.ticketKey.utf8)
  }
}

private enum OrchestratorWorktreeLaunchError: Error {
  case mappingChanged
}
