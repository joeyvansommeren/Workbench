//
//  SessionTabsSync.swift
//  AgentHub
//
//  Keeps the window's `SessionTabsModel` in step with the rest of the app.
//  Applied once at the shell root (always mounted), so it also runs while
//  Reviews or Sprint is shown:
//
//  - selection: whatever selects a session (sidebar tree, palette, router,
//    a launch) sets `primarySessionId`; the tab opens or is selected here.
//  - pending → resolved: a launching session's tab takes the real id.
//  - persistence: this window's tabs go into each provider's saved union
//    (`OpenSessionTabsAggregate`); the first window takes the saved tabs back.
//  - pruning: tabs of sessions that went away (archived, stopped) close.
//
//  The decisions live in `SessionTabsModel` and are unit tested there.
//

import SwiftUI

struct SessionTabsSync: ViewModifier {
  let tabsModel: SessionTabsModel
  let navigationModel: SessionNavigationModel
  let claude: CLISessionsViewModel
  let codex: CLISessionsViewModel

  private var availableIDs: [String] {
    ShellSessionItems.items(claude: claude, codex: codex).map(\.id)
  }

  func body(content: Content) -> some View {
    content
      .onAppear {
        let window = tabsModel.windowID
        tabsModel.onTabsChanged = { [claude, codex] ids in
          claude.updateOpenSessionTabIds(SessionTabsModel.persistedIDs(in: ids, for: .claude), window: window)
          codex.updateOpenSessionTabIds(SessionTabsModel.persistedIDs(in: ids, for: .codex), window: window)
        }
        restorePersistedTabs()
        followPrimarySelection(navigationModel.primarySessionId)
      }
      .onChange(of: navigationModel.primarySessionId) { _, newValue in
        followPrimarySelection(newValue)
      }
      .onChange(of: claude.resolvedPendingSessionHistory) { _, history in
        tabsModel.migrateResolvedPendingSessions(history, provider: .claude)
      }
      .onChange(of: codex.resolvedPendingSessionHistory) { _, history in
        tabsModel.migrateResolvedPendingSessions(history, provider: .codex)
      }
      .onChange(of: claude.restoredOpenSessionTabIds) { _, _ in restorePersistedTabs() }
      .onChange(of: codex.restoredOpenSessionTabIds) { _, _ in restorePersistedTabs() }
      .onChange(of: availableIDs) { _, ids in
        pruneTabs(availableIDs: Set(ids))
      }
  }

  private func followPrimarySelection(_ id: String?) {
    tabsModel.follow(
      primarySessionId: id,
      resolvedHistories: [
        (.claude, claude.resolvedPendingSessionHistory),
        (.codex, codex.resolvedPendingSessionHistory),
      ]
    )
  }

  private func restorePersistedTabs() {
    for (provider, viewModel) in [(SessionProviderKind.claude, claude), (.codex, codex)]
    where !tabsModel.hasRestored(provider) {
      if let ids = viewModel.claimRestoredOpenSessionTabIds() {
        tabsModel.restore(ids, provider: provider)
      }
    }
  }

  private func pruneTabs(availableIDs: Set<String>) {
    let change = tabsModel.prune(availableIDs: availableIDs, shownID: navigationModel.primarySessionId)
    guard case .show(let next) = change else { return }
    if let next {
      navigationModel.selectSession(next)
    } else {
      navigationModel.primarySessionId = nil
    }
  }
}
