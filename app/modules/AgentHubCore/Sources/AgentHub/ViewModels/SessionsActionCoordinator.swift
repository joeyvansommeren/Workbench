//
//  SessionsActionCoordinator.swift
//  AgentHub
//
//  Actions extracted from MultiProviderSessionsListView so both the legacy
//  and new shell can share archive, remove, delete, new-session and fork flows.
//

import AgentHubGitHub
import AppKit
import Foundation
import SwiftUI

// MARK: - Confirmation payloads

/// Payload for the "Remove repository?" confirmation alert.
struct RemoveConfirmation {
  let title: String
  let message: String
  let action: () -> Void
}

/// Payload for the "Delete worktree?" confirmation alert.
struct WorktreeModuleDeleteConfirmation {
  let worktree: WorktreeBranch
  let displayName: String
  let sessionCount: Int
  let providerKind: SessionProviderKind
}

/// Context for presenting the "Create worktree" sheet.
struct WorktreeCreateContext: Identifiable {
  let id = UUID()
  let providerKind: SessionProviderKind
  let repository: SelectedRepository
}

/// Context for presenting the "Start session" sheet.
struct StartSessionSheetContext: Identifiable {
  let id = UUID()
  let launchViewModel: MultiSessionLaunchViewModel
}

/// Context for presenting the GitHub panel sheet.
struct GitHubSheetItem: Identifiable {
  let id = UUID()
  let projectPath: String
  var branchName: String? = nil
  var session: CLISession? = nil
  var provider: SessionProviderKind? = nil
  var workspaceID: String? = nil
  var linkedPullRequests: [GitHubPullRequestURLReference] = []
}

/// Context for presenting the project details sheet.
struct ProjectDetailsSheetItem: Identifiable {
  let id = UUID()
  let projectPath: String
  let displayName: String
}

/// Context for presenting the session file sheet. Named with a `Coordinator`
/// suffix to avoid shadowing the private `SessionFileSheetItem` structs that
/// exist in `MonitoringPanelView` and `MultiProviderSessionsListView`.
struct CoordinatorSessionFileSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

// MARK: - SessionsActionCoordinator

/// Coordinates session and repository actions: archive/undo, remove, delete
/// worktree, new session, fork, create worktree, and sheet presentation.
///
/// The coordinator is `@Observable` so SwiftUI can bind directly to its
/// presentation state.
@MainActor
@Observable
final class SessionsActionCoordinator {
  // MARK: - Presentation State

  var sessionFileSheetItem: CoordinatorSessionFileSheetItem?
  /// Set when View Transcript could not read the session file; shown as an alert.
  var sessionFileError: String?
  /// The transcript read in flight. A new request or `clearTransientPresentation` cancels it.
  @ObservationIgnored private(set) var sessionFileTask: Task<Void, Never>?
  var createWorktreeContext: WorktreeCreateContext?
  var startSessionSheetContext: StartSessionSheetContext?
  var gitHubSheetItem: GitHubSheetItem?
  var gitHubSendError = false
  var gitHubSendErrorMessage =
    "The session or its terminal is no longer available. Open the session and try again."
  @ObservationIgnored private(set) var gitHubSendTask: Task<Void, Never>?
  var attentionResultRequestID: String?
  var projectDetailsSheetItem: ProjectDetailsSheetItem?
  var archiveUndo: ArchivedSessionsUndo?
  var removeConfirmation: RemoveConfirmation?
  var worktreeModuleDeleteConfirmation: WorktreeModuleDeleteConfirmation?
  var workspacePendingCloseID: String?
  /// The new shell's New session sheet. Window-level, so leaving Sessions
  /// does not clear it; the legacy shell never sets it.
  var newSessionSheetRequest: NewSessionSheetRequest?

  // MARK: - Init

  private let currentBranch: (String) async throws -> String

  init(
    currentBranch: @escaping (String) async throws -> String = {
      try await GitWorktreeService().getCurrentBranch(at: $0)
    }
  ) {
    self.currentBranch = currentBranch
  }

  // MARK: - Transient State

  /// Resets all sheet, alert and undo state so stale presentation does not
  /// resurface when the Sessions view re-enters the tree.
  func clearTransientPresentation() {
    archiveUndo = nil
    createWorktreeContext = nil
    startSessionSheetContext = nil
    gitHubSheetItem = nil
    gitHubSendTask?.cancel()
    gitHubSendTask = nil
    gitHubSendError = false
    gitHubSendErrorMessage =
      "The session or its terminal is no longer available. Open the session and try again."
    attentionResultRequestID = nil
    projectDetailsSheetItem = nil
    sessionFileSheetItem = nil
    sessionFileTask?.cancel()
    sessionFileTask = nil
    sessionFileError = nil
    removeConfirmation = nil
    worktreeModuleDeleteConfirmation = nil
    workspacePendingCloseID = nil
  }

