import AppKit
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

  @Test("Accessibility hierarchy follows visible repository and branch ownership")
  func accessibilityHierarchy() {
    let rows = SidebarTreeRows.rows(
      repos: [
        repo("/tmp/A", branches: [branch("main", sessions: ["a1"], hasMore: true)]),
        repo("/tmp/B", branches: [branch("dev", sessions: ["b1"])]),
      ],
      collapsedRepoPaths: [],
      decorations: .empty,
      title: { $0.id }
    )
    let hierarchy = SidebarTreeRows.accessibilityHierarchy(rows)
    #expect(hierarchy.map(\.level) == [0, 1, 2, 2, 0, 1, 2])
    #expect(
      hierarchy.map(\.parentID) == [
        nil, "repo|/tmp/A", "branch|/tmp/A|main", "branch|/tmp/A|main",
        nil, "repo|/tmp/B", "branch|/tmp/B|dev",
      ])
  }

  @Test("Session accessibility uses the projected display title")
  func accessibilityUsesProjectedTitle() {
    let rows = SidebarTreeRows.rows(
      repos: [repo("/tmp/A", branches: [branch("feature/branch", sessions: ["a1"])])],
      collapsedRepoPaths: [],
      decorations: .empty,
      title: { _ in "Ticket title chosen by the view model" }
    )
    guard case .session(let session) = rows.last else {
      Issue.record("expected a session row")
      return
    }
    #expect(session.sidebarAccessibilityLabel.hasPrefix("Ticket title chosen by the view model, "))
  }

  @MainActor
  @Test("Outline keeps visible row identity across updates")
  func outlineRowIdentity() {
    let outline = SidebarTreeAccessibilityOutline()
    let repository = SidebarTreeAccessibilityRow(id: "repo", parentID: nil, level: 0)
    let branch = SidebarTreeAccessibilityRow(id: "branch", parentID: "repo", level: 1)
    let session = SidebarTreeAccessibilityRow(id: "session", parentID: "branch", level: 2)
    outline.update([repository, branch, session])
    let first = outline.rows[0]
    let selected = outline.rows[2]
    outline.selectedID = "session"
    let selectedRow = outline.accessibilitySelectedRows()?.first as? SidebarTreeAccessibilityElement
    let parent = selected.accessibilityDisclosedByRow() as? SidebarTreeAccessibilityElement
    #expect(selectedRow === selected)
    #expect(parent === outline.rows[1])
    let oldAnchor = NSView()
    let newAnchor = NSView()
    outline.registerAnchor(oldAnchor, for: "session")
    outline.registerAnchor(newAnchor, for: "session")
    outline.unregisterAnchor(oldAnchor, for: "session")
    #expect(selected.anchor === newAnchor)
    outline.unregisterAnchor(newAnchor, for: "session")
    #expect(selected.anchor == nil)
    outline.update([repository])
    #expect(outline.rows[0] === first)
    #expect(!selected.isActive)
    #expect(!selected.isAccessibilityElement())
    #expect(!selected.isAccessibilitySelected())
    #expect(outline.accessibilitySelectedRows()?.isEmpty == true)
    outline.update([repository, branch, session])
    #expect(outline.rows[2] === selected)
    #expect(selected.isActive)
  }

  @MainActor
  @Test("Offscreen outline actions fail closed and result callbacks unregister safely")
  func outlineActionsFailClosed() {
    let row = SidebarTreeAccessibilityElement(id: "session")
    var performed = false
    let command = SidebarMenuCommand(id: "test", title: "Test", systemImage: "checkmark") {
      performed = true
    }
    row.commands = [.command(command), .separator]
    #expect(row.accessibilityCustomActions()?.map(\.name) == ["Test"])
    #expect(!row.accessibilityPerformShowMenu())
    #expect(!row.performCommand(id: command.id))
    #expect(!performed)

    let registry = SidebarTreeAccessibilityRegistry()
    let old = SidebarTreeAccessibilityRowCallbacks()
    let current = SidebarTreeAccessibilityRowCallbacks()
    current.showResult = { performed = true }
    registry.register(old, for: "session")
    registry.register(current, for: "session")
    registry.unregister(old, for: "session")
    #expect(registry.showResult(for: "session"))
    #expect(performed)
    registry.unregister(current, for: "session")
    #expect(!registry.showResult(for: "session"))
    func registerTemporaryCallbacks() {
      let temporary = SidebarTreeAccessibilityRowCallbacks()
      registry.register(temporary, for: "session")
    }
    registerTemporaryCallbacks()
    #expect(!registry.hasCallbacks(for: "session"))
  }

  @MainActor
  @Test("Inactive rows cannot disclose, select, or request focus")
  func inactiveRowSetters() {
    let outline = SidebarTreeAccessibilityOutline()
    let row = SidebarTreeAccessibilityElement(id: "session")
    var effects = 0
    row.owner = outline
    row.canExpand = true
    row.onDisclosure = { _ in effects += 1 }
    row.onFocus = { effects += 1 }
    outline.onSelect = { _ in effects += 1 }
    row.setAccessibilityDisclosed(true)
    row.setAccessibilitySelected(true)
    row.setAccessibilityFocused(true)
    #expect(effects == 0)
    row.isActive = true
    row.setAccessibilityFocused(true)
    #expect(effects == 1)
  }

  @MainActor
  @Test("A menu action resolves the latest command and rejects stale actions")
  func refreshedMenuActions() {
    var invoked = ""
    let old = SidebarMenuCommand(id: "reviewResult", title: "Review result", systemImage: "doc") {
      invoked = "old"
    }
    let current = SidebarMenuCommand(
      id: "reviewResult", title: "Read result", systemImage: "doc.text"
    ) { invoked = "current" }
    #expect(performSidebarMenuCommand(id: old.id, entries: [.command(current)], isVisible: true))
    #expect(invoked == "current")
    invoked = ""
    #expect(!performSidebarMenuCommand(id: old.id, entries: [], isVisible: true))
    let disabled = SidebarMenuCommand(
      id: "reviewResult", title: "Review result", systemImage: "doc", isAvailable: { false },
      action: { invoked = "disabled" })
    #expect(!performSidebarMenuCommand(id: old.id, entries: [.command(disabled)], isVisible: true))
    #expect(!performSidebarMenuCommand(id: old.id, entries: [.command(current)], isVisible: false))
    let changedContext = SidebarMenuCommand(
      id: "startReview|Codex", title: "Start Review with Codex", systemImage: "checkmark"
    ) { invoked = "changed context" }
    #expect(
      !performSidebarMenuCommand(
        id: "startReview|Claude", entries: [.command(changedContext)], isVisible: true))
    #expect(invoked.isEmpty)
  }

  @MainActor
  @Test("Outline exposes approval detail and the current sending phase")
  func outlineApprovalDetailAndPhase() {
    let actions = SidebarActionSpy()
    actions.presentation = ApprovalRequestPresentation(toolName: "Bash", input: "swift test")
    let node = SessionNode(
      id: "approval", session: CLISession(id: "approval", projectPath: "/tmp/fixture"),
      providerKind: .claude, isPending: false, status: nil, pendingToolName: "Bash")
    let model = SessionRowModel(
      node: node, title: "Fixture task", roleLabel: nil,
      isFirstInBranch: true, isLastInBranch: true)
    let outline = SidebarTreeAccessibilityOutline()
    outline.configure(
      rows: [.session(model)], selectedID: nil, sessionsByRepo: [:],
      sessionsByBranch: [:], registry: SidebarTreeAccessibilityRegistry(), actions: actions,
      onLoadMore: { _ in }, onFocus: { _ in })
    let row = outline.rows[0]
    #expect(row.accessibilityLabel()?.contains("Review request: swift test") == true)
    #expect((row.accessibilityValue() as? String) != "Sending")
    actions.phase = .sending(.approveOnce)
    #expect((row.accessibilityValue() as? String) == "Sending")
    actions.phase = .answered(.approveOnce)
    #expect((row.accessibilityValue() as? String) == "Sending")
    actions.phase = .checkTerminal
    #expect((row.accessibilityValue() as? String) != "Sending")
    actions.presentation = nil
    #expect(row.accessibilityLabel()?.contains("Review request: Bash") == true)
    #expect(row.accessibilityLabel()?.contains("swift test") == false)
  }

  @MainActor
  @Test("Removing an outline row releases captured payload and preserves its identity")
  func outlineReleasesRemovedRowPayload() {
    let outline = SidebarTreeAccessibilityOutline()
    let entry = SidebarTreeAccessibilityRow(id: "session", parentID: nil, level: 2)
    let child = SidebarTreeAccessibilityRow(id: "child", parentID: "session", level: 3)
    outline.update([entry, child])
    let row = outline.rows[0]
    #expect(row.childRows.count == 1)
    weak var weakSentinel: SidebarRetentionSentinel?
    func installCapturedPayload() {
      let sentinel = SidebarRetentionSentinel()
      weakSentinel = sentinel
      row.label = "private fixture text"
      outline.onSelect = { _ in _ = sentinel }
      row.onFocus = { _ = sentinel }
      row.approvalAccessibility = {
        _ = sentinel
        return ("Review request", "Sending")
      }
      row.onPress = {
        _ = sentinel
        return true
      }
      row.onDisclosure = { _ in _ = sentinel }
      row.commands = [
        .command(
          SidebarMenuCommand(id: "test", title: "Test", systemImage: "checkmark") {
            _ = sentinel
          })
      ]
    }
    installCapturedPayload()
    #expect(weakSentinel != nil)
    outline.update([])
    #expect(weakSentinel == nil)
    #expect(row.commands.isEmpty)
    #expect(row.label.isEmpty)
    #expect(row.childRows.isEmpty)
    outline.update([entry])
    #expect(outline.rows[0] === row)
    #expect(row.isActive)
    #expect(row.commands.isEmpty)
  }

  @MainActor
  @Test("Real menu factories expose their conditional commands and route Open")
  func actualMenuFactoryConditions() {
    let actions = SidebarActionSpy()
    let claude = SessionNode(
      id: "claude", session: CLISession(id: "claude", projectPath: "/tmp/fixture"),
      providerKind: .claude, isPending: false, status: nil)
    let codex = SessionNode(
      id: "codex", session: CLISession(id: "codex", projectPath: "/tmp/fixture"),
      providerKind: .codex, isPending: false, status: nil)
    let pending = SessionNode(
      id: "pending", session: CLISession(id: "pending", projectPath: "/tmp/fixture"),
      providerKind: .claude, isPending: true, status: nil)
    func ids(_ entries: [SidebarMenuEntry]) -> [String] {
      entries.compactMap {
        guard case .command(let command) = $0 else { return nil }
        return command.id
      }
    }
    let claudeEntries = sessionMenuEntries(node: claude, actions: actions, onShowResult: {})
    #expect(
      ids(claudeEntries) == [
        "open", "reviewResult", "copySessionID", "viewTranscript",
        "openInTerminal", "fork", "archive",
      ])
    #expect(
      !ids(sessionMenuEntries(node: codex, actions: actions, onShowResult: {})).contains(
        "openInTerminal"))
    #expect(
      ids(sessionMenuEntries(node: pending, actions: actions, onShowResult: {})) == [
        "open", "cancelLaunch",
      ])
    #expect(performSidebarMenuCommand(id: "open", entries: claudeEntries, isVisible: true))
    #expect(actions.opened == ["claude"])
    let repoModel = RepoHeaderRowModel(
      path: "/tmp/fixture", name: "Fixture", isCollapsed: false,
      attentionCount: 0, isFirst: true)
    #expect(
      !ids(repositoryMenuEntries(model: repoModel, sessions: [], actions: actions)).contains(
        "archiveSessions"))
    #expect(
      ids(repositoryMenuEntries(model: repoModel, sessions: [claude], actions: actions)).contains(
        "archiveSessions"))
    let branchModel = BranchRowModel(
      id: "branch", repositoryPath: "/tmp/fixture", repositoryName: "Fixture",
      name: "main", worktreePath: nil, isWorktree: false, isFirstInRepo: true, decoration: nil)
    #expect(
      !ids(branchMenuEntries(model: branchModel, sessions: [], actions: actions)).contains(
        "deleteWorktree"))
    let workflow = BranchWorkflowDecoration(
      branchWorkflowID: "workflow", archivableWorkflowID: "workflow",
      repositoryPath: "/tmp/fixture", branchName: "main", title: "main", ticketKey: "TES-1",
      isManual: false, pullRequest: nil, roles: [:], reviewProvider: .codex, canCompare: true)
    let worktree = BranchRowModel(
      id: "worktree", repositoryPath: "/tmp/fixture", repositoryName: "Fixture",
      name: "main", worktreePath: "/tmp/fixture-worktree", isWorktree: true, isFirstInRepo: true,
      decoration: workflow)
    #expect(
      ids(branchMenuEntries(model: worktree, sessions: [claude], actions: actions)) == [
        "newSessionOnBranch", "startReview|Codex", "compare", "openTicket", "archiveWorkflow",
        "openInFinder", "archiveSessions", "removeWorktree", "deleteWorktree",
      ])
  }

  @MainActor
  @Test("Outline configuration routes visible tree callbacks through existing actions")
  func outlineConfigurationRoutesActions() {
    let actions = SidebarActionSpy()
    let rows = SidebarTreeRows.rows(
      repos: [repo("/tmp/A", branches: [branch("main", sessions: ["a1"], hasMore: true)])],
      collapsedRepoPaths: [], decorations: .empty, title: { $0.id })
    let outline = SidebarTreeAccessibilityOutline()
    var loaded: [String] = []
    var focused: [String] = []
    outline.configure(
      rows: rows, selectedID: "a1", sessionsByRepo: [:], sessionsByBranch: [:],
      registry: SidebarTreeAccessibilityRegistry(), actions: actions,
      onLoadMore: { loaded.append($0.branchID) }, onFocus: { focused.append($0) })
    outline.rows[0].onDisclosure(true)
    #expect(actions.repositoryChanges == ["/tmp/A|expanded"])
    #expect(outline.rows[2].onPress())
    outline.onSelect("a1")
    outline.onSelect("not-present")
    #expect(actions.opened == ["a1", "a1"])
    outline.rows[2].setAccessibilityFocused(true)
    #expect(focused == ["a1"])
    #expect(outline.rows[3].onPress())
    #expect(loaded == ["/tmp/A|main"])
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
    let hierarchy = SidebarTreeRows.accessibilityHierarchy(rows)
    #expect(hierarchy.map(\.parentID) == [nil, nil, "repo|/tmp/B", "branch|/tmp/B|main"])
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

  @Test("Provider marks account for sessions beyond the loaded page")
  func mixedProvidersBeyondPage() {
    let rows = SidebarTreeRows.rows(
      repos: [repo("/tmp/A", branches: [branch("main", sessions: ["one"], hasMore: true)])],
      collapsedRepoPaths: [], decorations: .empty, title: { $0.id },
      providersByBranch: ["/tmp/A|main": [.claude, .codex]])
    guard case .session(let row) = rows[2] else { Issue.record("missing session"); return }
    #expect(row.showProvider)
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

@MainActor
private final class SidebarActionSpy: SidebarTreeActionHandling {
  var phase: ApprovalResponsePhase?
  var presentation: ApprovalRequestPresentation?
  var opened: [String] = []
  var repositoryChanges: [String] = []
  func approvalPhase(for node: SessionNode) -> ApprovalResponsePhase? { phase }
  func approvalPresentation(for node: SessionNode) -> ApprovalRequestPresentation? { presentation }
  func open(_ node: SessionNode) { opened.append(node.id) }
  func setRepository(_ model: RepoHeaderRowModel, collapsed: Bool) {
    repositoryChanges.append(model.path + (collapsed ? "|collapsed" : "|expanded"))
  }
  func startSession(at path: String) {}
  func startSession(onBranch model: BranchRowModel) {}
  func createWorktree(repositoryPath: String) {}
  func createWorkspace(projectPath: String) {}
  func showProjectDetails(path: String, name: String) {}
  func showGitHub(path: String) {}
  func openInFinder(path: String) {}
  func archiveSessions(_ nodes: [SessionNode], groupName: String) {}
  func requestRemoveRepository(path: String, name: String, sessionCount: Int) {}
  func requestRemoveWorktree(_ branch: BranchRowModel, sessions: [SessionNode]) {}
  func requestDeleteWorktree(_ branch: BranchRowModel, sessions: [SessionNode]) {}
  func startReview(_ decoration: BranchWorkflowDecoration) {}
  func compare(_ decoration: BranchWorkflowDecoration) {}
  func openPullRequest(_ decoration: BranchWorkflowDecoration) {}
  func openTicket(_ decoration: BranchWorkflowDecoration) {}
  func archiveWorkflow(_ decoration: BranchWorkflowDecoration) {}
  func copySessionID(_ node: SessionNode) {}
  func viewTranscript(_ node: SessionNode) {}
  func openInTerminal(_ node: SessionNode) {}
  func fork(_ node: SessionNode) {}
  func archive(_ node: SessionNode) {}
}

private final class SidebarRetentionSentinel {}
