import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session tree projection")
struct SessionTreeProjectionTests {
  @Test("Groups sessions by repo and branch")
  func groupsByRepoAndBranch() {
    let repo = SelectedRepository(
      path: "/tmp/RepoA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/RepoA", isWorktree: false),
        WorktreeBranch(name: "feature", path: "/tmp/RepoA-feature", isWorktree: true),
      ]
    )

    let items = [
      projectable("s1", projectPath: "/tmp/RepoA", branchName: "main", timestamp: 300),
      projectable("s2", projectPath: "/tmp/RepoA-feature", branchName: "feature", timestamp: 200),
      projectable("s3", projectPath: "/tmp/RepoA", branchName: "main", timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree.count == 1)
    #expect(tree[0].name == "RepoA")
    #expect(tree[0].branches.count == 2)
    #expect(tree[0].branches[0].name == "main")
    #expect(tree[0].branches[0].sessions.count == 2)
    #expect(tree[0].branches[0].sessions[0].id == "s1")
    #expect(tree[0].branches[0].sessions[1].id == "s3")
    #expect(tree[0].branches[1].name == "feature")
    #expect(tree[0].branches[1].sessions.count == 1)
    #expect(tree[0].branches[1].sessions[0].id == "s2")
  }

  @Test("Worktree sessions under the parent repo")
  func worktreeSessionsUnderParent() {
    let repo = SelectedRepository(
      path: "/tmp/Repo",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false),
        WorktreeBranch(name: "fix", path: "/tmp/Repo-fix", isWorktree: true),
      ]
    )

    let items = [
      projectable("s1", projectPath: "/tmp/Repo-fix", branchName: "fix", timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree.count == 1)
    #expect(tree[0].path == "/tmp/Repo")
    #expect(tree[0].branches.count == 1)
    #expect(tree[0].branches[0].name == "fix")
    #expect(tree[0].branches[0].isWorktree == true)
  }

  @Test("Nested launchPath resolves to the worktree root")
  func nestedLaunchPathResolvesToWorktreeRoot() {
    let repo = SelectedRepository(
      path: "/tmp/Repo",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false),
        WorktreeBranch(name: "deep", path: "/tmp/Repo-deep", isWorktree: true),
      ]
    )

    let items = [
      projectable(
        "s1",
        projectPath: "/tmp/Repo-deep/ios/App",
        branchName: "deep",
        timestamp: 100
      ),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree.count == 1)
    #expect(tree[0].branches[0].worktreePath == "/tmp/Repo-deep")
  }

  @Test("Sessions with no branch go in the 'No branch' bucket")
  func noBranchBucket() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    let items = [
      projectable("s1", projectPath: "/tmp/Repo", branchName: nil, timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree[0].branches[0].name == SessionTreeProjection.noBranchName)
  }

  @Test("Ordering sorts sessions newest-first within a branch")
  func orderingNewestFirst() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    let items = [
      projectable("old", projectPath: "/tmp/Repo", branchName: "main", timestamp: 100),
      projectable("new", projectPath: "/tmp/Repo", branchName: "main", timestamp: 300),
      projectable("mid", projectPath: "/tmp/Repo", branchName: "main", timestamp: 200),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])
    let ids = tree[0].branches[0].sessions.map(\.id)

    #expect(ids == ["new", "mid", "old"])
  }

  @Test("Paging shows 5 sessions per page")
  func pagingShowsFivePerPage() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    var items: [ProjectableSessionItem] = []
    for i in 0..<12 {
      items.append(
        projectable("s\(i)", projectPath: "/tmp/Repo", branchName: "main", timestamp: Double(100 - i))
      )
    }

    let tree1 = SessionTreeProjection.project(items: items, repositories: [repo])
    #expect(tree1[0].branches[0].sessions.count == 5)
    #expect(tree1[0].branches[0].hasMore == true)
    #expect(tree1[0].branches[0].visibleCount == 5)

    let branchId = tree1[0].branches[0].id
    let tree2 = SessionTreeProjection.project(
      items: items,
      repositories: [repo],
      loadedPages: [branchId: 2]
    )
    #expect(tree2[0].branches[0].sessions.count == 10)
    #expect(tree2[0].branches[0].hasMore == true)

    let tree3 = SessionTreeProjection.project(
      items: items,
      repositories: [repo],
      loadedPages: [branchId: 3]
    )
    #expect(tree3[0].branches[0].sessions.count == 12)
    #expect(tree3[0].branches[0].hasMore == false)
  }

  @Test("Attention count on a collapsed repo")
  func attentionCountOnCollapsedRepo() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    let items = [
      projectable(
        "approval",
        projectPath: "/tmp/Repo",
        branchName: "main",
        timestamp: 200,
        status: .awaitingApproval(tool: "Bash")
      ),
      projectable(
        "working",
        projectPath: "/tmp/Repo",
        branchName: "main",
        timestamp: 100,
        status: .thinking
      ),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree[0].attentionCount == 1)
  }

  @Test("Multiple repos produce separate nodes")
  func multipleRepos() {
    let repoA = SelectedRepository(path: "/tmp/RepoA")
    let repoB = SelectedRepository(path: "/tmp/RepoB")
    let items = [
      projectable("a1", projectPath: "/tmp/RepoA", branchName: "main", timestamp: 200),
      projectable("b1", projectPath: "/tmp/RepoB", branchName: "main", timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repoA, repoB])

    #expect(tree.count == 2)
    #expect(tree[0].name == "RepoA")
    #expect(tree[1].name == "RepoB")
  }

  @Test("Tile is the first letter uppercased")
  func tileIsFirstLetter() {
    let repo = SelectedRepository(path: "/tmp/workbench")
    let items = [
      projectable("s1", projectPath: "/tmp/workbench", branchName: "main", timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree[0].tile == "W")
  }

  // MARK: - Duplicate branch names across worktrees

  @Test("Duplicate branch names in different worktrees get distinct branch node ids")
  func duplicateBranchNamesDistinctIds() {
    let repo = SelectedRepository(
      path: "/tmp/Repo",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false),
        WorktreeBranch(name: "main", path: "/tmp/Repo-wt", isWorktree: true),
      ]
    )

    let items = [
      projectable("s1", projectPath: "/tmp/Repo", branchName: "main", timestamp: 200),
      projectable("s2", projectPath: "/tmp/Repo-wt", branchName: "main", timestamp: 100),
    ]

    let tree = SessionTreeProjection.project(items: items, repositories: [repo])

    #expect(tree.count == 1)
    #expect(tree[0].branches.count == 2)
    // Both have the name "main" but different ids.
    #expect(tree[0].branches[0].id != tree[0].branches[1].id)
    #expect(tree[0].branches[0].name == "main")
    #expect(tree[0].branches[1].name == "main")
  }

  // MARK: - loadedPages clamping

  @Test("loadedPages of 0 or negative is clamped to 1 page")
  func loadedPagesClampedToOne() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    var items: [ProjectableSessionItem] = []
    for i in 0..<8 {
      items.append(
        projectable("s\(i)", projectPath: "/tmp/Repo", branchName: "main", timestamp: Double(100 - i))
      )
    }

    let tree1 = SessionTreeProjection.project(items: items, repositories: [repo])
    let branchId = tree1[0].branches[0].id

    // loadedPages = 0 should still show 1 page (5 sessions)
    let tree0 = SessionTreeProjection.project(
      items: items,
      repositories: [repo],
      loadedPages: [branchId: 0]
    )
    #expect(tree0[0].branches[0].sessions.count == 5)

    // loadedPages = -1 should also be clamped
    let treeNeg = SessionTreeProjection.project(
      items: items,
      repositories: [repo],
      loadedPages: [branchId: -1]
    )
    #expect(treeNeg[0].branches[0].sessions.count == 5)
  }

  // MARK: - Approve pill

  @Test("The projection carries the pending tool name to the session node")
  func pendingToolNamePassesThrough() {
    let repo = SelectedRepository(path: "/tmp/Repo")
    let item = ProjectableSessionItem(
      id: "s1",
      session: CLISession(id: "s1", projectPath: "/tmp/Repo", branchName: "main"),
      providerKind: .claude,
      timestamp: Date(timeIntervalSince1970: 100),
      isPending: false,
      status: .awaitingApproval(tool: "Bash"),
      pendingToolName: "Bash"
    )

    let tree = SessionTreeProjection.project(items: [item], repositories: [repo])

    #expect(tree[0].branches[0].sessions[0].pendingToolName == "Bash")
    #expect(tree[0].branches[0].sessions[0].showsApprovePill)
  }

  @Test("Approve pill: Claude with a pending tool use that is a real approval")
  func approvePillForClaudeApproval() {
    #expect(pillNode(provider: .claude, pendingToolName: "Bash").showsApprovePill)
    #expect(pillNode(provider: .claude, pendingToolName: "Edit").showsApprovePill)
  }

  @Test("No Approve pill without a pending tool use")
  func noPillWithoutPendingTool() {
    #expect(!pillNode(provider: .claude, pendingToolName: nil).showsApprovePill)
  }

  @Test("No Approve pill for Codex")
  func noPillForCodex() {
    #expect(!pillNode(provider: .codex, pendingToolName: "Bash").showsApprovePill)
  }

  @Test("No Approve pill when the agent waits for input, not approval")
  func noPillForInteractiveInput() {
    #expect(!pillNode(provider: .claude, pendingToolName: "AskUserQuestion").showsApprovePill)
    #expect(
      !pillNode(provider: .claude, pendingToolName: "mcp__codex__request_user_input")
        .showsApprovePill)
  }

  @Test("No Approve pill on a session that is still starting")
  func noPillWhilePending() {
    #expect(!pillNode(provider: .claude, pendingToolName: "Bash", isPending: true).showsApprovePill)
  }

  @Test("Answer pill when the agent asks a question, for Claude and Codex")
  func answerPillForInputQuestions() {
    let claude = pillNode(provider: .claude, pendingToolName: "AskUserQuestion")
    #expect(claude.showsAnswerPill)
    #expect(!claude.showsApprovePill)
    // Codex has no pending tool use; the status alone carries the question.
    let codex = SessionNode(
      id: "c1", session: CLISession(id: "c1", projectPath: "/tmp/Repo"), providerKind: .codex,
      isPending: false, status: .awaitingApproval(tool: "request_user_input"))
    #expect(codex.showsAnswerPill)
  }

  @Test("No Answer pill for approvals, other states, or a session still starting")
  func noAnswerPill() {
    #expect(!pillNode(provider: .claude, pendingToolName: "Bash").showsAnswerPill)
    #expect(!pillNode(provider: .claude, pendingToolName: nil).showsAnswerPill)
    #expect(!pillNode(provider: .claude, pendingToolName: "AskUserQuestion", isPending: true).showsAnswerPill)
  }
}

// MARK: - Helpers

private func pillNode(
  provider: SessionProviderKind,
  pendingToolName: String?,
  isPending: Bool = false
) -> SessionNode {
  SessionNode(
    id: "s1",
    session: CLISession(id: "s1", projectPath: "/tmp/Repo"),
    providerKind: provider,
    isPending: isPending,
    status: pendingToolName.map { .awaitingApproval(tool: $0) },
    pendingToolName: pendingToolName
  )
}

private func projectable(
  _ id: String,
  projectPath: String,
  branchName: String?,
  timestamp: TimeInterval,
  status: SessionStatus? = nil
) -> ProjectableSessionItem {
  ProjectableSessionItem(
    id: id,
    session: CLISession(id: id, projectPath: projectPath, branchName: branchName),
    providerKind: .claude,
    timestamp: Date(timeIntervalSince1970: timestamp),
    isPending: false,
    status: status
  )
}
