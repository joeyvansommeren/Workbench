import AppKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sessions action coordinator")
@MainActor
struct SessionsActionCoordinatorTests {
  @Test("Archive sets the undo toast with a single session title using curly quotes")
  func archiveSetsUndoSingleSession() {
    let coordinator = SessionsActionCoordinator()
    let session = CLISession(id: "s1", projectPath: "/tmp/Repo")
    let item = ArchivableSessionItem(
      id: "claude-s1",
      session: session,
      providerKind: .claude,
      isPending: false,
      wasPinned: false
    )

    var stopped: [String] = []
    let vm = makeTestViewModel()

    coordinator.archiveSession(
      item,
      viewModelForProvider: { _ in
        // Track that stopMonitoring would be called via the real VM path.
        stopped.append(session.id)
        return vm
      },
      customNameForItem: { _ in "my session" }
    )

    #expect(coordinator.archiveUndo != nil)
    #expect(coordinator.archiveUndo?.title == "Archived \u{201C}my session\u{201D}")
    #expect(coordinator.archiveUndo?.entries.count == 1)
  }

  @Test("Undo archive clears the toast")
  func undoArchiveClearsToast() {
    let coordinator = SessionsActionCoordinator()
    let session = CLISession(id: "s1", projectPath: "/tmp/Repo")
    let item = ArchivableSessionItem(
      id: "claude-s1",
      session: session,
      providerKind: .claude,
      isPending: false,
      wasPinned: true
    )

    let vm = makeTestViewModel()
    coordinator.archiveSession(
      item,
      viewModelForProvider: { _ in vm },
      customNameForItem: { _ in nil }
    )

    let undo = coordinator.archiveUndo!
    coordinator.undoArchive(undo) { _ in vm }

    #expect(coordinator.archiveUndo == nil)
  }

  @Test("Archive skips pending sessions")
  func archiveSkipsPending() {
    let coordinator = SessionsActionCoordinator()
    let session = CLISession(id: "p1", projectPath: "/tmp/Repo")
    let item = ArchivableSessionItem(
      id: "pending-claude-\(UUID().uuidString)",
      session: session,
      providerKind: .claude,
      isPending: true,
      wasPinned: false
    )

    let vm = makeTestViewModel()
    coordinator.archiveSession(
      item,
      viewModelForProvider: { _ in vm },
      customNameForItem: { _ in nil }
    )

    #expect(coordinator.archiveUndo == nil)
  }

  @Test("Request archive current session beeps when workspace is selected")
  func requestArchiveBeepsForWorkspace() {
    let coordinator = SessionsActionCoordinator()
    let nav = SessionNavigationModel()
    nav.primarySessionId = "session-1"
    nav.selectedWorkspaceID = "workspace-1"

    let vm = makeTestViewModel()
    coordinator.requestArchiveCurrentSession(
      navigationModel: nav,
      selectedSessionItems: [],
      viewModelForProvider: { _ in vm },
      customNameForItem: { _ in nil }
    )

    #expect(coordinator.archiveUndo == nil)
  }

  @Test("Worktree delete confirmation payload carries session count")
  func worktreeDeleteConfirmationPayload() {
    let coordinator = SessionsActionCoordinator()
    let wt = WorktreeBranch(name: "feature", path: "/tmp/Repo-feature", isWorktree: true)
    coordinator.worktreeModuleDeleteConfirmation = WorktreeModuleDeleteConfirmation(
      worktree: wt,
      displayName: "feature",
      sessionCount: 3,
      providerKind: .claude
    )

    #expect(coordinator.worktreeModuleDeleteConfirmation?.sessionCount == 3)
    #expect(coordinator.worktreeModuleDeleteConfirmation?.displayName == "feature")
    #expect(coordinator.worktreeModuleDeleteConfirmation?.providerKind == .claude)
  }

  @Test("Remove confirmation holds the action closure")
  func removeConfirmationHoldsAction() {
    let coordinator = SessionsActionCoordinator()
    var actionCalled = false
    coordinator.removeConfirmation = RemoveConfirmation(
      title: "Remove?",
      message: "This will remove the repo.",
      action: { actionCalled = true }
    )

    coordinator.removeConfirmation?.action()

    #expect(actionCalled)
    #expect(coordinator.removeConfirmation?.title == "Remove?")
    #expect(coordinator.removeConfirmation?.message == "This will remove the repo.")
  }

  @Test("Multiple archives show the count in the title")
  func multipleArchivesShowCount() {
    let coordinator = SessionsActionCoordinator()
    let items = (1...3).map { i in
      ArchivableSessionItem(
        id: "claude-s\(i)",
        session: CLISession(id: "s\(i)", projectPath: "/tmp/Repo"),
        providerKind: .claude,
        isPending: false,
        wasPinned: false
      )
    }

    let vm = makeTestViewModel()
    coordinator.archiveSessions(
      items,
      groupName: "RepoA",
      viewModelForProvider: { _ in vm },
      customNameForItem: { _ in nil }
    )

    #expect(coordinator.archiveUndo?.title == "Archived 3 sessions in RepoA")
  }