  // MARK: - Archive

  /// Archives sessions immediately; the undo toast is the safety net.
  func archiveSession(
    _ item: ArchivableSessionItem,
    viewModelForProvider: (SessionProviderKind) -> CLISessionsViewModel,
    customNameForItem: (ArchivableSessionItem) -> String?
  ) {
    archiveSessions(
      [item],
      groupName: nil,
      viewModelForProvider: viewModelForProvider,
      customNameForItem: customNameForItem
    )
  }

  func archiveSessions(
    _ items: [ArchivableSessionItem],
    groupName: String?,
    viewModelForProvider: (SessionProviderKind) -> CLISessionsViewModel,
    customNameForItem: (ArchivableSessionItem) -> String?
  ) {
    let archivable = items.filter { !$0.isPending }
    guard !archivable.isEmpty else { return }
    let entries = archivable.map {
      ArchivedSessionsUndo.Entry(
        provider: $0.providerKind, session: $0.session, wasPinned: $0.wasPinned)
    }
    withAnimation(.easeInOut(duration: 0.25)) {
      for item in archivable {
        viewModelForProvider(item.providerKind).stopMonitoring(session: item.session)
      }
    }
    let title: String
    if archivable.count == 1, let item = archivable.first {
      let name = customNameForItem(item) ?? item.session.slug ?? item.session.shortId
      title = "Archived \u{201C}\(name)\u{201D}"
    } else {
      title = "Archived \(archivable.count) sessions\(groupName.map { " in \($0)" } ?? "")"
    }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      archiveUndo = ArchivedSessionsUndo(entries: entries, title: title)
    }
  }

  func undoArchive(
    _ undo: ArchivedSessionsUndo,
    viewModelForProvider: (SessionProviderKind) -> CLISessionsViewModel
  ) {
    withAnimation(.easeInOut(duration: 0.25)) {
      for entry in undo.entries {
        viewModelForProvider(entry.provider)
          .restoreArchivedSession(entry.session, wasPinned: entry.wasPinned)
      }
      archiveUndo = nil
    }
  }

  /// Handles the archive notification.
  func requestArchiveCurrentSession(
    navigationModel: SessionNavigationModel,
    selectedSessionItems: [ArchivableSessionItem],
    viewModelForProvider: (SessionProviderKind) -> CLISessionsViewModel,
    customNameForItem: (ArchivableSessionItem) -> String?
  ) {
    guard
      navigationModel.selectedWorkspaceID == nil,
      let primaryId = navigationModel.primarySessionId,
      let item = selectedSessionItems.first(where: { $0.id == primaryId }),
      !item.isPending
    else {
      NSSound.beep()
      return
    }
    archiveSession(
      item,
      viewModelForProvider: viewModelForProvider,
      customNameForItem: customNameForItem
    )
  }

  // MARK: - Worktree Delete

  func deleteWorktreeModule(
    _ confirmation: WorktreeModuleDeleteConfirmation,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) {
    worktreeModuleDeleteConfirmation = nil
    Task { @MainActor in
      let viewModel = confirmation.providerKind == .claude ? claudeViewModel : codexViewModel
      let succeeded = await viewModel.deleteWorktree(confirmation.worktree)
      if succeeded {
        removeWorktreeModuleFocus(
          confirmation.worktree,
          claudeViewModel: claudeViewModel,
          codexViewModel: codexViewModel,
          workspaceViewModel: workspaceViewModel,
          navigationModel: navigationModel
        )
      }
    }
  }

  /// Clears selection and focus for a worktree being removed.
  func removeWorktreeModuleFocus(
    _ worktree: WorktreeBranch,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) {
    let path = WorktreeModuleResolver.normalizedDirectoryPath(worktree.path)
    let workspaces = workspaceViewModel.workspaces(for: path)
    if workspaces.contains(where: { $0.id == navigationModel.selectedWorkspaceID }) {
      navigationModel.selectedWorkspaceID = nil
    }
    Task {
      for workspace in workspaces {
        await workspaceViewModel.closeWorkspace(id: workspace.id)
      }
    }
    if navigationModel.selectedModuleLandingPath == path {
      navigationModel.selectedModuleLandingPath = nil
    }
    claudeViewModel.removeFocusedWorktree(at: path)
    codexViewModel.removeFocusedWorktree(at: path)
  }

  // MARK: - Worktree Create

  /// Hands a side-panel worktree creation to the app-wide progress coordinator.
  func beginSidePanelWorktree(
    context: WorktreeCreateContext,
    branchName: String,
    directoryName: String,
    baseBranch: String?,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) {
    let vm = context.providerKind == .claude ? claudeViewModel : codexViewModel
    let repo = context.repository
    let providerKind = context.providerKind
    if let coordinator = vm.agentHubProvider?.worktreeGenerationProgressCoordinator {
      coordinator.beginSidePanelOperation(
        branchName: branchName,
        repoName: repo.name,
        providerKind: providerKind
      ) { onProgress in
        try await vm.createWorktree(
          for: repo,
          branchName: branchName,
          directoryName: directoryName,
          baseBranch: baseBranch,
          onProgress: onProgress
        )
      }
    } else {
      Task {
        try? await vm.createWorktree(
          for: repo,
          branchName: branchName,
          directoryName: directoryName,
          baseBranch: baseBranch,
          onProgress: { _ in }
        )
      }
    }
  }

  // MARK: - New Session

  func triggerNewSessionFlow(
    preferredRepositoryPath: String? = nil,
    fallsBackToRepositoryPicker: Bool = true,
    makeLaunchViewModel: () -> MultiSessionLaunchViewModel
  ) {
    let launchViewModel = makeLaunchViewModel()

    guard let preferredRepositoryPath else {
      startSessionSheetContext = StartSessionSheetContext(launchViewModel: launchViewModel)
      launchViewModel.selectRepository()
      return
    }

    if launchViewModel.preselectRepository(path: preferredRepositoryPath) {
      startSessionSheetContext = StartSessionSheetContext(launchViewModel: launchViewModel)
      launchViewModel.beginBranchLoad()
    } else if fallsBackToRepositoryPicker {
      startSessionSheetContext = StartSessionSheetContext(launchViewModel: launchViewModel)
      launchViewModel.selectRepository()
    }
  }

  // MARK: - Fork

  func triggerForkSessionFlow(
    session: CLISession,
    targetProvider: SessionProviderKind,
    makeLaunchViewModel: () -> MultiSessionLaunchViewModel
  ) {
    let launchViewModel = makeLaunchViewModel()
    if launchViewModel.configureForFork(from: session, targetProvider: targetProvider) {
      startSessionSheetContext = StartSessionSheetContext(launchViewModel: launchViewModel)
    }
  }

  /// Checks the live branch before sending to the selected standalone session.
  func gitHubSendToSession(
    item: GitHubSheetItem,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) -> ((String, CLISession) -> Void)? {
    guard item.session != nil else { return nil }
    return { [weak self] prompt, requestedSession in
      guard let self else { return }
      self.gitHubSendTask?.cancel()
      self.gitHubSendTask = nil
      self.gitHubSendError = false
      if item.workspaceID != nil {
        self.gitHubSendErrorMessage =
          "AgentHub can’t verify the workspace session. Open its terminal and enter the context yourself."
        self.gitHubSendError = true
        return
      }
      self.gitHubSendErrorMessage =
        "The session or its terminal is no longer available. Open the session and try again."
      self.gitHubSendTask = Task { @MainActor in
        guard !Task.isCancelled, self.gitHubSheetItem?.id == item.id else { return }
        guard let session = item.session, let provider = item.provider,
          let expectedBranch = item.branchName, !expectedBranch.isEmpty,
          session.projectPath == item.projectPath, session.branchName == expectedBranch,
          requestedSession.id == session.id, requestedSession.projectPath == session.projectPath,
          requestedSession.branchName == expectedBranch
        else {
          self.gitHubSendError = true
          return
        }
        await workspaceViewModel.load()
        guard !Task.isCancelled, self.gitHubSheetItem?.id == item.id else { return }
        let actualBranch = try? await self.currentBranch(item.projectPath)
        guard !Task.isCancelled, self.gitHubSheetItem?.id == item.id else { return }
        guard actualBranch == expectedBranch,
          navigationModel.selectedWorkspaceID == nil,
          navigationModel.primarySessionId
            == SidebarSessionItemID.monitored(
              provider: provider, sessionId: session.id),
          workspaceViewModel.hasLoadedWorkspaceOwnership,
          workspaceViewModel.workspaceIDs(owningSession: session.id, provider: provider).isEmpty
        else {
          self.gitHubSendErrorMessage =
            "The session, terminal, or branch changed. Open the session and try again."
          self.gitHubSendError = true
          return
        }
        let viewModel = provider == .claude ? claudeViewModel : codexViewModel
        guard viewModel.providerKind == provider,
          let current = viewModel.monitoredCLISessions.first(where: { $0.id == session.id }),
          current.projectPath == session.projectPath, current.branchName == expectedBranch
        else {
          self.gitHubSendError = true
          return
        }
        // Keep verified context out of the deferred initial-prompt queue.
        guard viewModel.sendPromptToActiveTerminal(forKey: current.id, prompt: prompt) else {
          self.gitHubSendError = true
          return
        }
      }
    }
  }

  // MARK: - GitHub Review Session

  func launchGitHubReviewSession(
    projectPath: String,
    inputText: String,
    providerKind: SessionProviderKind,
    orderedTrackedRepos: [SelectedRepository],
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) {
    let viewModel = providerKind == .claude ? claudeViewModel : codexViewModel
    let target = GitHubReviewSessionLaunchTargetResolver.launchTarget(
      for: projectPath,
      repositories: Array(orderedTrackedRepos)
    )

    gitHubSheetItem = nil

    Task { @MainActor in
      let worktree: WorktreeBranch
      if target.worktree.isWorktree, let parentRepositoryPath = target.parentRepositoryPath {
        worktree = await viewModel.registerCreatedWorktree(
          name: target.worktree.name,
          path: target.worktree.path,
          parentRepositoryPath: parentRepositoryPath
        )
      } else {
        viewModel.addRepository(at: target.worktree.path)
        worktree = target.worktree
      }

      viewModel.startNewSessionInHub(worktree, initialPrompt: inputText)
      viewModel.refresh()
    }
  }

  // MARK: - Add Repository

  /// Uses asyncAfter to schedule NSOpenPanel creation on a future run loop
  /// iteration, avoiding HIRunLoopSemaphore deadlock.
  func showAddRepositoryPicker(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    trackPendingModule: @escaping (String) -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      MainActor.assumeIsolated {
        let panel = NSOpenPanel()
        panel.title = "Add Sessions Folder"
        panel.message = "Choose a repository or a folder containing projects"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
          trackPendingModule(url.path)
          claudeViewModel.addFolder(at: url.path)
          codexViewModel.addFolder(at: url.path)
        }
      }
    }
  }

  // MARK: - Session File

  static let sessionFileErrorMessage = "Couldn't read the transcript"

  /// Reads the transcript off the main actor (files can be many MB), then shows
  /// the sheet, or a short error when the file is missing, unreadable or empty.
  func openSessionFile(
    for session: CLISession,
    viewModel: CLISessionsViewModel
  ) {
    let fileURL = viewModel.sessionFileURL(for: session)
    sessionFileTask?.cancel()
    sessionFileTask = Task {
      let content = await Self.readTranscript(at: fileURL)
      guard !Task.isCancelled else { return }
      sessionFileTask = nil
      guard let fileURL, let content else {
        sessionFileError = Self.sessionFileErrorMessage
        return
      }
      sessionFileSheetItem = CoordinatorSessionFileSheetItem(
        session: session,
        fileName: fileURL.lastPathComponent,
        content: content
      )
    }
  }

  /// The file's UTF-8 text, or nil when it is missing, unreadable or empty.
  nonisolated static func readTranscript(at url: URL?) async -> String? {
    guard let url else { return nil }
    return await Task.detached(priority: .userInitiated) {
      guard let data = try? Data(contentsOf: url),
        let content = String(data: data, encoding: .utf8),
        !content.isEmpty
      else { return nil }
      return content
    }.value
  }

  // MARK: - Workspace Close

  func requestCloseWorkspace(
    _ workspaceID: String,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) {
    if workspaceViewModel.requiresCloseConfirmation(id: workspaceID) {
      workspacePendingCloseID = workspaceID
    } else {
      closeWorkspace(
        workspaceID,
        workspaceViewModel: workspaceViewModel,
        navigationModel: navigationModel
      )
    }
  }

  func closePendingWorkspace(
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) {
    guard let workspaceID = workspacePendingCloseID else { return }
    workspacePendingCloseID = nil
    closeWorkspace(
      workspaceID,
      workspaceViewModel: workspaceViewModel,
      navigationModel: navigationModel
    )
  }

  private func closeWorkspace(
    _ workspaceID: String,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel
  ) {
    let wasSelected = navigationModel.selectedWorkspaceID == workspaceID
    if wasSelected {
      navigationModel.selectedWorkspaceID = nil
    }
    Task {
      await workspaceViewModel.closeWorkspace(id: workspaceID)
    }
  }
}

// MARK: - ArchivableSessionItem

/// A lightweight representation of a session for archive operations.
struct ArchivableSessionItem {
  let id: String
  let session: CLISession
  let providerKind: SessionProviderKind
  let isPending: Bool
  let wasPinned: Bool
}
