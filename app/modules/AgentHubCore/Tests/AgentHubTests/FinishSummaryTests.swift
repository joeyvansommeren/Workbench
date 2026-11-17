import AgentHubGitHub
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentHubCore

@MainActor
@Suite("Finish summary")
struct FinishSummaryTests {
  @Test("Acceptance requires an explicit current result decision")
  func acceptanceIsVersionBound() {
    #expect(FinishSummaryModel.acceptanceText(nil) == "Acceptance not recorded")
    let decision = SessionResultDecisionSnapshot(provider: .codex, sessionID: "s",
      resultRevision: UUID(), contentIdentity: "sha", decision: .accepted,
      decidedAt: Date(), freshness: .unknown)
    #expect(FinishSummaryModel.acceptanceText(decision).contains("source not verified"))
    let current = SessionResultDecisionSnapshot(provider: .codex, sessionID: "s",
      resultRevision: UUID(), contentIdentity: "sha", decision: .accepted,
      decidedAt: Date(), freshness: .current)
    #expect(FinishSummaryModel.acceptanceText(current) == "Recorded result accepted; source unchanged")
  }

  @Test("Only a clean exact merged head with quiet known sessions is a candidate")
  func cleanCandidate() {
    #expect(proposal().isCandidate)
    #expect(!proposal(git: FinishGitSafety(root: path, branch: "feature", head: "new", hasUncommittedChanges: false)).isCandidate)
    #expect(!proposal(git: FinishGitSafety(root: path, branch: "feature", head: "old", hasUncommittedChanges: true)).isCandidate)
    #expect(!proposal(registered: false).isCandidate)
    #expect(!proposal(snapshot: .initial(target: target)).isCandidate)
    #expect(!proposal(snapshot: snapshot(state: .error("unavailable"))).isCandidate)
    #expect(!proposal(snapshot: snapshot(prState: "CLOSED")).isCandidate)
    #expect(!proposal(snapshot: snapshot(prState: "OPEN")).isCandidate)
    let wrongTarget = GitHubPRObservationSnapshot(target: .currentBranch(projectPath: "/other-repo", branchName: "feature"),
      pullRequest: snapshot().pullRequest, checks: [], state: .ready, lastRefreshedAt: Date())
    #expect(!proposal(snapshot: wrongTarget).isCandidate)
    let oldReady = GitHubPRObservationSnapshot(target: target, pullRequest: snapshot().pullRequest,
      checks: [], state: .ready, lastRefreshedAt: Date(timeIntervalSinceNow: -300))
    #expect(!proposal(snapshot: oldReady).isCandidate)
  }

  @Test("Unknown, active and cross-provider sibling states protect a worktree")
  func unsafeSiblings() {
    let quiet = resource(id: "Claude:s")
    for sibling in [resource(id: "Codex:s", active: true), resource(status: nil, process: .unknown),
      resource(pending: true), resource(status: .thinking), resource(status: .awaitingApproval(tool: "Bash")),
      resource(branch: "other")] {
      #expect(!proposal(sessions: [quiet, sibling]).isCandidate)
    }
    #expect(!proposal(sessions: []).isCandidate)
    #expect(!proposal(servers: [FinishServerResource(id: "s", description: "External server", blocksCleanup: true)]).isCandidate)
  }

  @Test("Refresh compares current source with the current persisted decision")
  func refreshAcceptanceSourceAndRecord() async throws {
    var record = SessionResult(provider: .codex, sessionID: "s", projectPath: path)
    record.sourceIdentity = "accepted-source"
    record.decision = .accepted
    record.decidedAt = Date()
    let store = FinishAcceptanceTestStore(record: record)
    let source = FinishAcceptanceTestSource(identity: "accepted-source")
    let model = FinishSummaryModel(git: FinishTestGitInspector(safety:
      FinishGitSafety(root: path, branch: "one", head: "head", hasUncommittedChanges: false)),
      gitHub: FinishTestObserver(), resultStore: store, resultSource: source)
    let session = CLISession(id: "s", projectPath: path, branchName: "one", isWorktree: true)
    let oldSnapshot = record.acceptance(comparedTo: "accepted-source")
    await model.load(session: session, provider: .codex, repositories: [], sessions: [], servers: [], acceptance: oldSnapshot)
    #expect(model.summary?.acceptance == "Recorded result accepted; source unchanged")
    await source.setIdentity("changed-source")
    await model.load(session: session, provider: .codex, repositories: [], sessions: [], servers: [], acceptance: oldSnapshot)
    #expect(model.summary?.acceptance == "Earlier result accepted; source changed")
    await source.setIdentity(nil)
    await model.load(session: session, provider: .codex, repositories: [], sessions: [], servers: [], acceptance: oldSnapshot)
    #expect(model.summary?.acceptance == "Recorded result accepted; source not verified")
    record.decision = .none
    record.decidedAt = nil
    try await store.saveSessionResult(record)
    await model.load(session: session, provider: .codex, repositories: [], sessions: [], servers: [], acceptance: oldSnapshot)
    #expect(model.summary?.acceptance == "Acceptance not recorded")
  }

