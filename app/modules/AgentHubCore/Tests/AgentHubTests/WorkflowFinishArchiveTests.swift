import AgentHubGitHub
import Foundation
import Testing
@testable import AgentHubCore

@Suite("Workflow finish archive")
struct WorkflowFinishArchiveTests {
  @Test("One merged branch never archives a mixed task")
  func mixedBranches() {
    #expect(WorkflowFinishArchivePolicy.canArchive([branch("one", state: .merged)]))
    #expect(!WorkflowFinishArchivePolicy.canArchive([branch("one", state: .merged), branch("two", state: .open)]))
    #expect(!WorkflowFinishArchivePolicy.canArchive([branch("one", state: .closed)]))
    #expect(!WorkflowFinishArchivePolicy.canArchive([]))
  }

  @Test("Archive evidence cannot be reused for another branch, PR or version")
  func recordBinding() {
    let branch = branch("one", state: .merged)
    let record = WorkflowFinishArchiveRecord(workflowID: "TES-1", repositoryPath: branch.repositoryPath,
      branchName: "one", pullRequestURL: branch.pullRequest!.url,
      pullRequestHeadSHA: "head", archivedAt: Date())
    #expect(record.matches(branch, workflowID: "TES-1"))
    #expect(!record.matches(branch, workflowID: "TES-2"))
    #expect(!record.matches(self.branch("two", state: .merged), workflowID: "TES-1"))
  }

