//
//  ShellSessionItems.swift
//  AgentHub
//
//  The window's open sessions (pending and monitored, both providers) as
//  `ProjectableSessionItem`s, newest first. Same ids and order as the legacy
//  sidebar, so `SessionNavigationModel` selection works in either shell.
//

import Foundation

@MainActor
enum ShellSessionItems {
  static func items(
    claude: CLISessionsViewModel,
    codex: CLISessionsViewModel
  ) -> [ProjectableSessionItem] {
    var results: [ProjectableSessionItem] = []
    for (provider, viewModel) in [(SessionProviderKind.claude, claude), (.codex, codex)] {
      for pending in viewModel.pendingHubSessions {
        results.append(
          ProjectableSessionItem(
            id: SidebarSessionItemID.pending(provider: provider, pendingId: pending.id),
            session: pending.placeholderSession,
            providerKind: provider,
            timestamp: pending.startedAt,
            isPending: true,
            status: nil,
            pendingID: pending.id
          ))
      }
      // `sessionStatus(for:)` is the narrow projection; reading `monitorStates`
      // would re-render on every token update.
      for session in viewModel.monitoredCLISessions {
        results.append(
          ProjectableSessionItem(
            id: SidebarSessionItemID.monitored(provider: provider, sessionId: session.id),
            session: session,
            providerKind: provider,
            timestamp: session.lastActivityAt,
            isPending: false,
            status: viewModel.sessionStatus(for: session.id)
          ))
      }
    }
    return results.sorted { $0.timestamp > $1.timestamp }
  }

  /// Tracked repositories from both providers, merged.
  static func repositories(
    claude: CLISessionsViewModel,
    codex: CLISessionsViewModel
  ) -> [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claude.selectedRepositories + codex.selectedRepositories
    )
  }

  static func snapshots(_ items: [ProjectableSessionItem]) -> [SessionItemSnapshot] {
    items.map {
      SessionItemSnapshot(
        id: $0.id,
        providerKind: $0.providerKind,
        sessionId: $0.session.id,
        isPending: $0.isPending
      )
    }
  }
}