  @Test("A live or unknown process protects a quiet waiting session")
  func quietLiveProcessProtection() {
    var quiet = resource()
    quiet = FinishSessionResource(id: quiet.id, name: quiet.name, path: quiet.path,
      branchName: quiet.branchName, isPending: false, isActive: false, status: .waitingForUser,
      processState: .running, repositoryPath: "/repo", workflowID: "TES-1")
    #expect(!proposal(sessions: [quiet]).isCandidate)
    quiet.processState = .unknown
    #expect(!proposal(sessions: [quiet]).isCandidate)
  }

  @Test("Finish resamples process and pending evidence after awaited checks")
  func processStartsDuringRefresh() async {
    let stopped = resource(branch: "one")
    var live = stopped
    live.processState = .running
    let initial = FinishRuntimeInventory(isComplete: true, sessions: [stopped], terminals: [])
    let current = FinishRuntimeInventory(isComplete: true, sessions: [live], terminals: [
      FinishTerminalResource(provider: .codex, key: "s", projectPath: path, processID: 123, processState: .running)])
    let model = FinishSummaryModel(git: FinishTestGitInspector(safety:
      FinishGitSafety(root: path, branch: "one", head: "head", hasUncommittedChanges: false)),
      gitHub: FinishTestObserver())
    let session = CLISession(id: "s", projectPath: path, branchName: "one", isWorktree: true,
      lastActivityAt: Date(timeIntervalSinceNow: -3_600), isActive: false)
    let repositories = [SelectedRepository(path: "/repo", name: "Repo",
      worktrees: [WorktreeBranch(name: "one", path: path, isWorktree: true)])]
    await model.load(session: session, provider: .codex, repositories: repositories,
      sessions: initial.sessions, servers: [], acceptance: nil, runtime: initial, refreshRuntime: { current })
    #expect(model.summary?.sessions.first?.processState == .running)
    #expect(model.summary?.cleanup.isCandidate == false)
    #expect(model.summary?.cleanup.reasons.contains("A managed terminal process is still running.") == true)
  }

  @Test("Files changed during result inspection protect the cleanup proposal")
  func filesChangeDuringRefresh() async {
    let clean = FinishGitSafety(root: path, branch: "one", head: "head", hasUncommittedChanges: false)
    let dirty = FinishGitSafety(root: path, branch: "one", head: "head", hasUncommittedChanges: true)
    let git = FinishTransitionTestGitInspector(safety: clean)
    let source = FinishDirtyingTestSource(git: git, changedSafety: dirty)
    let record = SessionResult(provider: .codex, sessionID: "s", projectPath: path)
    let model = FinishSummaryModel(git: git, gitHub: FinishTestObserver(),
      resultStore: FinishAcceptanceTestStore(record: record), resultSource: source)
    let session = CLISession(id: "s", projectPath: path, branchName: "one", isWorktree: true)
    let repositories = [SelectedRepository(path: "/repo", name: "Repo",
      worktrees: [WorktreeBranch(name: "one", path: path, isWorktree: true)])]
    let stopped = resource(branch: "one")
    let runtime = FinishRuntimeInventory(isComplete: true, sessions: [stopped], terminals: [])

    await model.load(session: session, provider: .codex, repositories: repositories,
      sessions: runtime.sessions, servers: [], acceptance: nil, runtime: runtime)

    #expect(model.summary?.cleanup.isCandidate == false)
    #expect(model.summary?.cleanup.reasons.contains("Uncommitted or untracked files remain.") == true)
  }

  @Test("Recipe server keys and unscoped server inventory protect cleanup")
  func realRecipeServerKey() {
    let selected = resource(id: "Codex:s")
    let key = SessionResult.key(provider: .codex, sessionID: "s") + ":result"
    let keys = Set(FinishServerInventory.keys(for: selected))
    #expect(keys.contains(key))
    let inventory = [FinishServerRuntimeResource(key: key, projectPath: path + "/web",
      state: .ready(url: URL(string: "http://localhost:3000")!), isExternal: false),
      FinishServerRuntimeResource(key: "unknown-owner", projectPath: nil,
        state: .starting(message: "Starting"), isExternal: true),
      FinishServerRuntimeResource(key: "other", projectPath: "/other-project",
        state: .ready(url: URL(string: "http://localhost:3001")!), isExternal: false)]
    let servers = FinishServerInventory.resources(inventory, root: path, knownKeys: keys)
    #expect(Set(servers.map(\.id)) == Set([key, "unknown-owner"]))
    #expect(!proposal(servers: servers).isCandidate)
  }

