import AgentHubGitHub
import Foundation
import Observation

@MainActor
@Observable
final class FinishSummaryModel {
  private let git: any FinishGitInspecting
  private let gitHub: any GitHubPRObservationServiceProtocol
  private let resultStore: (any SessionResultStoreProtocol)?
  private let resultSource: any ResultSourceInspecting
  private(set) var summary: FinishSummary?
  private(set) var isLoading = false

  init(git: any FinishGitInspecting, gitHub: any GitHubPRObservationServiceProtocol,
    resultStore: (any SessionResultStoreProtocol)? = nil,
    resultSource: any ResultSourceInspecting = ResultSourceService()) {
    self.git = git
    self.gitHub = gitHub
    self.resultStore = resultStore
    self.resultSource = resultSource
  }

  func load(
    session: CLISession,
    provider: SessionProviderKind,
    repositories: [SelectedRepository],
    sessions inventory: [FinishSessionResource],
    servers: [FinishServerResource],
    acceptance: SessionResultDecisionSnapshot?,
    runtime: FinishRuntimeInventory? = nil,
    refreshRuntime: (@MainActor () -> FinishRuntimeInventory)? = nil
  ) async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    let match = WorktreeModuleResolver.bestMatch(for: session.projectPath, repositories: repositories)
    let path = WorktreeModuleResolver.normalizedDirectoryPath(match?.worktree.path ?? session.projectPath)
    let initialSafety = try? await git.inspect(at: path)
    var sessions = inventory.filter { resource in
      let normalized = WorktreeModuleResolver.normalizedDirectoryPath(resource.path)
      return normalized == path || normalized.hasPrefix(path + "/")
    }
    let snapshot: GitHubPRObservationSnapshot?
    if let initialSafety {
      snapshot = await FinishGitHubSnapshotReader.read(service: gitHub, path: path, branch: initialSafety.branch)
    } else { snapshot = nil }
    let decision = await refreshAcceptance(session: session, provider: provider, fallback: acceptance)
    // Files and refs can change while GitHub and result checks suspend this task.
    // An unavailable final sample protects the worktree instead of reusing old facts.
    let safety = try? await git.inspect(at: path)
    guard !Task.isCancelled else { return }
    let currentRuntime = refreshRuntime?() ?? runtime
    if let currentRuntime {
      sessions = currentRuntime.sessions.filter { resource in
        let normalized = WorktreeModuleResolver.normalizedDirectoryPath(resource.path)
        return normalized == path || normalized.hasPrefix(path + "/")
      }
    }
    let available = snapshot?.state == .ready && snapshot?.isStale == false
    let pr = snapshot?.pullRequest
    let checks: String
    if !available { checks = "Checks unavailable" }
    else if let ci = snapshot?.ciSummary, ci.total > 0 {
      checks = "\(ci.passed) passing · \(ci.failed) failing · \(ci.pending) pending"
    } else { checks = "No check results recorded" }
    let publishing: String
    if !available { publishing = "Publishing status unavailable" }
    else if let pr {
      switch pr.stateKind {
      case .merged: publishing = "PR #\(pr.number) merged"
      case .closed: publishing = "PR #\(pr.number) closed without merge"
      case .open: publishing = "\(pr.isDraft ? "Draft PR" : "PR") #\(pr.number) open"
      case .unknown: publishing = "Pull request status unknown"
      }
    } else { publishing = "No pull request found for this branch" }
    summary = FinishSummary(
      projectPath: path,
      acceptance: Self.acceptanceText(decision),
      checks: checks,
      publishing: publishing,
      pullRequestURL: available ? pr.flatMap { URL(string: $0.url) } : nil,
      sessions: sessions,
      servers: servers,
      cleanup: FinishCleanupPolicy.proposal(path: path,
        isRegisteredWorktree: match?.worktree.isWorktree == true,
        git: safety, snapshot: snapshot, sessions: sessions, servers: servers, runtime: currentRuntime)
    )
  }

  private func refreshAcceptance(session: CLISession, provider: SessionProviderKind,
    fallback: SessionResultDecisionSnapshot?) async -> SessionResultDecisionSnapshot? {
    if let resultStore {
      let source = await resultSource.inspect(projectPath: session.projectPath)
      // Read the current persisted decision after source inspection, not the
      // snapshot the result view supplied when this sheet first opened.
      if let records = try? await resultStore.loadSessionResults() {
        return records.first { $0.provider == provider && $0.sessionID == session.id }?
          .acceptance(comparedTo: source.identity)
      }
    }
    guard let fallback, fallback.provider == provider, fallback.sessionID == session.id else { return nil }
    return SessionResultDecisionSnapshot(provider: fallback.provider, sessionID: fallback.sessionID,
      resultRevision: fallback.resultRevision, contentIdentity: fallback.contentIdentity,
      decision: fallback.decision, decidedAt: fallback.decidedAt, freshness: .unknown)
  }

  static func acceptanceText(_ decision: SessionResultDecisionSnapshot?) -> String {
    guard let decision else { return "Acceptance not recorded" }
    switch decision.decision {
    case .none: return "Acceptance not recorded"
    case .changesRequested: return decision.freshness == .current ? "Changes requested" : "Changes requested for an earlier result"
    case .accepted:
      switch decision.freshness {
      case .current: return "Recorded result accepted; source unchanged"
      case .stale: return "Earlier result accepted; source changed"
      case .unknown: return "Recorded result accepted; source not verified"
      }
    }
  }
}
