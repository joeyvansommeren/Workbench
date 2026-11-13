import AppKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session navigation model")
@MainActor
struct SessionNavigationModelTests {
  // MARK: - History Navigation

  @Test("History navigation wraps forward")
  func historyNavigationWrapsForward() {
    let model = SessionNavigationModel()
    model.primarySessionId = "c"
    model.navigateSessionHistory(
      direction: .forward,
      navigableIDs: ["a", "b", "c"]
    )
    #expect(model.primarySessionId == "a")
    #expect(model.scrollToSessionId == "a")
  }

  @Test("History navigation wraps backward")
  func historyNavigationWrapsBackward() {
    let model = SessionNavigationModel()
    model.primarySessionId = "a"
    model.navigateSessionHistory(
      direction: .backward,
      navigableIDs: ["a", "b", "c"]
    )
    #expect(model.primarySessionId == "c")
    #expect(model.scrollToSessionId == "c")
  }

  @Test("History navigation with no current picks first")
  func historyNavigationNoCurrentPicksFirst() {
    let model = SessionNavigationModel()
    model.primarySessionId = nil
    model.navigateSessionHistory(
      direction: .forward,
      navigableIDs: ["a", "b"]
    )
    #expect(model.primarySessionId == "a")
  }

  @Test("History navigation reopens workflow comparison")
  func historyNavigationReopensComparison() {
    let model = SessionNavigationModel()
    let comparison = workflowComparison()
    model.workflowComparisonState.retainAndPresent(comparison)
    model.workflowComparisonState.showStandaloneContent()
    model.primarySessionId = "other"

    model.navigateSessionHistory(
      direction: .forward,
      navigableIDs: ["other", comparison.implementation.itemID]
    )

    #expect(model.workflowComparisonState.presentedComparison == comparison)
    #expect(model.primarySessionId == comparison.implementation.itemID)
  }

  // MARK: - Pending → Resolved

  @Test("Pending-to-resolved swap updates the primary id")
  func pendingToResolvedSwap() {
    let model = SessionNavigationModel()
    let pendingUUID = UUID()
    model.primarySessionId = "pending-claude-\(pendingUUID.uuidString)"

    let vm = makeTestViewModel()
    vm.resolvedPendingSessions[pendingUUID] = "real-session-123"

    model.handleResolvedSessions(
      vm.resolvedPendingSessions,
      provider: .claude,
      viewModel: vm
    )

    #expect(model.primarySessionId == "claude-real-session-123")
    #expect(vm.resolvedPendingSessions.isEmpty)
  }

  @Test("Pending-to-resolved ignores mismatched provider")
  func pendingToResolvedIgnoresMismatch() {
    let model = SessionNavigationModel()
    let pendingUUID = UUID()
    model.primarySessionId = "pending-claude-\(pendingUUID.uuidString)"

    let vm = makeTestViewModel()
    vm.resolvedPendingSessions[pendingUUID] = "real-session-123"

    model.handleResolvedSessions(
      vm.resolvedPendingSessions,
      provider: .codex,
      viewModel: vm
    )

    #expect(model.primarySessionId == "pending-claude-\(pendingUUID.uuidString)")
    #expect(!vm.resolvedPendingSessions.isEmpty)
  }

  // MARK: - Ensure Primary Selection

