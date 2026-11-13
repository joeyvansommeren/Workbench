import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sidebar tree rows")
struct SidebarTreeRowsTests {
  @Test("Rows come out in tree order with load more after a paged branch")
  func treeOrder() {
    let rows = SidebarTreeRows.rows(
      repos: [repo("/tmp/A", branches: [branch("main", sessions: ["a1", "a2"], hasMore: true)])],
      collapsedRepoPaths: [],
      decorations: .empty,
      title: { $0.id.uppercased() }
    )

    #expect(rows.map(\.id) == ["repo|/tmp/A", "branch|/tmp/A|main", "a1", "a2", "more|/tmp/A|main"])
    guard case .session(let first) = rows[2], case .session(let last) = rows[3] else {
      Issue.record("expected session rows")
      return
    }
    #expect(first.title == "A1")
    #expect(first.isFirstInBranch && !first.isLastInBranch)
    #expect(last.isLastInBranch)
  }

  @Test("A collapsed repository shows only its header, with the attention count")
  func collapsedRepository() {
    let rows = SidebarTreeRows.rows(
      repos: [
        repo("/tmp/A", attention: 2, branches: [branch("main", sessions: ["a1"])]),
        repo("/tmp/B", branches: [branch("main", sessions: ["b1"])]),
      ],
      collapsedRepoPaths: ["/tmp/A"],
      decorations: .empty,
      title: { $0.id }
    )

    #expect(rows.map(\.id) == ["repo|/tmp/A", "repo|/tmp/B", "branch|/tmp/B|main", "b1"])
    guard case .repo(let header) = rows[0], case .repo(let second) = rows[1] else {
      Issue.record("expected repo rows")
      return
    }
    #expect(header.isCollapsed && header.attentionCount == 2 && header.isFirst)
    #expect(!second.isFirst)
  }

  @Test("Arrow keys walk session rows and stop at the ends")
  func adjacentSessions() {
    let rows = SidebarTreeRows.rows(
      repos: [
        repo("/tmp/A", branches: [branch("main", sessions: ["a1"]), branch("dev", sessions: ["a2"])])
      ],
      collapsedRepoPaths: [],
      decorations: .empty,
      title: { $0.id }
    )

    #expect(SidebarTreeRows.adjacentSessionID(in: rows, from: nil, forward: true) == "a1")
    #expect(SidebarTreeRows.adjacentSessionID(in: rows, from: nil, forward: false) == "a2")
    #expect(SidebarTreeRows.adjacentSessionID(in: rows, from: "a1", forward: true) == "a2")
    #expect(SidebarTreeRows.adjacentSessionID(in: rows, from: "a2", forward: true) == nil)
    #expect(SidebarTreeRows.adjacentSessionID(in: rows, from: "a1", forward: false) == nil)
    #expect(SidebarTreeRows.repositoryPath(containing: "a2", in: rows) == "/tmp/A")
  }

  @Test("Role labels appear only for a reviewed workflow")
  func roleLabels() {
    let node = SessionNode(
      id: SidebarSessionItemID.monitored(provider: .codex, sessionId: "s1"),
      session: CLISession(id: "s1", projectPath: "/tmp/A"),
      providerKind: .codex,
      isPending: false,
      status: nil
    )
    let reviewed = decoration(roles: [node.id: .reviewer])
    let implementOnly = decoration(roles: [node.id: .implementer])

    #expect(SidebarTreeRows.roleLabel(for: node, decoration: reviewed) == "Reviewer")
    #expect(SidebarTreeRows.roleLabel(for: node, decoration: implementOnly) == nil)
    #expect(SidebarTreeRows.roleLabel(for: node, decoration: nil) == nil)
  }
}

// MARK: - Fixtures

private func repo(_ path: String, attention: Int = 0, branches: [BranchNode]) -> RepoNode {
  RepoNode(
    id: path, path: path, name: URL(fileURLWithPath: path).lastPathComponent, tile: "A",
    attentionCount: attention,
    branches: branches.map {
      BranchNode(
        id: "\(path)|\($0.name)", name: $0.name, worktreePath: nil, isWorktree: false,
        sessions: $0.sessions, hasMore: $0.hasMore, visibleCount: $0.visibleCount)
    })
}

private func branch(_ name: String, sessions: [String], hasMore: Bool = false) -> BranchNode {
  BranchNode(
    id: name, name: name, worktreePath: nil, isWorktree: false,
    sessions: sessions.map {
      SessionNode(
        id: $0, session: CLISession(id: $0, projectPath: "/tmp"), providerKind: .claude,
        isPending: false, status: nil)
    },
    hasMore: hasMore, visibleCount: sessions.count)
}

private func decoration(roles: [String: DetectedAgentRole]) -> BranchWorkflowDecoration {
  BranchWorkflowDecoration(
    branchWorkflowID: "b", archivableWorkflowID: nil, repositoryPath: "/tmp/A", branchName: "main",
    title: "main", ticketKey: nil, isManual: false, pullRequest: nil, roles: roles,
    reviewProvider: nil, canCompare: false)
}
