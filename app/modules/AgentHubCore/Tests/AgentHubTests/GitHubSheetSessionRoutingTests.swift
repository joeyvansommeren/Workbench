import Combine
import Testing

@testable import AgentHubCore

@MainActor
struct GitHubSheetSessionRoutingTests {
  @Test func routesToExplicitProviderWhenIDsCollide() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "shared", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    codex.startMonitoring(session: session)
    let claudeSurface = WorkspaceTerminalSurfaceSpy()
    let codexSurface = WorkspaceTerminalSurfaceSpy()
    claudeSurface.acceptsImmediatePrompt = true
    codexSurface.acceptsImmediatePrompt = true
    claude.activeTerminals[session.id] = claudeSurface
    codex.activeTerminals[session.id] = codexSurface
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    for provider in [SessionProviderKind.claude, .codex] {
      navigation.selectSession(
        SidebarSessionItemID.monitored(provider: provider, sessionId: session.id))
      let item = GitHubSheetItem(
        projectPath: session.projectPath, branchName: session.branchName,
        session: session, provider: provider)
      coordinator.gitHubSheetItem = item
      let send = try #require(
        coordinator.gitHubSendToSession(
          item: item, claudeViewModel: claude, codexViewModel: codex,
          workspaceViewModel: workspaces, navigationModel: navigation))
      let targetSurface = provider == .claude ? claudeSurface : codexSurface
      let otherSurface = provider == .claude ? codexSurface : claudeSurface
      let otherSubmissions = otherSurface.immediatePrompts.count
      coordinator.gitHubSendError = true
      send("prompt", session)
      await coordinator.gitHubSendTask?.value
      #expect(!coordinator.gitHubSendError)
      let target = provider == .claude ? claude : codex
      let other = provider == .claude ? codex : claude
      #expect(targetSurface.immediatePrompts == ["prompt"])
      #expect(otherSurface.immediatePrompts.count == otherSubmissions)
      #expect(target.pendingPrompt(for: session.id) == nil)
      #expect(other.pendingPrompt(for: session.id) == nil)
    }
  }

  @Test(arguments: [false, true])
  func unavailableTerminalNeverQueuesContext(mounted: Bool) async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = WorkspaceTerminalSurfaceSpy()
    if mounted { claude.activeTerminals[session.id] = surface }
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(coordinator.gitHubSendError)
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(claude.activeTerminals.count == (mounted ? 1 : 0))
    #expect(surface.immediatePrompts.isEmpty)
  }

  @Test(arguments: [1, 2], [SessionProviderKind.claude, .codex])
  func persistedOwnersBlockStandaloneLookingSheet(
    ownerCount: Int, ownerProvider: SessionProviderKind
  ) async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "shared", projectPath: "/tmp/project", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    claude.activeTerminals[session.id] = surface
    let owners = try (0..<ownerCount).map { try makeWorkspace(id: "owner-\($0)") }
    let store = WorkspaceStoreSpy(
      workspaces: owners,
      links: owners.map {
        AgentWorkspaceSessionLink(
          workspaceId: $0.id, provider: ownerProvider, sessionId: session.id, origin: .explicit)
      })
    let workspaces = makeWorkspaceTestViewModel(
      store: store, surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    #expect(navigation.selectedWorkspaceID == nil)
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    #expect(item.workspaceID == nil)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(coordinator.gitHubSendError == (ownerProvider == .claude))
    #expect(surface.immediatePrompts == (ownerProvider == .claude ? [] : ["prompt"]))
    #expect(claude.pendingPrompt(for: session.id) == nil)
  }

  @Test func rejectsMissingAndChangedIdentity() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = acceptingSurface(for: session, in: claude)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    for item in [
      GitHubSheetItem(projectPath: "/fixture"),
      GitHubSheetItem(projectPath: "/fixture", branchName: "feature", session: session),
      GitHubSheetItem(
        projectPath: "/other", branchName: "feature", session: session, provider: .claude),
      GitHubSheetItem(
        projectPath: "/fixture", branchName: "other", session: session, provider: .claude),
    ] {
      let action = coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation)
      if item.session == nil {
        #expect(action == nil)
      } else {
        coordinator.gitHubSheetItem = item
        action?("prompt", session)
        await coordinator.gitHubSendTask?.value
        #expect(coordinator.gitHubSendError)
        #expect(surface.immediatePrompts.isEmpty)
        coordinator.gitHubSendError = false
      }
    }
    let item = GitHubSheetItem(
      projectPath: "/fixture", branchName: "feature", session: session, provider: .claude)
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    for changed in [
      CLISession(id: "other", projectPath: "/fixture", branchName: "feature"),
      CLISession(id: "session", projectPath: "/other", branchName: "feature"),
      CLISession(id: "session", projectPath: "/fixture", branchName: "other"),
    ] {
      send("prompt", changed)
      await coordinator.gitHubSendTask?.value
      #expect(coordinator.gitHubSendError)
      #expect(surface.immediatePrompts.isEmpty)
    }
    #expect(claude.pendingPrompt(for: session.id) == nil)
    claude.stopMonitoring(session: session)
    claude.activeTerminals[session.id] = surface
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(surface.immediatePrompts.isEmpty)
    #expect(coordinator.gitHubSendError)
  }

  @Test func workspacePromptFailsWithoutTouchingTerminal() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "shared", projectPath: "/tmp/project", branchName: "feature")
    claude.startMonitoring(session: session)
    codex.startMonitoring(session: session)
    let claudeSurface = acceptingSurface(for: session, in: claude)
    let codexSurface = acceptingSurface(for: session, in: codex)
    let workspace = try collidingWorkspace(for: session)
    let store = WorkspaceStoreSpy(
      workspaces: [workspace],
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id, provider: .claude, sessionId: session.id, origin: .explicit),
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id, provider: .codex, sessionId: session.id, origin: .explicit),
      ])
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    let workspaces = makeWorkspaceTestViewModel(store: store, surface: surface)
    await workspaces.load()
    _ = workspaces.terminalSurface(for: workspace.id, isDark: true)
    let navigation = SessionNavigationModel()
    navigation.selectedWorkspaceID = workspace.id
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude, workspaceID: workspace.id)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    #expect(coordinator.gitHubSendTask == nil)
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(codex.pendingPrompt(for: session.id) == nil)
    #expect(coordinator.gitHubSendError)
    #expect(claudeSurface.immediatePrompts.isEmpty)
    #expect(codexSurface.immediatePrompts.isEmpty)
    #expect(surface.immediatePrompts.isEmpty)
    #expect(coordinator.gitHubSendErrorMessage.contains("can’t verify"))
  }

  @Test func duplicateWorkspaceOwnersDoNotReceivePrompt() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "shared", projectPath: "/tmp/project", branchName: "feature")
    claude.startMonitoring(session: session)
    let standaloneSurface = acceptingSurface(for: session, in: claude)
    let first = try makeWorkspace(id: "first")
    let second = try makeWorkspace(id: "second")
    let store = WorkspaceStoreSpy(
      workspaces: [first, second],
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: first.id, provider: .claude,
          sessionId: session.id, origin: .explicit),
        AgentWorkspaceSessionLink(
          workspaceId: second.id, provider: .claude,
          sessionId: session.id, origin: .explicit),
      ])
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    let workspaces = makeWorkspaceTestViewModel(store: store, surface: surface)
    await workspaces.load()
    _ = workspaces.terminalSurface(for: first.id, isDark: true)
    let navigation = SessionNavigationModel()
    navigation.selectedWorkspaceID = first.id
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude, workspaceID: first.id)
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    #expect(coordinator.gitHubSendTask == nil)
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(coordinator.gitHubSendError)
    #expect(standaloneSurface.immediatePrompts.isEmpty)
    #expect(surface.immediatePrompts.isEmpty)
  }

  @Test func changedLiveBranchDoesNotQueuePrompt() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "old")
    claude.startMonitoring(session: session)
    let surface = acceptingSurface(for: session, in: claude)
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "new" })
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    coordinator.gitHubSheetItem = item
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(surface.immediatePrompts.isEmpty)
    #expect(coordinator.gitHubSendError)
  }

  @Test func changedSelectionDuringBranchLookupDoesNotQueuePrompt() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = acceptingSurface(for: session, in: claude)
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    var observedPath = ""
    let coordinator = SessionsActionCoordinator(currentBranch: { path in
      await MainActor.run {
        observedPath = path
        navigation.selectSession("codex-other")
      }
      return "feature"
    })
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(observedPath == session.projectPath)
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(surface.immediatePrompts.isEmpty)
    #expect(coordinator.gitHubSendError)
  }

  @Test(arguments: ["fresh", "failedOwnership", "unavailableBranch"])
  func ownershipLoadsBeforeSendingAndFailuresStayBlocked(availability: String) async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = acceptingSurface(for: session, in: claude)
    let store = WorkspaceStoreSpy()
    if availability == "failedOwnership" { await store.failLoads() }
    let workspaces = makeWorkspaceTestViewModel(
      store: store, surface: WorkspaceTerminalSurfaceSpy())
    if availability == "failedOwnership" { await workspaces.load() }
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in
      if availability == "unavailableBranch" { throw RoutingTestError.unavailable }
      return "feature"
    })
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    let previousSubmissions = surface.immediatePrompts
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(workspaces.hasLoadedWorkspaceOwnership == (availability != "failedOwnership"))
    #expect(coordinator.gitHubSendError == (availability != "fresh"))
    #expect(surface.immediatePrompts == (
      availability == "fresh" ? previousSubmissions + ["prompt"] : previousSubmissions))
    #expect(claude.pendingPrompt(for: session.id) == nil)
  }

  @Test func workspaceRejectionCancelsEarlierSend() async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = acceptingSurface(for: session, in: claude)
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let workspaces = makeWorkspaceTestViewModel(
      store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let gate = BranchLookupGate()
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in try await gate.wait() })
    let standalone = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    coordinator.gitHubSheetItem = standalone
    let first = try #require(
      coordinator.gitHubSendToSession(
        item: standalone, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    first("old", session)
    let oldTask = coordinator.gitHubSendTask
    await gate.waitUntilStarted()
    let workspace = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude, workspaceID: "workspace")
    let second = try #require(
      coordinator.gitHubSendToSession(
        item: workspace, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    second("new", session)
    gate.finish("feature")
    await oldTask?.value
    #expect(coordinator.gitHubSendTask == nil)
    #expect(coordinator.gitHubSendError)
    #expect(claude.pendingPrompt(for: session.id) == nil)
    #expect(surface.immediatePrompts.isEmpty)
  }

  @Test func obsoleteSheetCannotReportAnErrorAfterBranchLookup() async throws {
    for action in ["dismiss", "replace", "reset"] {
      let claude = makeViewModel(.claude)
      let codex = makeViewModel(.codex)
      let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
      claude.startMonitoring(session: session)
      let surface = acceptingSurface(for: session, in: claude)
      let navigation = SessionNavigationModel()
      navigation.selectSession(
        SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
      let workspaces = makeWorkspaceTestViewModel(
        store: WorkspaceStoreSpy(), surface: WorkspaceTerminalSurfaceSpy())
      await workspaces.load()
      let gate = BranchLookupGate()
      let coordinator = SessionsActionCoordinator(currentBranch: { _ in try await gate.wait() })
      let original = GitHubSheetItem(
        projectPath: session.projectPath, branchName: session.branchName,
        session: session, provider: .claude)
      coordinator.gitHubSheetItem = original
      let send = try #require(
        coordinator.gitHubSendToSession(
          item: original, claudeViewModel: claude, codexViewModel: codex,
          workspaceViewModel: workspaces, navigationModel: navigation))
      send("prompt", session)
      let task = coordinator.gitHubSendTask
      await gate.waitUntilStarted()
      if action == "reset" {
        coordinator.gitHubSendError = true
        coordinator.clearTransientPresentation()
      } else if action == "replace" {
        coordinator.gitHubSheetItem = GitHubSheetItem(projectPath: "/another")
      } else {
        coordinator.gitHubSheetItem = nil
      }
      gate.finish("feature")
      await task?.value
      #expect(!coordinator.gitHubSendError, "unexpected error after \(action)")
      #expect(claude.pendingPrompt(for: session.id) == nil)
      #expect(surface.immediatePrompts.isEmpty)
      if action == "reset" { #expect(coordinator.gitHubSendTask == nil) }
      if action == "replace" { #expect(coordinator.gitHubSheetItem?.projectPath == "/another") }
    }
  }

  @Test(arguments: [false, true])
  func failedOwnershipLoadRetriesBeforeSending(failedLinks: Bool) async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    claude.activeTerminals[session.id] = surface
    let store = WorkspaceStoreSpy()
    await store.failLoads(links: failedLinks)
    let workspaces = makeWorkspaceTestViewModel(
      store: store, surface: WorkspaceTerminalSurfaceSpy())
    await workspaces.load()
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    coordinator.gitHubSheetItem = item
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(coordinator.gitHubSendError)
    #expect(!workspaces.hasLoadedWorkspaceOwnership)
    #expect(surface.immediatePrompts.isEmpty)
    #expect(claude.pendingPrompt(for: session.id) == nil)

    await store.recoverLoads()
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(!coordinator.gitHubSendError)
    #expect(workspaces.hasLoadedWorkspaceOwnership)
    #expect(workspaces.errorMessage == nil)
    #expect(surface.immediatePrompts == ["prompt"])
    #expect(claude.pendingPrompt(for: session.id) == nil)
  }

  @Test(arguments: ["dismiss", "selection"])
  func identityChangesDuringOwnershipLoadPreventDelivery(action: String) async throws {
    let claude = makeViewModel(.claude)
    let codex = makeViewModel(.codex)
    let session = CLISession(id: "session", projectPath: "/fixture", branchName: "feature")
    claude.startMonitoring(session: session)
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    claude.activeTerminals[session.id] = surface
    let navigation = SessionNavigationModel()
    navigation.selectSession(
      SidebarSessionItemID.monitored(provider: .claude, sessionId: session.id))
    let item = GitHubSheetItem(
      projectPath: session.projectPath, branchName: session.branchName,
      session: session, provider: .claude)
    let coordinator = SessionsActionCoordinator(currentBranch: { _ in "feature" })
    coordinator.gitHubSheetItem = item
    let store = WorkspaceStoreSpy()
    var loadObserved = false
    await store.onNextLoad {
      loadObserved = true
      if action == "dismiss" {
        coordinator.gitHubSheetItem = nil
      } else {
        navigation.selectSession("codex-other")
      }
    }
    let workspaces = makeWorkspaceTestViewModel(
      store: store, surface: WorkspaceTerminalSurfaceSpy())
    let send = try #require(
      coordinator.gitHubSendToSession(
        item: item, claudeViewModel: claude, codexViewModel: codex,
        workspaceViewModel: workspaces, navigationModel: navigation))
    send("prompt", session)
    await coordinator.gitHubSendTask?.value
    #expect(loadObserved)
    #expect(workspaces.hasLoadedWorkspaceOwnership)
    #expect(coordinator.gitHubSendError == (action == "selection"))
    #expect(surface.immediatePrompts.isEmpty)
    #expect(claude.pendingPrompt(for: session.id) == nil)
  }

  private func collidingWorkspace(for session: CLISession) throws -> AgentWorkspaceRecord {
    try AgentWorkspaceRecord(
      id: "workspace", projectPath: session.projectPath,
      snapshot: TerminalWorkspaceSnapshot(panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(
              role: .agent, workingDirectory: session.projectPath,
              linkedSession: TerminalWorkspaceLinkedSessionSnapshot(
                provider: .claude, sessionId: session.id)),
            TerminalWorkspaceTabSnapshot(
              role: .agent, workingDirectory: session.projectPath,
              linkedSession: TerminalWorkspaceLinkedSessionSnapshot(
                provider: .codex, sessionId: session.id)),
          ])
      ]))
  }

  private func acceptingSurface(
    for session: CLISession, in viewModel: CLISessionsViewModel
  ) -> WorkspaceTerminalSurfaceSpy {
    let surface = WorkspaceTerminalSurfaceSpy()
    surface.acceptsImmediatePrompt = true
    viewModel.activeTerminals[session.id] = surface
    return surface
  }

  private func makeViewModel(_ provider: SessionProviderKind) -> CLISessionsViewModel {
    let vm = CLISessionsViewModel(
      monitorService: RoutingMonitor(), fileWatcher: RoutingWatcher(), searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider, approvalNotificationService: NoOpApprovalNotificationService(),
      cliAvailabilityService: CLIAvailabilityService(findExecutable: { _, _, _ in nil }))
    vm.workspaceStateReadOverride = { _ in SessionWorkspaceState() }
    return vm
  }
}

private actor RoutingMonitor: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}
private final class RoutingWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    Empty<SessionFileWatcher.StateUpdate, Never>().eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

private enum RoutingTestError: Error { case unavailable }

@MainActor
private final class BranchLookupGate {
  private var lookup: CheckedContinuation<String, any Error>?
  private var started: CheckedContinuation<Void, Never>?

  func wait() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      lookup = continuation
      started?.resume()
      started = nil
    }
  }

  func waitUntilStarted() async {
    if lookup != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func finish(_ branch: String) {
    lookup?.resume(returning: branch)
    lookup = nil
  }
}
