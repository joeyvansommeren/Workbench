//
//  ShellDetailSlot.swift
//  AgentHub
//
//  DETAIL SLOT of the new shell: what the content panel shows for the current
//  destination. P4 hosts the existing views; P6 replaces Sessions, P8 Reviews
//  and P9 Sprint, each by swapping its own case below.
//

import SwiftUI

struct ShellDetailSlot: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    if let agentHub {
      destinationView(agentHub: agentHub)
    } else {
      ContentUnavailableView("Workbench provider not found", systemImage: "exclamationmark.triangle")
    }
  }

  @ViewBuilder
  private func destinationView(agentHub: AgentHubProvider) -> some View {
    let actions = WorkspaceLaunchActions(
      agentHub: agentHub,
      showSessions: { shellModel.select(.sessions) }
    )
    switch shellModel.destination {
    case .sessions:
      ShellSessionsDetail(
        claudeViewModel: agentHub.claudeSessionsViewModel,
        codexViewModel: agentHub.codexSessionsViewModel,
        workspaceViewModel: agentHub.agentWorkspacesViewModel
      )
    case .reviews:
      GitHubReviewsView(
        viewModel: agentHub.gitHubReviewsViewModel,
        claudeSessionsViewModel: agentHub.claudeSessionsViewModel,
        codexSessionsViewModel: agentHub.codexSessionsViewModel,
        onReview: { pullRequest, provider, template in
          await actions.startReview(pullRequest, provider: provider, template: template)
        },
        onOpenSession: { actions.openReviewSession($0) }
      )
    case .sprint:
      ShellSprintDetail(agentHub: agentHub, actions: actions, tracker: shellModel.sprintTracker)
    }
  }
}

// MARK: - Sprint (P9 replaces)

private struct ShellSprintDetail: View {
  let agentHub: AgentHubProvider
  let actions: WorkspaceLaunchActions
  let tracker: SprintTracker

  private var repositories: [SelectedRepository] {
    ShellSessionItems.repositories(
      claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel
    )
  }

  var body: some View {
    switch tracker {
    case .jira:
      JiraSprintView(
        viewModel: agentHub.jiraSprintViewModel,
        repositories: repositories,
        linkedSessions: agentHub.jiraLinkedSessions(),
        isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
        isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
        onStart: { ticket, provider, repositoryPath in
          await actions.startJiraTicket(ticket, provider: provider, repositoryPath: repositoryPath)
        },
        onOpenSession: { agentHub.showSession($0) }
      )
    case .linear:
      LinearBoardView(
        viewModel: agentHub.linearViewModel,
        repositories: repositories,
        linkedSessions: agentHub.linearLinkedSessions(),
        isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
        isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
        onStart: { issue, provider, repositoryPath in
          await actions.startLinearIssue(issue, provider: provider, repositoryPath: repositoryPath)
        },
        onOpenSession: { agentHub.showLinearSession($0) }
      )
    }
  }
}

// MARK: - Sessions (P6 replaces)

/// Hosts the legacy `MultiProviderMonitoringPanelView` on the window's
/// `SessionNavigationModel`, with the selection upkeep the legacy sidebar did:
/// consume router requests and keep a valid primary selection. Pending-session
/// selection and archive live in the always-mounted `ShellRoot`.
private struct ShellSessionsDetail: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Bindable var workspaceViewModel: AgentWorkspacesViewModel

  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var actionCoordinator

  @AppStorage(AgentHubDefaults.selectedSidePanelProvider)
  private var selectedProviderRaw: String = "Claude"

  var body: some View {
    if let navigationModel {
      content(navigationModel: navigationModel)
    }
  }

  private func content(navigationModel: SessionNavigationModel) -> some View {
    VStack(spacing: 0) {
      WorktreeGenerationProgressBar()
      if let workspaceID = navigationModel.selectedWorkspaceID,
        let workspace = workspaceViewModel.workspace(id: workspaceID)
      {
        AgentWorkspaceDetailView(
          workspace: workspace,
          viewModel: workspaceViewModel,
          onRename: { name in
            Task { await workspaceViewModel.renameWorkspace(id: workspace.id, name: name) }
          },
          onClose: {
            actionCoordinator?.requestCloseWorkspace(
              workspace.id,
              workspaceViewModel: workspaceViewModel,
              navigationModel: navigationModel
            )
          }
        )
      } else {
        monitoringPanel(navigationModel: navigationModel)
      }
    }
    .onAppear {
      consumeRouterRequests()
      ensurePrimarySelection()
    }
    .task { await workspaceViewModel.load() }
    .onChange(of: agentHub?.globalSessionSelectionRouter.selectionRequest?.id) { _, _ in
      consumeRouterRequests()
    }
    .onChange(of: agentHub?.globalSessionSelectionRouter.comparisonRequest?.id) { _, _ in
      consumeRouterRequests()
    }
    .onChange(of: itemIDs) { _, _ in
      consumeRouterRequests()
      ensurePrimarySelection()
    }
  }

  private func monitoringPanel(navigationModel: SessionNavigationModel) -> some View {
    MultiProviderMonitoringPanelView(
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      primarySessionId: Binding(
        get: { navigationModel.primarySessionId },
        set: { navigationModel.primarySessionId = $0 }
      ),
      workflowComparison: navigationModel.workflowComparisonBinding(
        router: agentHub?.globalSessionSelectionRouter
      ),
      selectedModuleLandingPath: Binding(
        get: { navigationModel.selectedModuleLandingPath },
        set: { navigationModel.selectedModuleLandingPath = $0 }
      ),
      onAddFolder: { sessionActions?.addRepository() },
      onRequestStartSession: { sessionActions?.startSession(preferredRepositoryPath: $0) },
      onRequestForkSession: { sessionActions?.forkSession($0, targetProvider: $1) }
    )
  }

  private var sessionActions: ShellSessionActions? {
    guard let agentHub, let actionCoordinator, let navigationModel else { return nil }
    return ShellSessionActions(
      agentHub: agentHub, coordinator: actionCoordinator, navigationModel: navigationModel)
  }

  // MARK: - Selection upkeep

  private var items: [ProjectableSessionItem] {
    ShellSessionItems.items(claude: claudeViewModel, codex: codexViewModel)
  }

  private var itemIDs: [String] { items.map(\.id) }

  private func consumeRouterRequests() {
    guard let navigationModel else { return }
    navigationModel.consumeGlobalSessionSelectionIfNeeded(
      router: agentHub?.globalSessionSelectionRouter,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      workspaceViewModel: workspaceViewModel,
      selectedSessionItems: { ShellSessionItems.snapshots(items) },
      colorScheme: colorScheme,
      // The new shell has no auxiliary shell dock.
      setAuxiliaryShellVisible: { _ in },
      selectedProviderRawSetter: { selectedProviderRaw = $0 }
    )
    navigationModel.consumeGlobalWorkflowComparisonIfNeeded(
      router: agentHub?.globalSessionSelectionRouter,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      availableItemIDs: { Set(itemIDs) }
    )
  }

  private func ensurePrimarySelection() {
    guard let navigationModel else { return }
    // Workspace-owned sessions show inside their workspace, never as the primary card.
    let standalone = items.filter { item in
      item.isPending
        || workspaceViewModel.workspaceID(
          owningSession: item.session.id, provider: item.providerKind) == nil
    }
    navigationModel.ensurePrimarySelection(
      items: ShellSessionItems.snapshots(standalone),
      hasRouterRequest: agentHub?.globalSessionSelectionRouter.selectionRequest != nil
    )
  }
}