  @Test("Ensure primary selection picks first item when none selected")
  func ensurePrimarySelectionPicksFirst() {
    let model = SessionNavigationModel()
    model.primarySessionId = nil

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
        SessionItemSnapshot(id: "b", providerKind: .codex, sessionId: "s2", isPending: false),
      ],
      hasRouterRequest: false
    )

    #expect(model.primarySessionId == "a")
  }

  @Test("Ensure primary selection retains valid selection")
  func ensurePrimarySelectionRetainsValid() {
    let model = SessionNavigationModel()
    model.primarySessionId = "b"

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
        SessionItemSnapshot(id: "b", providerKind: .codex, sessionId: "s2", isPending: false),
      ],
      hasRouterRequest: false
    )

    #expect(model.primarySessionId == "b")
  }

  @Test("Ensure primary selection clears when module landing is active")
  func ensurePrimarySelectionClearsForModuleLanding() {
    let model = SessionNavigationModel()
    model.primarySessionId = "a"
    model.selectedModuleLandingPath = "/tmp/Repo"

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
      ],
      hasRouterRequest: false
    )

    #expect(model.primarySessionId == nil)
  }

  @Test("Ensure primary selection clears when router request is pending")
  func ensurePrimarySelectionClearsForRouterRequest() {
    let model = SessionNavigationModel()
    model.primarySessionId = "a"

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
      ],
      hasRouterRequest: true
    )

    #expect(model.primarySessionId == nil)
  }

  @Test("Ensure primary selection resets when current is not in items")
  func ensurePrimarySelectionResetsWhenMissing() {
    let model = SessionNavigationModel()
    model.primarySessionId = "gone"

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "x", providerKind: .claude, sessionId: "s1", isPending: false),
      ],
      hasRouterRequest: false
    )

    #expect(model.primarySessionId == "x")
  }

  @Test("Ensure primary selection gives nil for empty items")
  func ensurePrimarySelectionNilForEmpty() {
    let model = SessionNavigationModel()
    model.primarySessionId = "stale"

    model.ensurePrimarySelection(items: [], hasRouterRequest: false)

    #expect(model.primarySessionId == nil)
  }

  @Test("Ensure primary selection gives nil when workspace is set")
  func ensurePrimarySelectionNilForWorkspace() {
    let model = SessionNavigationModel()
    model.primarySessionId = "a"
    model.selectedWorkspaceID = "ws-1"

    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
      ],
      hasRouterRequest: false
    )

    #expect(model.primarySessionId == nil)
  }

  @Test("Ensure primary selection keeps id when list swaps but still contains it")
  func ensurePrimarySelectionKeepsAcrossSwap() {
    let model = SessionNavigationModel()
    model.primarySessionId = "b"

    // First list
    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "a", providerKind: .claude, sessionId: "s1", isPending: false),
        SessionItemSnapshot(id: "b", providerKind: .claude, sessionId: "s2", isPending: false),
      ],
      hasRouterRequest: false
    )
    #expect(model.primarySessionId == "b")

    // Swap to a different list that still has "b"
    model.ensurePrimarySelection(
      items: [
        SessionItemSnapshot(id: "c", providerKind: .codex, sessionId: "s3", isPending: false),
        SessionItemSnapshot(id: "b", providerKind: .claude, sessionId: "s2", isPending: false),
      ],
      hasRouterRequest: false
    )
    #expect(model.primarySessionId == "b")
  }

  // MARK: - Comparison

  @Test("Comparison retain and close round-trip")
  func comparisonRetainAndClose() {
    let model = SessionNavigationModel()
    let comparison = workflowComparison()

    model.workflowComparisonState.retainAndPresent(comparison)
    #expect(model.workflowComparisonState.presentedComparison == comparison)

    model.closeWorkflowComparison(router: nil)
    #expect(model.workflowComparisonState.retainedComparison == nil)
    #expect(model.workflowComparisonState.presentedComparison == nil)
  }

  // MARK: - Selection Helpers

  @Test("Select pending session sets the pending item id")
  func selectPendingSession() {
    let model = SessionNavigationModel()
    let pendingID = UUID()

    model.selectPendingSession(provider: .codex, pendingID: pendingID)

    #expect(model.primarySessionId == "pending-codex-\(pendingID.uuidString)")
    #expect(model.selectedWorkspaceID == nil)
  }

  @Test("Select empty module clears session selection")
  func selectEmptyModuleClearsSession() {
    let model = SessionNavigationModel()
    model.primarySessionId = "session-1"
    model.selectedWorkspaceID = "workspace-1"

    model.selectEmptyModule("/tmp/Repo")

    #expect(model.primarySessionId == nil)
    #expect(model.selectedModuleLandingPath == "/tmp/Repo")
    #expect(model.selectedWorkspaceID == nil)
  }

  @Test("Select session clears module landing and workspace")
  func selectSessionClearsOtherSelections() {
    let model = SessionNavigationModel()
    model.selectedModuleLandingPath = "/tmp/Repo"
    model.selectedWorkspaceID = "workspace-1"

    model.selectSession("claude-abc")

    #expect(model.primarySessionId == "claude-abc")
    #expect(model.selectedModuleLandingPath == nil)
    #expect(model.selectedWorkspaceID == nil)
  }

  // MARK: - Consume Global Session Selection

  @Test("Consume session selection routes and marks consumed")
  func consumeSessionSelectionConsumed() {
    let model = SessionNavigationModel()
    let router = GlobalSessionSelectionRouter(defaults: .init(suiteName: "test-\(UUID())")!)
    let session = CLISession(id: "s1", projectPath: "/tmp/Repo")
    router.select(
      providerKind: .claude, sessionId: "s1",
      projectPath: "/tmp/Repo", session: session
    )

    let vm = makeTestViewModel()
    let consumed = model.consumeGlobalSessionSelectionIfNeeded(
      router: router,
      claudeViewModel: vm,
      codexViewModel: makeTestViewModel(),
      workspaceViewModel: makeTestWorkspaceViewModel(),
      selectedSessionItems: {
        [SessionItemSnapshot(id: "claude-s1", providerKind: .claude, sessionId: "s1", isPending: false)]
      },
      colorScheme: .dark,
      setAuxiliaryShellVisible: { _ in },
      selectedProviderRawSetter: { _ in }
    )

    #expect(consumed)
    #expect(router.selectionRequest == nil)
    #expect(model.primarySessionId == "claude-s1")
  }

  @Test("Consume session selection returns false when item absent")
  func consumeSessionSelectionAbsentReturnsFalse() {
    let model = SessionNavigationModel()
    let router = GlobalSessionSelectionRouter(defaults: .init(suiteName: "test-\(UUID())")!)
    router.select(
      providerKind: .claude, sessionId: "missing",
      projectPath: "/tmp/Repo"
    )

    let consumed = model.consumeGlobalSessionSelectionIfNeeded(
      router: router,
      claudeViewModel: makeTestViewModel(),
      codexViewModel: makeTestViewModel(),
      workspaceViewModel: makeTestWorkspaceViewModel(),
      selectedSessionItems: { [] },
      colorScheme: .light,
      setAuxiliaryShellVisible: { _ in },
      selectedProviderRawSetter: { _ in }
    )

    #expect(!consumed)
    // Request stays so a later call with the item present can consume it.
    #expect(router.selectionRequest != nil)
  }

  // MARK: - Consume Global Workflow Comparison

  @Test("Consume workflow comparison routes and marks consumed")
  func consumeWorkflowComparisonConsumed() {
    let model = SessionNavigationModel()
    let router = GlobalSessionSelectionRouter(defaults: .init(suiteName: "test-\(UUID())")!)
    let comparison = workflowComparison()
    router.compare(comparison)

    let claudeVM = makeTestViewModel()
    let codexVM = makeTestViewModel()

    let consumed = model.consumeGlobalWorkflowComparisonIfNeeded(
      router: router,
      claudeViewModel: claudeVM,
      codexViewModel: codexVM,
      availableItemIDs: {
        Set([comparison.implementation.itemID, comparison.review.itemID])
      }
    )

    #expect(consumed)
    #expect(router.comparisonRequest == nil)
    #expect(model.workflowComparisonState.presentedComparison == comparison)
  }

  @Test("Consume workflow comparison returns false when items absent")
  func consumeWorkflowComparisonAbsentReturnsFalse() {
    let model = SessionNavigationModel()
    let router = GlobalSessionSelectionRouter(defaults: .init(suiteName: "test-\(UUID())")!)
    let comparison = workflowComparison()
    router.compare(comparison)

    let consumed = model.consumeGlobalWorkflowComparisonIfNeeded(
      router: router,
      claudeViewModel: makeTestViewModel(),
      codexViewModel: makeTestViewModel(),
      availableItemIDs: { Set<String>() }
    )

    #expect(!consumed)
  }

  // MARK: - Transient State

  @Test("Clear transient navigation resets scroll and refresh flag")
  func clearTransientNavigation() {
    let model = SessionNavigationModel()
    model.scrollToSessionId = "session-1"
    model.didScheduleInitialGitHubStateRefresh = true

    model.clearTransientNavigation()

    #expect(model.scrollToSessionId == nil)
    #expect(model.didScheduleInitialGitHubStateRefresh == false)
  }
}

