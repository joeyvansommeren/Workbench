import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Branch workflow decoration")
struct BranchWorkflowDecorationTests {
  @Test("A detected pull request decorates its branch with number, state and CI")
  func pullRequestBadge() {
    var branch = workflowBranch(id: "b1", repo: "/tmp/Repo", branch: "feat/x", implementers: ["s1"])
    branch.pullRequest = DetectedPullRequest(
      number: 212,
      title: "Fix",
      url: "https://github.com/o/r/pull/212",
      state: .open,
      headBranch: "feat/x",
      ciStatus: .failure
    )

    let index = BranchWorkflowDecorationIndex(branches: [branch])
    let decoration = index.decoration(
      repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "feat/x")

    #expect(decoration?.pullRequest?.number == 212)
    #expect(decoration?.pullRequest?.state == .open)
    #expect(decoration?.pullRequest?.ciStatus == .failure)
    #expect(decoration?.pullRequest?.url == "https://github.com/o/r/pull/212")
  }

  @Test("A branch with no pull request has no badge")
  func noPullRequest() {
    let branch = workflowBranch(id: "b1", repo: "/tmp/Repo", branch: "main", implementers: ["s1"])
    let decoration = BranchWorkflowDecorationIndex(branches: [branch])
      .decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "main")
    #expect(decoration != nil)
    #expect(decoration?.pullRequest == nil)
  }

  @Test("Roles are keyed by sidebar item id; labels show only once there is a reviewer")
  func roles() {
    let implementOnly = workflowBranch(
      id: "b1", repo: "/tmp/Repo", branch: "a", implementers: ["s1", "s2"])
    let reviewed = workflowBranch(
      id: "b2", repo: "/tmp/Repo", branch: "b", implementers: ["s3"], reviewers: [("s4", .codex)])

    let index = BranchWorkflowDecorationIndex(branches: [implementOnly, reviewed])
    let first = index.decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "a")
    let second = index.decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "b")

    let claudeS1 = SidebarSessionItemID.monitored(provider: .claude, sessionId: "s1")
    let claudeS3 = SidebarSessionItemID.monitored(provider: .claude, sessionId: "s3")
    let codexS4 = SidebarSessionItemID.monitored(provider: .codex, sessionId: "s4")
    #expect(first?.roles[claudeS1] == .implementer)
    #expect(first?.showsRoleLabels == false)
    #expect(second?.roles[claudeS3] == .implementer)
    #expect(second?.roles[codexS4] == .reviewer)
    #expect(second?.showsRoleLabels == true)
  }

  @Test("Review starts with the other model, only when nobody reviews yet")
  func reviewProvider() {
    let claudeImplementer = workflowBranch(
      id: "b1", repo: "/tmp/Repo", branch: "a", implementers: ["s1"])
    let codexImplementer = workflowBranch(
      id: "b2", repo: "/tmp/Repo", branch: "b", implementers: ["s2"], implementerProvider: .codex)
    let alreadyReviewed = workflowBranch(
      id: "b3", repo: "/tmp/Repo", branch: "c", implementers: ["s3"], reviewers: [("s4", .codex)])
    var merged = workflowBranch(id: "b4", repo: "/tmp/Repo", branch: "d", implementers: ["s5"])
    merged.pullRequest = DetectedPullRequest(
      number: 1, title: "", url: "", state: .merged, headBranch: "d")

    let index = BranchWorkflowDecorationIndex(branches: [
      claudeImplementer, codexImplementer, alreadyReviewed, merged,
    ])
    let decoration = { (name: String) in
      index.decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: name)
    }

    #expect(decoration("a")?.reviewProvider == .codex)
    #expect(decoration("b")?.reviewProvider == .claude)
    #expect(decoration("c")?.reviewProvider == nil)
    #expect(decoration("c")?.canCompare == true)
    #expect(decoration("d")?.reviewProvider == nil)
    #expect(decoration("a")?.canCompare == false)
  }

  @Test("Archived workflows are hidden")
  func archivedHidden() {
    var archived = workflowBranch(id: "b1", repo: "/tmp/Repo", branch: "old", implementers: ["s1"])
    archived.isArchived = true
    var archivedManual = manualBranch(workflowID: "manual:A", repo: "/tmp/Repo", branch: "gone")
    archivedManual.isArchived = true

    let index = BranchWorkflowDecorationIndex(branches: [archived, archivedManual])

    #expect(index.decorations.isEmpty)
    #expect(index.manualWorkflowsWithoutSessions.isEmpty)
    #expect(
      index.decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "old") == nil)
  }

  @Test("Manual workflows with no sessions become empty branch rows")
  func manualWorkflowEmptyRow() {
    let manual = manualBranch(workflowID: "manual:A", repo: "/tmp/Repo", branch: "feat/empty")
    let index = BranchWorkflowDecorationIndex(branches: [manual])
    let repository = SelectedRepository(
      path: "/tmp/Repo",
      worktrees: [WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false)]
    )

    let merged = SessionTreeWorkflowMerge.merge(
      repos: [], repositories: [repository], decorations: index)

    #expect(merged.count == 1)
    #expect(merged[0].branches.count == 1)
    let row = merged[0].branches[0]
    #expect(row.name == "feat/empty")
    #expect(row.sessions.isEmpty)
    let decoration = index.decoration(for: row, repositoryPath: "/tmp/Repo")
    #expect(decoration?.isManual == true)
    #expect(decoration?.archivableWorkflowID == "manual:A")
  }

  @Test("A manual workflow without a branch is named after the workflow")
  func manualWorkflowWithoutBranch() {
    let manual = manualBranch(workflowID: "manual:B", repo: "/tmp/Repo", branch: nil, name: "XD-12")
    let index = BranchWorkflowDecorationIndex(branches: [manual])
    let merged = SessionTreeWorkflowMerge.merge(
      repos: [], repositories: [SelectedRepository(path: "/tmp/Repo")], decorations: index)

    #expect(merged[0].branches.map(\.name) == ["XD-12"])
    #expect(index.decoration(for: merged[0].branches[0], repositoryPath: "/tmp/Repo")?.title == "XD-12")
  }

  @Test("A manual workflow on a branch that already has sessions adds no second row")
  func manualWorkflowDoesNotDuplicate() {
    let manual = manualBranch(workflowID: "manual:A", repo: "/tmp/Repo", branch: "main")
    let index = BranchWorkflowDecorationIndex(branches: [manual])
    let existing = RepoNode(
      id: "/tmp/Repo", path: "/tmp/Repo", name: "Repo", tile: "R", attentionCount: 0,
      branches: [
        BranchNode(
          id: "/tmp/Repo||main", name: "main", worktreePath: nil, isWorktree: false,
          sessions: [], hasMore: false, visibleCount: 0)
      ])

    let merged = SessionTreeWorkflowMerge.merge(
      repos: [existing], repositories: [SelectedRepository(path: "/tmp/Repo")], decorations: index)

    #expect(merged[0].branches.count == 1)
  }

  @Test("Tracked repositories without sessions still get a header, in tracked order")
  func emptyTrackedRepository() {
    let projected = RepoNode(
      id: "/tmp/B", path: "/tmp/B", name: "B", tile: "B", attentionCount: 1, branches: [])
    let merged = SessionTreeWorkflowMerge.merge(
      repos: [projected],
      repositories: [SelectedRepository(path: "/tmp/A"), SelectedRepository(path: "/tmp/B")],
      decorations: .empty
    )

    #expect(merged.map(\.path) == ["/tmp/A", "/tmp/B"])
    #expect(merged[0].branches.isEmpty)
    #expect(merged[1].attentionCount == 1)
  }

  @Test("A workflow on a worktree root matches the tree branch through its worktree path")
  func worktreePathLookup() {
    let branch = workflowBranch(
      id: "b1", repo: "/tmp/Repo-feature/", branch: "feature", implementers: ["s1"])
    let index = BranchWorkflowDecorationIndex(branches: [branch])

    let decoration = index.decoration(
      repositoryPath: "/tmp/Repo", worktreePath: "/tmp/Repo-feature", branchName: "feature")
    #expect(decoration?.branchWorkflowID == "b1")
  }

  @Test("Only confident workflows can be archived from a branch row")
  func archivableOnlyWhenConfident() {
    let unassigned = workflowBranch(id: "b1", repo: "/tmp/Repo", branch: "a", implementers: ["s1"])
    // Two sessions on one ticket make the classifier confident.
    var ticketed = workflowBranch(
      id: "b2", repo: "/tmp/Repo", branch: "XD-7-fix", implementers: ["s2", "s3"])
    ticketed.ticketKey = "XD-7"

    let index = BranchWorkflowDecorationIndex(branches: [unassigned, ticketed])
    let first = index.decoration(repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "a")
    let second = index.decoration(
      repositoryPath: "/tmp/Repo", worktreePath: nil, branchName: "XD-7-fix")

    #expect(first?.archivableWorkflowID == nil)
    #expect(second?.archivableWorkflowID == "XD-7")
    #expect(second?.ticketKey == "XD-7")
  }
}