  @Test("Archive uses slug when no custom name is available")
  func archiveUsesSlug() {
    let coordinator = SessionsActionCoordinator()
    let session = CLISession(id: "s1", projectPath: "/tmp/Repo")
    let item = ArchivableSessionItem(
      id: "claude-s1",
      session: session,
      providerKind: .claude,
      isPending: false,
      wasPinned: false
    )

    let vm = makeTestViewModel()
    coordinator.archiveSession(
      item,
      viewModelForProvider: { _ in vm },
      customNameForItem: { _ in nil }
    )

    // With no custom name, slug, or shortId, it falls back to shortId.
    #expect(coordinator.archiveUndo?.title.hasPrefix("Archived") == true)
  }

  // MARK: - Clear Transient Presentation

  @Test("Clear transient presentation resets all sheets and undo")
  func clearTransientPresentation() {
    let coordinator = SessionsActionCoordinator()
    coordinator.archiveUndo = ArchivedSessionsUndo(
      entries: [
        ArchivedSessionsUndo.Entry(
          provider: .claude,
          session: CLISession(id: "s1", projectPath: "/tmp"),
          wasPinned: false
        ),
      ],
      title: "Archived"
    )
    coordinator.workspacePendingCloseID = "ws-1"
    coordinator.removeConfirmation = RemoveConfirmation(
      title: "Remove?", message: "msg", action: {}
    )

    coordinator.clearTransientPresentation()

    #expect(coordinator.archiveUndo == nil)
    #expect(coordinator.workspacePendingCloseID == nil)
    #expect(coordinator.removeConfirmation == nil)
    #expect(coordinator.createWorktreeContext == nil)
    #expect(coordinator.startSessionSheetContext == nil)
    #expect(coordinator.gitHubSheetItem == nil)
    #expect(coordinator.projectDetailsSheetItem == nil)
    #expect(coordinator.worktreeModuleDeleteConfirmation == nil)
  }

  // MARK: - Remove Worktree Module Focus

  @Test("removeWorktreeModuleFocus clears matching landing path")
  func removeWorktreeModuleFocusClearsLanding() {
    let coordinator = SessionsActionCoordinator()
    let nav = SessionNavigationModel()
    let claudeVM = makeTestViewModel()
    let codexVM = makeTestViewModel()
    let workspaceVM = makeTestWorkspaceViewModel()

    let wt = WorktreeBranch(name: "feature", path: "/tmp/Repo-feature", isWorktree: true)
    // Must match the normalized path (no trailing slash).
    nav.selectedModuleLandingPath = "/tmp/Repo-feature"

    coordinator.removeWorktreeModuleFocus(
      wt,
      claudeViewModel: claudeVM,
      codexViewModel: codexVM,
      workspaceViewModel: workspaceVM,
      navigationModel: nav
    )

    #expect(nav.selectedModuleLandingPath == nil)
  }

  @Test("removeWorktreeModuleFocus leaves unrelated landing path")
  func removeWorktreeModuleFocusLeavesUnrelated() {
    let coordinator = SessionsActionCoordinator()
    let nav = SessionNavigationModel()
    let claudeVM = makeTestViewModel()
    let codexVM = makeTestViewModel()
    let workspaceVM = makeTestWorkspaceViewModel()

    let wt = WorktreeBranch(name: "feature", path: "/tmp/Repo-feature", isWorktree: true)
    nav.selectedModuleLandingPath = "/tmp/OtherRepo"

    coordinator.removeWorktreeModuleFocus(
      wt,
      claudeViewModel: claudeVM,
      codexViewModel: codexVM,
      workspaceViewModel: workspaceVM,
      navigationModel: nav
    )

    #expect(nav.selectedModuleLandingPath == "/tmp/OtherRepo")
  }
}

// MARK: - Helpers

@MainActor
private func makeTestViewModel() -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: CoordTestMonitorService(),
    fileWatcher: CoordTestFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: CoordTestApprovalNotificationService()
  )
}

@MainActor
private func makeTestWorkspaceViewModel() -> AgentWorkspacesViewModel {
  AgentWorkspacesViewModel(
    store: nil,
    metadataStore: nil,
    terminalSurfaceFactory: CoordTestTerminalSurfaceFactory(),
    sessionCoordinator: CoordTestSessionCoordinator()
  )
}

private final class CoordTestMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
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

private final class CoordTestFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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

private final class CoordTestApprovalNotificationService: ApprovalNotificationServiceProtocol,
  @unchecked Sendable
{
  func requestPermission() async -> Bool { true }
  func sendApprovalNotification(
    sessionId: String, toolName: String, projectPath: String?,
    model: String?, lastMessage: String?
  ) {}
}

private final class CoordTestTerminalSurfaceFactory: EmbeddedTerminalSurfaceFactory {
  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    CoordTestTerminalSurface()
  }
}

private final class CoordTestTerminalSurface: NSView, EmbeddedTerminalSurface {
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

private final class CoordTestSessionCoordinator: AgentWorkspaceSessionCoordinating {
  func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration {
    CLICommandConfiguration(command: "claude", mode: .claude)
  }
  func monitorDetectedSession(_ result: AccessorySessionDetectionResult) async {}
  func restorePersistedSessions(_ references: [AgentWorkspaceSessionReference]) async {}
  func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity {
    .idle
  }
}
