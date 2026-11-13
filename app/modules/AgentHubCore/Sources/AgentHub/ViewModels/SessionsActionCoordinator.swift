//
//  SessionsActionCoordinator.swift
//  AgentHub
//
//  Actions extracted from MultiProviderSessionsListView so both the legacy
//  and new shell can share archive, remove, delete, new-session and fork flows.
//

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
  var createWorktreeContext: WorktreeCreateContext?
  var startSessionSheetContext: StartSessionSheetContext?
  var gitHubSheetItem: GitHubSheetItem?
  var projectDetailsSheetItem: ProjectDetailsSheetItem?
  var archiveUndo: ArchivedSessionsUndo?
  var removeConfirmation: RemoveConfirmation?
  var worktreeModuleDeleteConfirmation: WorktreeModuleDeleteConfirmation?
  var workspacePendingCloseID: String?
  /// The new shell's New session sheet. Window-level, so leaving Sessions
  /// does not clear it; the legacy shell never sets it.
  var newSessionSheetRequest: NewSessionSheetRequest?

  // MARK: - Init

  init() {}

  // MARK: - Transient State

  /// Resets all sheet, alert and undo state so stale presentation does not
  /// resurface when the Sessions view re-enters the tree.
  func clearTransientPresentation() {
    archiveUndo = nil
    createWorktreeContext = nil
    startSessionSheetContext = nil
    gitHubSheetItem = nil
    projectDetailsSheetItem = nil
    sessionFileSheetItem = nil
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

  func openSessionFile(
    for session: CLISession,
    viewModel: CLISessionsViewModel
  ) {
    guard let fileURL = viewModel.sessionFileURL(for: session),
      let data = FileManager.default.contents(atPath: fileURL.path),
      let content = String(data: data, encoding: .utf8)
    else {
      return
    }

    if !content.isEmpty {
      sessionFileSheetItem = CoordinatorSessionFileSheetItem(
        session: session,
        fileName: fileURL.lastPathComponent,
        content: content
      )
    }
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
