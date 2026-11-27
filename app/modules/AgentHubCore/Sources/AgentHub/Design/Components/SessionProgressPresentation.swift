import AgentHubGitHub
import Foundation

/// The next action is a projection of independent provider, result and GitHub
/// facts. A complete provider turn can be ready to read without any work to review.
struct SessionProgressPresentation: Equatable {
  enum Action: Equatable {
    case starting
    case working
    case answer
    case permission
    case readResponse
    case reviewChanges
    case checkFailure
    case notRunning
    case unavailable
  }

  let action: Action
  let status: SessionStatusPresentation
  let reason: String
  let publication: String?
  let startedAt: Date?
  let updatedAt: Date?
  let lastCompletedAt: Date?

  init(
    state: SessionMonitorState?,
    pendingSince: Date? = nil,
    terminalExitedAt: Date? = nil,
    result: SessionResult? = nil,
    projectPath: String,
    branch: String? = nil,
    snapshot: GitHubPRObservationSnapshot? = nil
  ) {
    let turn = state?.turnProgress
    let currentPR = Self.currentPullRequest(snapshot, projectPath: projectPath, branch: branch)
    let terminalStopped = terminalExitedAt.map { exit in
      state.map { $0.lastActivityAt <= exit } ?? true
    } ?? false
    let currentResult: SessionResult? = result.flatMap { result in
      guard result.matches(projectPath: projectPath),
        turn?.startedAt.map({ $0 <= result.updatedAt }) ?? true else { return nil }
      return result
    }

    startedAt = turn?.startedAt ?? state?.sessionStartedAt ?? pendingSince
    updatedAt = state?.sessionStartedAt == nil ? nil : state?.lastActivityAt
    lastCompletedAt = turn?.lastCompletedAt
    publication = currentPR.map(Self.publicationLabel)

    switch (state?.status, turn?.phase) {
    case _ where pendingSince != nil:
      action = .starting
      reason = "Opening the provider."
    case _ where state?.isSourceAvailable == false && !terminalStopped:
      action = .unavailable
      reason = "Workbench lost access to this session’s transcript."
    case (.awaitingApproval(let tool), _) where !terminalStopped:
      if SessionInteractiveInputTool.matches(tool) {
        action = .answer
        reason = "Open the terminal to answer the agent’s question."
      } else {
        action = .permission
        reason = "Open the terminal to review the permission request."
      }
    case (.thinking, _) where !terminalStopped, (.executingTool, _) where !terminalStopped:
      action = .working
      reason = "The agent is working on this turn."
    case _ where currentPR?.stateKind == .open && snapshot?.ciSummary.overallStatus == .failure:
      action = .checkFailure
      reason = "A check failed on the current pull request."
    case _ where currentResult?.decision == SessionProductDecision.none:
      action = .reviewChanges
      reason = "A result is ready for review."
    case (_, .responded):
      action = .readResponse
      reason = "The agent finished its response."
    case (_, .finishedWithoutResponse):
      action = .notRunning
      reason = "The turn ended without a response."
    case _ where terminalStopped:
      action = .notRunning
      reason = "The terminal process has stopped."
    case (_, .interrupted):
      action = .notRunning
      reason = "The turn was interrupted."
    default:
      action = .unavailable
      reason = "Refresh sessions or open the terminal to check what is happening."
    }

    status = SessionStatusPresentation(progressAction: action)
  }

  private static func currentPullRequest(
    _ snapshot: GitHubPRObservationSnapshot?, projectPath: String, branch: String?
  ) -> GitHubPullRequest? {
    guard let snapshot, snapshot.state == .ready, !snapshot.isStale,
      case .session(let path, let observedBranch, _) = snapshot.target,
      let branch, branch == observedBranch,
      WorktreeModuleResolver.normalizedDirectoryPath(path) == WorktreeModuleResolver.normalizedDirectoryPath(projectPath),
      snapshot.pullRequest?.headRefName == branch
    else { return nil }
    return snapshot.pullRequest
  }

  private static func publicationLabel(_ pr: GitHubPullRequest) -> String {
    switch pr.stateKind {
    case .open: pr.isDraft ? "Draft PR #\(pr.number)" : "Open PR #\(pr.number)"
    case .merged: "Merged PR #\(pr.number)"
    case .closed: "Closed PR #\(pr.number)"
    case .unknown: "PR #\(pr.number)"
    }
  }
}
