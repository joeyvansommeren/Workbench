import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session navigation model")
@MainActor
struct SessionNavigationModelTests {
  @Test("Select sets the primary session id")
  func selectSetsPrimary() {
    let model = SessionNavigationModel()
    model.primarySessionId = "session-1"
    #expect(model.primarySessionId == "session-1")
  }

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