  @Test("Restoring a persisted automatic archive survives reload for exactly that PR head")
  @MainActor
  func durableRestore() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-restore-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("metadata.sqlite").path
    let store = try SessionMetadataStore(path: path)
    let record = WorkflowFinishArchiveRecord(workflowID: "TES-1", repositoryPath: "/repo",
      branchName: "one", pullRequestURL: "https://github.com/example/repo/pull/1",
      pullRequestHeadSHA: "head", archivedAt: Date())
    try await store.saveWorkflowFinishArchive(record)
    let vm = AgentWorkflowDashboardViewModel(sessionObservationSource: { [] })
    await vm.configureFinishArchiving(store: store, observationService: FinishTestObserver(),
      gitInspector: FinishTestGitInspector(safety: FinishGitSafety(root: "/worktree", branch: "one", head: "head", hasUncommittedChanges: false)))
    await vm.restoreAutomaticallyArchivedWorkflow("TES-1")
    let reopened = try SessionMetadataStore(path: path)
    let records = try await reopened.loadWorkflowFinishArchives()
    #expect(records.count == 1)
    #expect(records.first?.restoredAt != nil)
    #expect(WorkflowFinishArchivePolicy.wasRestored(record, among: records))
    let newHead = WorkflowFinishArchiveRecord(workflowID: "TES-1", repositoryPath: "/repo",
      branchName: "one", pullRequestURL: record.pullRequestURL,
      pullRequestHeadSHA: "new-head", archivedAt: Date())
    #expect(!WorkflowFinishArchivePolicy.wasRestored(newHead, among: records))
    #expect(try await reopened.loadSessionResults().isEmpty)
  }

  @Test("Failed history reads block every write and preserve durable restore choices")
  @MainActor
  func failedHistoryCannotEraseRestore() async throws {
    let merged = branch("one", state: .merged)
    var restored = WorkflowFinishArchiveRecord(workflowID: "TES-1", repositoryPath: "/repo",
      branchName: "one", pullRequestURL: merged.pullRequest!.url,
      pullRequestHeadSHA: "head", archivedAt: Date())
    restored.restoredAt = Date()
    let other = WorkflowFinishArchiveRecord(workflowID: "TES-2", repositoryPath: "/repo",
      branchName: "two", pullRequestURL: "https://github.com/example/repo/pull/2",
      pullRequestHeadSHA: "other", archivedAt: Date())
    let store = FailingFinishHistoryStore(records: [restored, other])
    let resource = FinishSessionResource(id: "Codex:s", name: "Old session", path: "/worktree",
      branchName: "one", isPending: false, isActive: false, status: .waitingForUser,
      processState: .stopped, repositoryPath: "/repo", workflowID: "TES-1")
    let inventory = FinishRuntimeInventory(isComplete: true, sessions: [resource], terminals: [])
    let vm = AgentWorkflowDashboardViewModel(sessionObservationSource: { [] })
    await vm.configureFinishArchiving(store: store, observationService: FinishTestObserver(),
      gitInspector: FinishTestGitInspector(safety: FinishGitSafety(root: "/worktree", branch: "one", head: "head", hasUncommittedChanges: false)),
      inventorySource: { inventory })
    var attempted = restored
    attempted.restoredAt = nil
    #expect(!(await vm.persistAutomaticFinishArchive([attempted], workflowID: "TES-1", branches: [merged])))
    await vm.restoreAutomaticallyArchivedWorkflow("TES-2")
    #expect(await store.writes == 0)
    await store.allowHistoryReads()
    #expect(!(await vm.persistAutomaticFinishArchive([attempted], workflowID: "TES-1", branches: [merged])))
    await vm.restoreAutomaticallyArchivedWorkflow("TES-2")
    #expect(await store.writes == 1)
    let saved = try await store.loadWorkflowFinishArchives()
    #expect(saved.first { $0.workflowID == "TES-1" }?.restoredAt == restored.restoredAt)
    #expect(saved.first { $0.workflowID == "TES-2" }?.restoredAt != nil)
  }

  @Test("Complete inventory protects pending, unanalyzed and quiet live siblings")
  func fullRuntimeInventory() {
    let merged = branch("one", state: .merged)
    let stopped = FinishSessionResource(id: "Codex:s", name: "Old waiting session", path: "/worktree",
      branchName: "one", isPending: false, isActive: false, status: .waitingForUser,
      processState: .stopped, repositoryPath: "/repo", workflowID: "TES-1")
    let harmless = (0..<10).map { index in
      FinishSessionResource(id: "Claude:older-\(index)", name: "Other task", path: "/other-worktree",
        branchName: "other", isPending: false, isActive: false, status: .idle,
        processState: .stopped, repositoryPath: "/repo", workflowID: "TES-2")
    }
    func allowed(_ resources: [FinishSessionResource], terminals: [FinishTerminalResource] = []) -> Bool {
      WorkflowFinishRuntimePolicy.canArchive(workflowID: "TES-1", branches: [merged],
        inventory: FinishRuntimeInventory(isComplete: true, sessions: resources, terminals: terminals))
    }
    #expect(allowed([stopped] + harmless))
    var sibling = stopped
    sibling = FinishSessionResource(id: "Claude:beyond-analysis-quota", name: "Unanalyzed sibling",
      path: "/new-worktree", branchName: "new-branch", isPending: false, isActive: true,
      status: .thinking, processState: .running, repositoryPath: "/repo", workflowID: "TES-1")
    #expect(!allowed([stopped] + harmless + [sibling]))
    let pending = FinishSessionResource(id: "Claude:pending-new", name: "Pending sibling",
      path: "/new-worktree", branchName: "new-branch", isPending: true, isActive: true,
      status: nil, repositoryPath: "/repo")
    #expect(!allowed([stopped] + harmless + [pending]))
    var quietLive = stopped
    quietLive.processState = .running
    #expect(!allowed([quietLive]))
    var unknown = stopped
    unknown.processState = .unknown
    #expect(!allowed([unknown]))
    #expect(!allowed([stopped], terminals: [FinishTerminalResource(provider: .codex,
      key: "s", projectPath: "/worktree", processID: 123, processState: .running)]))
    #expect(!WorkflowFinishRuntimePolicy.canArchive(workflowID: "TES-1", branches: [merged], inventory: .unknown))
  }

  @Test("Live archive planner verifies the observer target, merge and disk head")
  func runtimeArchiveSafety() async {
    let branch = branch("one", state: .merged)
    let safe = FinishTestGitInspector(safety: FinishGitSafety(root: "/worktree", branch: "one", head: "head", hasUncommittedChanges: false))
    let observer = FinishTestObserver()
    let planner = WorkflowFinishArchivePlanner(observer: observer, inspector: safe)
    let records = await planner.records(workflowID: "TES-1", branches: [branch])
    #expect(records.count == 1)
    #expect(records.first?.pullRequestHeadSHA == "head")
    #expect(await observer.unsubscribeCount == 1)

    let wrongTarget = FinishTestObserver(wrongTarget: true)
    #expect(await WorkflowFinishArchivePlanner(observer: wrongTarget, inspector: safe)
      .records(workflowID: "TES-1", branches: [branch]).isEmpty)
    let stale = FinishTestObserver(stale: true)
    #expect(await WorkflowFinishArchivePlanner(observer: stale, inspector: safe)
      .records(workflowID: "TES-1", branches: [branch]).isEmpty)
    for safety in [
      FinishGitSafety(root: "/worktree", branch: "one", head: "later", hasUncommittedChanges: false),
      FinishGitSafety(root: "/worktree", branch: "one", head: "head", hasUncommittedChanges: true),
      FinishGitSafety(root: "/worktree", branch: "other", head: "head", hasUncommittedChanges: false)
    ] {
      #expect(await WorkflowFinishArchivePlanner(observer: observer,
        inspector: FinishTestGitInspector(safety: safety)).records(workflowID: "TES-1", branches: [branch]).isEmpty)
    }
    #expect(await planner.records(workflowID: "TES-1", branches: [branch, self.branch("two", state: .open)]).isEmpty)
    #expect(!WorkflowFinishArchivePolicy.canArchive([self.branch("one", state: .merged, active: true)]))
  }

  private func branch(_ name: String, state: GitHubPullRequestState, active: Bool = false) -> DetectedBranchWorkflow {
    let assignment = DetectedAgentSession(session: CLISession(id: "s", projectPath: "/worktree",
      branchName: name, isWorktree: true, isActive: active), provider: .codex,
      role: .implementer, roleConfidence: .high, roleReason: "Test")
    return DetectedBranchWorkflow(id: name, ticketKey: "TES-1", repositoryPath: "/repo",
      repositoryName: "Repo", branchName: name, implementerSessions: [assignment], reviewerSessions: [],
      linkedPullRequests: [], pullRequest: DetectedPullRequest(number: 1, title: "Feature",
        url: "https://github.com/example/repo/pull/1", state: state, headBranch: name, headSHA: "head"),
      lastActivityAt: Date())
  }
}