// MARK: - Fixtures

private func workflowBranch(
  id: String,
  repo: String,
  branch: String?,
  implementers: [String],
  implementerProvider: SessionProviderKind = .claude,
  reviewers: [(String, SessionProviderKind)] = []
) -> DetectedBranchWorkflow {
  DetectedBranchWorkflow(
    id: id,
    ticketKey: nil,
    repositoryPath: repo,
    repositoryName: URL(fileURLWithPath: repo).lastPathComponent,
    branchName: branch,
    implementerSessions: implementers.map {
      assignment($0, provider: implementerProvider, role: .implementer)
    },
    reviewerSessions: reviewers.map { assignment($0.0, provider: $0.1, role: .reviewer) },
    linkedPullRequests: [],
    pullRequest: nil,
    lastActivityAt: Date(timeIntervalSince1970: 100)
  )
}

private func manualBranch(
  workflowID: String,
  repo: String,
  branch: String?,
  name: String = "Manual"
) -> DetectedBranchWorkflow {
  DetectedBranchWorkflow(
    id: "\(workflowID)|branch",
    ticketKey: name,
    repositoryPath: repo,
    repositoryName: URL(fileURLWithPath: repo).lastPathComponent,
    branchName: branch,
    implementerSessions: [],
    reviewerSessions: [],
    linkedPullRequests: [],
    pullRequest: nil,
    lastActivityAt: Date(timeIntervalSince1970: 100),
    manualWorkflowID: workflowID
  )
}

private func assignment(
  _ sessionID: String,
  provider: SessionProviderKind,
  role: DetectedAgentRole
) -> DetectedAgentSession {
  DetectedAgentSession(
    session: CLISession(id: sessionID, projectPath: "/tmp/Repo"),
    provider: provider,
    role: role,
    roleConfidence: .high,
    roleReason: "test"
  )
}
