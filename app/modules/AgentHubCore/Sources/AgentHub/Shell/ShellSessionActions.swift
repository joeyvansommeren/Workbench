//
//  ShellSessionActions.swift
//  AgentHub
//
//  Session actions the new shell triggers from its chrome and commands (⌘N,
//  fork, add a folder). Thin wrappers that hand the window's coordinator the
//  inputs the legacy sidebar used to supply.
//

import Foundation

@MainActor
struct ShellSessionActions {
  let agentHub: AgentHubProvider
  let coordinator: SessionsActionCoordinator
  let navigationModel: SessionNavigationModel

  private var claude: CLISessionsViewModel { agentHub.claudeSessionsViewModel }
  private var codex: CLISessionsViewModel { agentHub.codexSessionsViewModel }

  /// ⌘N: a new session in the focused project, or the picker when nothing is focused.
  func startFocusedSession() {
    startSession(preferredRepositoryPath: focusedLaunchPath)
  }

  func startSession(preferredRepositoryPath: String?) {
    MainThreadStallMonitor.breadcrumb("sheet: new session")
    coordinator.triggerNewSessionFlow(
      preferredRepositoryPath: preferredRepositoryPath,
      fallsBackToRepositoryPicker: true,
      makeLaunchViewModel: makeLaunchViewModel
    )
  }

  func forkSession(_ session: CLISession, targetProvider: SessionProviderKind) {
    coordinator.triggerForkSessionFlow(
      session: session,
      targetProvider: targetProvider,
      makeLaunchViewModel: makeLaunchViewModel
    )
  }

  /// ⌥⌘A: archive this window's primary session (beeps when there is none).
  func archiveCurrentSession() {
    let viewModelFor: (SessionProviderKind) -> CLISessionsViewModel = {
      $0 == .claude ? claude : codex
    }
    coordinator.requestArchiveCurrentSession(
      navigationModel: navigationModel,
      selectedSessionItems: ShellSessionItems.items(claude: claude, codex: codex).map { item in
        ArchivableSessionItem(
          id: item.id,
          session: item.session,
          providerKind: item.providerKind,
          isPending: item.isPending,
          wasPinned: viewModelFor(item.providerKind).pinnedSessionIds.contains(item.session.id)
        )
      },
      viewModelForProvider: viewModelFor,
      customNameForItem: { viewModelFor($0.providerKind).sessionCustomNames[$0.session.id] }
    )
  }

  func addRepository() {
    // The legacy sidebar tracks pending module rows; the new shell has none yet (P5).
    coordinator.showAddRepositoryPicker(
      claudeViewModel: claude,
      codexViewModel: codex,
      trackPendingModule: { _ in }
    )
  }

  private var focusedLaunchPath: String? {
    FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: navigationModel.primarySessionId,
      selectedModuleLandingPath: navigationModel.selectedModuleLandingPath,
      items: ShellSessionItems.items(claude: claude, codex: codex).map {
        FocusedSessionLaunchTargetResolver.SessionItem(id: $0.id, projectPath: $0.session.projectPath)
      },
      repositories: ShellSessionItems.repositories(claude: claude, codex: codex)
    )
  }

  private func makeLaunchViewModel() -> MultiSessionLaunchViewModel {
    MultiSessionLaunchViewModel(
      claudeViewModel: claude,
      codexViewModel: codex,
      intelligenceViewModel: agentHub.intelligenceViewModel,
      worktreeBranchNamingService: agentHub.worktreeBranchNamingService,
      worktreeSuccessSoundService: agentHub.worktreeSuccessSoundService,
      contextProfileService: agentHub.contextProfileService
    )
  }
}
