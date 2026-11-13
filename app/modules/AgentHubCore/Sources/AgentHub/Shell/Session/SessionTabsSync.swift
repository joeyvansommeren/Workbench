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
//  - persistence: open tabs are saved with each provider's workspace state
//    and merged back once that state is read.
//  - pruning: tabs of sessions that went away (archived, stopped) close.
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
        tabsModel.onTabsChanged = { [claude, codex] ids in
          claude.updateOpenSessionTabIds(SessionTabsModel.persistedIDs(in: ids, for: .claude))
          codex.updateOpenSessionTabIds(SessionTabsModel.persistedIDs(in: ids, for: .codex))
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
    // Rename pending tabs first, so a resolved selection reuses the tab.
    tabsModel.migrateResolvedPendingSessions(claude.resolvedPendingSessionHistory, provider: .claude)
    tabsModel.migrateResolvedPendingSessions(codex.resolvedPendingSessionHistory, provider: .codex)
    guard let id else { return }
    tabsModel.open(id)
  }

  private func restorePersistedTabs() {
    if let ids = claude.restoredOpenSessionTabIds { tabsModel.restore(ids, provider: .claude) }
    if let ids = codex.restoredOpenSessionTabIds { tabsModel.restore(ids, provider: .codex) }
  }

  private func pruneTabs(availableIDs: Set<String>) {
    let shownBefore = navigationModel.primarySessionId
    tabsModel.prune(availableIDs: availableIDs)
    // The shown session went away: show the tab the model selected instead.
    guard let shownBefore, !tabsModel.openTabIDs.contains(shownBefore),
      navigationModel.primarySessionId == shownBefore
    else { return }
    if let next = tabsModel.selectedTabID, availableIDs.contains(next) {
      navigationModel.selectSession(next)
    }
  }
}
