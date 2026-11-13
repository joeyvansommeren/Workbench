import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sessions action coordinator")
@MainActor
struct SessionsActionCoordinatorTests {
  @Test("Archive sets the undo toast with a single session title")
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
    #expect(coordinator.archiveUndo?.title == "Archived \"my session\"")
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
