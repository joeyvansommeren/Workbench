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
      SessionDetailView(
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