  @Test("Runtime model scopes nested sessions and rejects another session's acceptance")
  func runtimeSummaryScope() async throws {
    let model = FinishSummaryModel(git: FinishTestGitInspector(safety:
      FinishGitSafety(root: path, branch: "one", head: "head", hasUncommittedChanges: false)),
      gitHub: FinishTestObserver())
    let nested = CLISession(id: "s", projectPath: path + "/ios", branchName: "one", isWorktree: true)
    let repositories = [SelectedRepository(path: "/repo", name: "Repo",
      worktrees: [WorktreeBranch(name: "one", path: path, isWorktree: true)])]
    let resources = [FinishSessionResource(id: "Codex:s", name: "Selected", path: nested.projectPath,
      branchName: "one", isPending: false, isActive: false, status: .idle),
      FinishSessionResource(id: "Claude:s", name: "Sibling", path: path, branchName: "one",
        isPending: false, isActive: false, status: .thinking),
      FinishSessionResource(id: "Codex:other", name: "Other", path: "/other", branchName: "other",
        isPending: false, isActive: false, status: .idle)]
    let wrongAcceptance = SessionResultDecisionSnapshot(provider: .claude, sessionID: "s",
      resultRevision: UUID(), contentIdentity: "head", decision: .accepted, decidedAt: Date(), freshness: .current)
    await model.load(session: nested, provider: .codex, repositories: repositories,
      sessions: resources, servers: [], acceptance: wrongAcceptance)
    let summary = try #require(model.summary)
    #expect(summary.sessions.map(\.id) == ["Codex:s", "Claude:s"])
    #expect(summary.acceptance == "Acceptance not recorded")
    #expect(!summary.cleanup.isCandidate)
    #expect(summary.checks == "No check results recorded")
  }

  @Test("Long finish content fits a sheet inside the 900 point minimum window")
  func nativeLayoutSmoke() {
    let summary = FinishSummary(projectPath: String(repeating: "/long-project", count: 20),
      acceptance: "Acceptance not recorded", checks: "Checks unavailable",
      publishing: "Publishing status unavailable", pullRequestURL: nil,
      sessions: [resource(id: "Codex:s")], servers: [], cleanup: proposal())
    let view = FinishSummaryView(summary: summary).frame(width: DesignTokens.Width.sheet - 48)
    let host = NSHostingView(rootView: view)
    #expect(host.fittingSize.width <= DesignTokens.Width.sheet)
    #expect(host.fittingSize.width < ShellLayout.windowMinWidth)
    #expect(host.fittingSize.height > 0)
  }

  private var path: String { "/tmp/finish-feature" }
  private var target: GitHubPRObservationTarget { .currentBranch(projectPath: path, branchName: "feature") }
  private func resource(id: String = "Codex:s", active: Bool = false, pending: Bool = false,
    status: SessionStatus? = .idle, branch: String = "feature", process: FinishProcessState = .stopped) -> FinishSessionResource {
    FinishSessionResource(id: id, name: "Long session name", path: path, branchName: branch,
      isPending: pending, isActive: active, status: status, processState: process,
      repositoryPath: "/repo", workflowID: "TES-1")
  }
  private func snapshot(state: GitHubPRObservationState = .ready, prState: String = "MERGED") -> GitHubPRObservationSnapshot {
    let pr = GitHubPullRequest(number: 1, title: "Feature", body: nil, state: prState,
      url: "https://github.com/example/repo/pull/1", headRefName: "feature", headRefOid: "old",
      baseRefName: "main", author: nil, createdAt: nil, updatedAt: nil, isDraft: false,
      mergeable: nil, additions: 1, deletions: 0, changedFiles: 1, reviewDecision: nil,
      statusCheckRollup: [], labels: nil, reviewRequests: nil, comments: nil)
    return GitHubPRObservationSnapshot(target: target, pullRequest: pr, checks: [], state: state, lastRefreshedAt: Date())
  }
  private func proposal(git: FinishGitSafety? = nil, registered: Bool = true,
    snapshot observed: GitHubPRObservationSnapshot? = nil, sessions: [FinishSessionResource]? = nil,
    servers: [FinishServerResource] = []) -> FinishCleanupProposal {
    FinishCleanupPolicy.proposal(path: path, isRegisteredWorktree: registered,
      git: git ?? FinishGitSafety(root: path, branch: "feature", head: "old", hasUncommittedChanges: false),
      snapshot: observed ?? snapshot(), sessions: sessions ?? [resource()], servers: servers,
      runtime: FinishRuntimeInventory(isComplete: true, sessions: sessions ?? [resource()], terminals: []))
  }
}


private actor FinishAcceptanceTestStore: SessionResultStoreProtocol {
  var record: SessionResult
  init(record: SessionResult) { self.record = record }
  func loadSessionResults() async throws -> [SessionResult] { [record] }
  func saveSessionResult(_ result: SessionResult) async throws { record = result }
}

private actor FinishAcceptanceTestSource: ResultSourceInspecting {
  var identity: String?
  init(identity: String?) { self.identity = identity }
  func setIdentity(_ identity: String?) { self.identity = identity }
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: projectPath, identity: identity)
  }
}

private actor FinishTransitionTestGitInspector: FinishGitInspecting {
  private var safety: FinishGitSafety
  init(safety: FinishGitSafety) { self.safety = safety }
  func update(_ safety: FinishGitSafety) { self.safety = safety }
  func inspect(at path: String) async throws -> FinishGitSafety { safety }
}

private struct FinishDirtyingTestSource: ResultSourceInspecting {
  let git: FinishTransitionTestGitInspector
  let changedSafety: FinishGitSafety
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    await git.update(changedSafety)
    return ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: projectPath, identity: nil)
  }
}