struct FinishTestGitInspector: FinishGitInspecting {
  let safety: FinishGitSafety
  func inspect(at path: String) async throws -> FinishGitSafety { safety }
}

actor FinishTestObserver: GitHubPRObservationServiceProtocol {
  let wrongTarget: Bool
  let stale: Bool
  private(set) var unsubscribeCount = 0
  init(wrongTarget: Bool = false, stale: Bool = false) {
    self.wrongTarget = wrongTarget
    self.stale = stale
  }
  func subscribe(to target: GitHubPRObservationTarget, refreshOnSubscribe: Bool) async -> GitHubPRObservationSubscription {
    let pr = GitHubPullRequest(number: 1, title: "Feature", body: nil, state: "MERGED",
      url: "https://github.com/example/repo/pull/1", headRefName: "one", headRefOid: "head",
      baseRefName: "main", author: nil, createdAt: nil, updatedAt: nil, isDraft: false,
      mergeable: nil, additions: 1, deletions: 0, changedFiles: 1, reviewDecision: nil,
      statusCheckRollup: [], labels: nil, reviewRequests: nil, comments: nil)
    let snapshot = GitHubPRObservationSnapshot(
      target: wrongTarget ? .currentBranch(projectPath: "/other-repository", branchName: "one") : target,
      pullRequest: pr, checks: [], state: .ready,
      lastRefreshedAt: stale ? Date(timeIntervalSinceNow: -300) : Date())
    return GitHubPRObservationSubscription(id: UUID(), updates: AsyncStream { continuation in
      continuation.yield(snapshot)
      continuation.finish()
    })
  }
  func unsubscribe(subscriptionID: UUID) async { unsubscribeCount += 1 }
  func refresh(_ target: GitHubPRObservationTarget) async {}
  func recordActivity(for target: GitHubPRObservationTarget, at: Date) async {}
}


private actor FailingFinishHistoryStore: WorkflowFinishArchiveStoring {
  private var records: [WorkflowFinishArchiveRecord]
  private var readsFail = true
  private(set) var writes = 0
  init(records: [WorkflowFinishArchiveRecord]) { self.records = records }
  func allowHistoryReads() { readsFail = false }
  func loadWorkflowFinishArchives() async throws -> [WorkflowFinishArchiveRecord] {
    if readsFail { throw CocoaError(.fileReadUnknown) }
    return records
  }
  func saveWorkflowFinishArchive(_ record: WorkflowFinishArchiveRecord) async throws {
    writes += 1
    records.removeAll { $0.workflowID == record.workflowID && $0.repositoryPath == record.repositoryPath && $0.branchName == record.branchName }
    records.append(record)
  }
}
