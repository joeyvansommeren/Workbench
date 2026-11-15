import AgentHubGitHub
import Foundation

struct FinishSessionResource: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let path: String
  let branchName: String?
  let isPending: Bool
  let isActive: Bool
  let status: SessionStatus?
  var processState: FinishProcessState = .unknown
  var repositoryPath: String? = nil
  var workflowID: String? = nil
}

struct FinishServerResource: Identifiable, Equatable, Sendable {
  let id: String
  let description: String
  let blocksCleanup: Bool
}

struct FinishGitSafety: Equatable, Sendable {
  let root: String
  let branch: String
  let head: String
  let hasUncommittedChanges: Bool
}

struct FinishCleanupProposal: Equatable, Sendable {
  let worktreePath: String
  let isCandidate: Bool
  let reasons: [String]
}

/// Every unknown fact protects the worktree. This value never performs cleanup.
enum FinishCleanupPolicy {
  static func proposal(
    path: String,
    isRegisteredWorktree: Bool,
    git: FinishGitSafety?,
    snapshot: GitHubPRObservationSnapshot?,
    sessions: [FinishSessionResource],
    servers: [FinishServerResource],
    runtime: FinishRuntimeInventory? = nil
  ) -> FinishCleanupProposal {
    var reasons: [String] = []
    if let runtime {
      if !runtime.isComplete { reasons.append("The complete session and process inventory is unavailable.") }
      reasons += runtime.terminalProtectionReasons(at: path)
    } else { reasons.append("Session process safety is unknown.") }
    if !isRegisteredWorktree { reasons.append("This is not a registered worktree.") }
    guard let git else {
      return FinishCleanupProposal(worktreePath: path, isCandidate: false,
        reasons: reasons + ["Working tree and commit safety could not be checked."])
    }
    if git.root != path { reasons.append("The worktree root changed.") }
    if git.hasUncommittedChanges { reasons.append("Uncommitted or untracked files remain.") }
    if sessions.isEmpty { reasons.append("Session safety is unknown.") }
    for session in sessions {
      if session.processState != .stopped { reasons.append("A session process is running or its state is unknown.") }
      if session.branchName != git.branch { reasons.append("A session belongs to another or unknown branch.") }
      if session.isPending || session.isActive {
        reasons.append("A session is still active or starting.")
      }
      switch session.status {
      case .thinking?, .executingTool?, .awaitingApproval?:
        reasons.append("A session is working or needs approval.")
      case nil:
        if session.processState != .stopped { reasons.append("A session status is unknown.") }
      case .idle?, .waitingForUser?: break
      }
    }
    if servers.contains(where: \.blocksCleanup) { reasons.append("A server is running or its ownership is unknown.") }
    if let snapshot, snapshot.state == .ready, !snapshot.isStale,
      FinishGitHubSnapshotReader.matches(snapshot, path: path, branch: git.branch),
      snapshot.lastRefreshedAt.map({ Date().timeIntervalSince($0) <= 120 }) == true, let pr = snapshot.pullRequest,
      pr.stateKind == .merged, pr.headRefName == git.branch,
      let mergedHead = pr.headRefOid, mergedHead == git.head {
      if !snapshot.blockers.isEmpty || snapshot.ciSummary.overallStatus == .pending || snapshot.ciSummary.overallStatus == .failure {
        reasons.append("Pull request checks still need attention.")
      }
    } else {
      reasons.append("A current merged pull request for this exact branch and commit is not confirmed.")
    }
    return FinishCleanupProposal(worktreePath: path, isCandidate: reasons.isEmpty,
      reasons: Array(Set(reasons)).sorted())
  }
}

struct FinishSummary: Sendable {
  let projectPath: String
  let acceptance: String
  let checks: String
  let publishing: String
  let pullRequestURL: URL?
  let sessions: [FinishSessionResource]
  let servers: [FinishServerResource]
  let cleanup: FinishCleanupProposal
}
