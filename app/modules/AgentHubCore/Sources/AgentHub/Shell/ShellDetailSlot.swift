//
//  ShellDetailSlot.swift
//  AgentHub
//
//  DETAIL SLOT of the new shell: what the content panel shows for the current
//  destination: Sessions (P6), Reviews (P8), Jira and Linear (P9, one tab
//  each since P12).
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
      ReviewsDestinationView(agentHub: agentHub, actions: actions)
    case .jira:
      JiraDestinationView(agentHub: agentHub, actions: actions)
    case .linear:
      LinearDestinationView(agentHub: agentHub, actions: actions)
    }
  }
}
