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
    let snapshot = SessionTreeSnapshot(
      repos: [
        repo("/tmp/A", branches: [branch("main", sessions: ["a1"]), branch("dev", sessions: ["a2"])])
      ],
      collapsedRepoPaths: [],
      decorations: .empty,
      title: { $0.id }
    )
    let next = { (id: String?, forward: Bool) in
      SidebarTreeRows.adjacentSessionID(
        in: snapshot.rows, from: id, forward: forward,
        repoPathBySessionID: snapshot.repoPathBySessionID)
    }

    #expect(next(nil, true) == "a1")
    #expect(next(nil, false) == "a2")
    #expect(next("a1", true) == "a2")
    #expect(next("a2", true) == nil)
    #expect(next("a1", false) == nil)
  }

  @Test("A collapsed repo still knows the selected session, so Right can expand it again")
  func collapseThenExpandFindsRepository() {
    let repos = [
      repo("/tmp/A", branches: [branch("main", sessions: ["a1"])]),
      repo("/tmp/B", branches: [branch("main", sessions: ["b1"])]),
    ]
    let collapsed = SessionTreeSnapshot(
      repos: repos, collapsedRepoPaths: ["/tmp/A"], decorations: .empty, title: { $0.id })

    // "a1" has no visible row, but its repository is still known.
    #expect(!collapsed.rows.contains { $0.id == "a1" })
    #expect(collapsed.repoPathBySessionID["a1"] == "/tmp/A")
  }

  @Test("Up and Down continue from the collapsed repository's header")
  func arrowsAfterCollapse() {
    let repos = [
      repo("/tmp/A", branches: [branch("main", sessions: ["a1"])]),
      repo("/tmp/B", branches: [branch("main", sessions: ["b1", "b2"])]),
      repo("/tmp/C", branches: [branch("main", sessions: ["c1"])]),
    ]
    let snapshot = SessionTreeSnapshot(
      repos: repos, collapsedRepoPaths: ["/tmp/B"], decorations: .empty, title: { $0.id })
    let next = { (id: String?, forward: Bool) in
      SidebarTreeRows.adjacentSessionID(
        in: snapshot.rows, from: id, forward: forward,
        repoPathBySessionID: snapshot.repoPathBySessionID)
    }

    // "b2" is hidden in collapsed B: Down goes to C, Up goes back to A.
    #expect(next("b2", true) == "c1")
    #expect(next("b2", false) == "a1")
  }

  @Test("Menus and counts use every session, not only the loaded page")
  func unpagedSessionsForMenus() {
    let allSessions = (0..<8).map { "s\($0)" }
    let paged = [repo("/tmp/A", branches: [branch("main", sessions: Array(allSessions.prefix(5)), hasMore: true)])]
    let unpaged = [repo("/tmp/A", branches: [branch("main", sessions: allSessions)])]

    let snapshot = SessionTreeSnapshot(
      repos: paged, unpagedRepos: unpaged, collapsedRepoPaths: [], decorations: .empty,
      title: { $0.id })

    let sessionRows = snapshot.rows.filter { if case .session = $0 { return true } else { return false } }
    #expect(sessionRows.count == 5)
    #expect(snapshot.sessionsByRepo["/tmp/A"]?.count == 8)
    #expect(snapshot.sessionsByBranch["/tmp/A|main"]?.count == 8)
    #expect(snapshot.repoPathBySessionID["s7"] == "/tmp/A")
  }

  @Test("The unpaged projection keeps every session in its branch")
  func unpagedProjection() {
    let repository = SelectedRepository(path: "/tmp/Repo")
    let items = (0..<8).map { index in
      ProjectableSessionItem(
        id: "s\(index)",
        session: CLISession(id: "s\(index)", projectPath: "/tmp/Repo", branchName: "main"),
        providerKind: .claude,
        timestamp: Date(timeIntervalSince1970: Double(100 - index)),
        isPending: false,
        status: nil
      )
    }

    let paged = SessionTreeProjection.project(items: items, repositories: [repository])
    let unpaged = SessionTreeProjection.project(items: items, repositories: [repository], paged: false)

    #expect(paged[0].branches[0].sessions.count == 5)
    #expect(unpaged[0].branches[0].sessions.count == 8)
    #expect(!unpaged[0].branches[0].hasMore)
    #expect(unpaged[0].branches[0].id == paged[0].branches[0].id)
  }

  @Test("A workspace-owned session stays highlighted while its workspace is shown")
  func workspaceHighlight() {
    let open = SidebarWorkspaceOpen(sessionRowID: "claude-s1", workspaceID: "ws1")

    #expect(
      SidebarTreeSelection.highlightedSessionID(
        primarySessionId: nil, selectedWorkspaceID: "ws1", lastWorkspaceOpen: open) == "claude-s1")
    // Another workspace is shown: the old row is not highlighted.
    #expect(
      SidebarTreeSelection.highlightedSessionID(
        primarySessionId: nil, selectedWorkspaceID: "ws2", lastWorkspaceOpen: open) == nil)
    // A standalone session wins.
    #expect(
      SidebarTreeSelection.highlightedSessionID(
        primarySessionId: "codex-s2", selectedWorkspaceID: nil, lastWorkspaceOpen: open)
        == "codex-s2")
    #expect(
      SidebarTreeSelection.highlightedSessionID(
        primarySessionId: nil, selectedWorkspaceID: nil, lastWorkspaceOpen: open) == nil)
  }

  @Test("Arrow keys continue from the highlighted workspace session")
  func arrowsFromWorkspaceSession() {
    let snapshot = SessionTreeSnapshot(
      repos: [repo("/tmp/A", branches: [branch("main", sessions: ["s1", "s2", "s3"])])],
      collapsedRepoPaths: [], decorations: .empty, title: { $0.id })
    let highlighted = SidebarTreeSelection.highlightedSessionID(
      primarySessionId: nil, selectedWorkspaceID: "ws1",
      lastWorkspaceOpen: SidebarWorkspaceOpen(sessionRowID: "s2", workspaceID: "ws1"))

    #expect(
      SidebarTreeRows.adjacentSessionID(
        in: snapshot.rows, from: highlighted, forward: true,
        repoPathBySessionID: snapshot.repoPathBySessionID) == "s3")
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
