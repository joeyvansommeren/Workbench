//
//  SessionsPresentationModifier.swift
//  AgentHub
//
//  Attaches all the sheets and alerts that were previously embedded in
//  MultiProviderSessionsListView.presentedContent. Both the legacy and the
//  new shell apply this modifier so sheets are defined in one place.
//

import AgentHubGitHub
import SwiftUI

// MARK: - RemoveConfirmationAlert

/// Alert modifier for the "Remove repository?" confirmation.
struct RemoveConfirmationAlert: ViewModifier {
  @Binding var confirmation: RemoveConfirmation?

  func body(content: Content) -> some View {
    content.alert(
      confirmation?.title ?? "",
      isPresented: Binding(
        get: { confirmation != nil },
        set: { if !$0 { confirmation = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmation = nil }
      Button("Remove", role: .destructive) {
        confirmation?.action()
        confirmation = nil
      }
    } message: {
      if let confirmation {
        Text(confirmation.message)
      }
    }
  }
}

// MARK: - SessionsPresentationModifier

/// Attaches all session-related sheets and alerts to the modified view.
///
/// This is the single place where presentation state from
/// `SessionsActionCoordinator` and `SessionNavigationModel` is turned
/// into SwiftUI modifiers.
struct SessionsPresentationModifier: ViewModifier {
  @Bindable var coordinator: SessionsActionCoordinator
  let claudeViewModel: CLISessionsViewModel
  let codexViewModel: CLISessionsViewModel
  let workspaceViewModel: AgentWorkspacesViewModel
  let navigationModel: SessionNavigationModel
  let intelligenceViewModel: IntelligenceViewModel?
  let contextProfileService: (any ContextProfileServiceProtocol)?

  init(
    coordinator: SessionsActionCoordinator,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    workspaceViewModel: AgentWorkspacesViewModel,
    navigationModel: SessionNavigationModel,
    intelligenceViewModel: IntelligenceViewModel?,
    contextProfileService: (any ContextProfileServiceProtocol)?
  ) {
    self.coordinator = coordinator
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.workspaceViewModel = workspaceViewModel
    self.navigationModel = navigationModel
    self.intelligenceViewModel = intelligenceViewModel
    self.contextProfileService = contextProfileService
  }

  func body(content: Content) -> some View {
    alertsLayer(sheetsLayer(content))
  }

  // MARK: - Sheets

  @ViewBuilder
  private func sheetsLayer(_ content: Content) -> some View {
    content
      .sheet(item: $coordinator.createWorktreeContext) { context in
        CreateWorktreeSheet(
          repositoryPath: context.repository.path,
          repositoryName: context.repository.name,
          onDismiss: { coordinator.createWorktreeContext = nil },
          onCreate: { branchName, directoryName, baseBranch in
            coordinator.beginSidePanelWorktree(
              context: context,
              branchName: branchName,
              directoryName: directoryName,
              baseBranch: baseBranch,
              claudeViewModel: claudeViewModel,
              codexViewModel: codexViewModel
            )
          }
        )
      }
      .sheet(item: $coordinator.gitHubSheetItem) { item in
        gitHubPanelSheet(item: item)
      }
      .sheet(item: $coordinator.startSessionSheetContext) { context in
        StartSessionSheet(
          launchViewModel: context.launchViewModel,
          intelligenceViewModel: intelligenceViewModel,
          onDismiss: { coordinator.startSessionSheetContext = nil }
        )
      }
      .sheet(item: $coordinator.projectDetailsSheetItem) { item in
        projectDetailsSheet(item: item)
      }
      // Set only by `openSessionFile(for:viewModel:)`, which the new shell's
      // tree rows call; the legacy views keep their own transcript sheets.
      .sheet(item: $coordinator.sessionFileSheetItem) { item in
        SessionTranscriptSheetView(
          session: item.session,
          fileName: item.fileName,
          content: item.content,
          onDismiss: { coordinator.sessionFileSheetItem = nil }
        )
      }
      .overlay(alignment: .topTrailing) {
        archiveUndoOverlay
      }
  }

  // MARK: - Alerts

  @ViewBuilder
  private func alertsLayer<V: View>(_ content: V) -> some View {
    content
      .alert(
        "Failed to Delete Worktree",
        isPresented: worktreeDeletionErrorPresented
      ) {
        worktreeDeletionErrorActions
      } message: {
        worktreeDeletionErrorMessage
      }
      .alert(
        "Delete Worktree?",
        isPresented: worktreeModuleDeletePresented,
        presenting: coordinator.worktreeModuleDeleteConfirmation
      ) { confirmation in
        Button("Cancel", role: .cancel) {
          coordinator.worktreeModuleDeleteConfirmation = nil
        }
        Button("Delete", role: .destructive) {
          coordinator.deleteWorktreeModule(
            confirmation,
            claudeViewModel: claudeViewModel,
            codexViewModel: codexViewModel,
            workspaceViewModel: workspaceViewModel,
            navigationModel: navigationModel
          )
        }
      } message: { confirmation in
        worktreeModuleDeleteMessage(confirmation)
      }
      .modifier(RemoveConfirmationAlert(confirmation: $coordinator.removeConfirmation))
      .modifier(
        AgentWorkspaceCloseConfirmationModifier(
          workspaceID: $coordinator.workspacePendingCloseID,
          onConfirm: {
            coordinator.closePendingWorkspace(
              workspaceViewModel: workspaceViewModel,
              navigationModel: navigationModel
            )
          }
        )
      )
      .modifier(AgentWorkspaceErrorAlertModifier(viewModel: workspaceViewModel))
  }

  // MARK: - Sheet Builders

  private func gitHubPanelSheet(item: GitHubSheetItem) -> some View {
    let provider = claudeViewModel.agentHubProvider ?? codexViewModel.agentHubProvider
    return GitHubPanelView(
      projectPath: item.projectPath,
      onDismiss: { coordinator.gitHubSheetItem = nil },
      isEmbedded: false,
      viewModel: GitHubViewModel(
        service: provider?.gitHubService ?? GitHubCLIService(),
        observationService: provider?.gitHubPRObservationService
      ),
      onSendToSession: { prompt, session in
        claudeViewModel.showTerminalWithPrompt(for: session, prompt: prompt)
      },
      onStartNewSession: { inputText, providerKind in
        coordinator.launchGitHubReviewSession(
          projectPath: item.projectPath,
          inputText: inputText,
          providerKind: providerKind,
          orderedTrackedRepos: mergedRepos,
          claudeViewModel: claudeViewModel,
          codexViewModel: codexViewModel
        )
      }
    )
  }

  private func projectDetailsSheet(item: ProjectDetailsSheetItem) -> some View {
    ProjectDetailsSheetView(
      modulePath: item.projectPath,
      displayName: item.displayName,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      contextProfileService: contextProfileService,
      onDismiss: { coordinator.projectDetailsSheetItem = nil },
      onSelectSession: { sessionItem in
        coordinator.projectDetailsSheetItem = nil
        navigationModel.selectedWorkspaceID = nil
        navigationModel.selectedModuleLandingPath = nil
        navigationModel.primarySessionId = sessionItem.id
      }
    )
  }

  @ViewBuilder
  private var archiveUndoOverlay: some View {
    if let archiveUndo = coordinator.archiveUndo {
      ArchiveUndoToast(
        undo: archiveUndo,
        onUndo: {
          coordinator.undoArchive(archiveUndo) { provider in
            provider == .claude ? claudeViewModel : codexViewModel
          }
        },
        onDismiss: {
          withAnimation(.easeOut(duration: 0.2)) {
            if coordinator.archiveUndo == archiveUndo {
              coordinator.archiveUndo = nil
            }
          }
        }
      )
      .id(archiveUndo.id)
      .padding(.top, DesignTokens.Spacing.md)
      .padding(.trailing, DesignTokens.Spacing.lg)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  // MARK: - Worktree Module Delete

  private var worktreeModuleDeletePresented: Binding<Bool> {
    Binding(
      get: { coordinator.worktreeModuleDeleteConfirmation != nil },
      set: { if !$0 { coordinator.worktreeModuleDeleteConfirmation = nil } }
    )
  }

  @ViewBuilder
  private func worktreeModuleDeleteMessage(
    _ confirmation: WorktreeModuleDeleteConfirmation
  ) -> some View {
    if confirmation.sessionCount > 0 {
      let threadLabel = confirmation.sessionCount == 1 ? "thread" : "threads"
      Text(
        "This will archive \(confirmation.sessionCount) \(threadLabel) "
          + "and delete \(confirmation.displayName) at:\n"
          + "\(confirmation.worktree.path)\n\n"
          + "This cannot be undone."
      )
    } else {
      Text(
        """
        Delete \(confirmation.displayName) at:
        \(confirmation.worktree.path)

        This cannot be undone.
        """
      )
    }
  }

  // MARK: - Merged repos helper

  private var mergedRepos: [SelectedRepository] {
    let combined = WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )
    return combined.reversed()
  }

  // MARK: - Worktree Deletion Error

  private var worktreeDeletionErrorPresented: Binding<Bool> {
    Binding(
      get: {
        claudeViewModel.worktreeDeletionError != nil
          || codexViewModel.worktreeDeletionError != nil
      },
      set: {
        if !$0 {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.clearWorktreeDeletionError()
        }
      }
    )
  }

  @ViewBuilder
  private var worktreeDeletionErrorActions: some View {
    let error = claudeViewModel.worktreeDeletionError ?? codexViewModel.worktreeDeletionError
    if let error, error.isOrphaned, let parentRepoPath = error.parentRepoPath {
      Button("Prune & Delete") {
        let isClaudeError = claudeViewModel.worktreeDeletionError != nil
        if isClaudeError {
          codexViewModel.clearWorktreeDeletionError()
          claudeViewModel.forceDeleteOrphanedWorktree(
            error.worktree, parentRepoPath: parentRepoPath)
        } else {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.forceDeleteOrphanedWorktree(
            error.worktree, parentRepoPath: parentRepoPath)
        }
      }
      Button("Cancel", role: .cancel) {
        claudeViewModel.clearWorktreeDeletionError()
        codexViewModel.clearWorktreeDeletionError()
      }
    } else if let error {
      Button("Force Delete", role: .destructive) {
        let isClaudeError = claudeViewModel.worktreeDeletionError != nil
        if isClaudeError {
          codexViewModel.clearWorktreeDeletionError()
          claudeViewModel.forceDeleteWorktree(error.worktree)
        } else {
          claudeViewModel.clearWorktreeDeletionError()
          codexViewModel.forceDeleteWorktree(error.worktree)
        }
      }
      Button("Cancel", role: .cancel) {
        claudeViewModel.clearWorktreeDeletionError()
        codexViewModel.clearWorktreeDeletionError()
      }
    }
  }

  @ViewBuilder
  private var worktreeDeletionErrorMessage: some View {
    let error = claudeViewModel.worktreeDeletionError ?? codexViewModel.worktreeDeletionError
    if let error {
      if error.isOrphaned, let parentRepoPath = error.parentRepoPath {
        Text(
          "The worktree at:\n\(error.worktree.path)\n\nhas no parent repo. You can prune and delete it from:\n\(parentRepoPath)"
        )
      } else {
        Text(
          "\(error.message)\n\n\"Force Delete\" will remove the worktree even if it contains untracked files."
        )
      }
    }
  }
}