// MARK: - Helpers

private func workflowComparison() -> WorkflowSessionComparisonRequest {
  WorkflowSessionComparisonRequest(
    id: UUID(uuidString: "E61601BE-9907-41D4-9645-3DC1755941DB")!,
    workflowID: "workflow",
    title: "XFA-1234",
    implementation: WorkflowSessionComparisonTarget(
      providerKind: .codex,
      session: CLISession(id: "implementation", projectPath: "/tmp/Repo")
    ),
    review: WorkflowSessionComparisonTarget(
      providerKind: .claude,
      session: CLISession(id: "review", projectPath: "/tmp/Repo")
    )
  )
}

@MainActor
private func makeTestViewModel() -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: NavTestMonitorService(),
    fileWatcher: NavTestFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NavTestApprovalNotificationService()
  )
}

@MainActor
private func makeTestWorkspaceViewModel() -> AgentWorkspacesViewModel {
  AgentWorkspacesViewModel(
    store: nil,
    metadataStore: nil,
    terminalSurfaceFactory: NavTestTerminalSurfaceFactory(),
    sessionCoordinator: NavTestSessionCoordinator()
  )
}

private final class NavTestMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class NavTestFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

private final class NavTestApprovalNotificationService: ApprovalNotificationServiceProtocol,
  @unchecked Sendable
{
  func requestPermission() async -> Bool { true }
  func sendApprovalNotification(
    sessionId: String, toolName: String, projectPath: String?,
    model: String?, lastMessage: String?
  ) {}
}

private final class NavTestTerminalSurfaceFactory: EmbeddedTerminalSurfaceFactory {
  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    NavTestTerminalSurface()
  }
}

private final class NavTestTerminalSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {}
  func configure(
    sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?, initialInputText: String?, launchContext: String?,
    isDark: Bool, dangerouslySkipPermissions: Bool, permissionModePlan: Bool,
    worktreeName: String?, metadataStore: SessionMetadataStore?
  ) {}
  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {}
  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {}
  func terminateProcess() {}
  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { false }
  func typeText(_ text: String) {}
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
}

private final class NavTestSessionCoordinator: AgentWorkspaceSessionCoordinating {
  func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration {
    CLICommandConfiguration(command: "claude", mode: .claude)
  }
  func monitorDetectedSession(_ result: AccessorySessionDetectionResult) async {}
  func restorePersistedSessions(_ references: [AgentWorkspaceSessionReference]) async {}
  func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity {
    .idle
  }
}
