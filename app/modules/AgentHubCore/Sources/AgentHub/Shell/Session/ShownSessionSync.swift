//
//  ShownSessionSync.swift
//  AgentHub
//
//  Keeps the window's `SessionDetailStateModel` in step with the rest of the
//  app. Applied once at the shell root (always mounted), so it also runs while
//  Reviews, Jira or Linear is shown:
//
//  - shown session: whatever selects a session (sidebar tree, palette,
//    router, a launch) sets `primarySessionId`; it is saved here.
//  - pending → resolved: a launching session's per-session state takes the
//    real id.
//  - persistence: each provider saves the shown session of every window
//    (`OpenSessionTabsAggregate`, stored in the v17 `openSessionTabIds`
//    column); the first window takes the saved ids back at launch.
//
//  Which session to show when nothing is (or the shown one went away) is
//  decided by `SessionDetailStateModel.selectionUpkeep`, run by the detail.
//

import SwiftUI

struct ShownSessionSync: ViewModifier {
  let stateModel: SessionDetailStateModel
  let navigationModel: SessionNavigationModel
  let claude: CLISessionsViewModel
  let codex: CLISessionsViewModel

  func body(content: Content) -> some View {
    content
      .onAppear {
        let window = stateModel.windowID
        stateModel.onShownChanged = { [claude, codex] id in
          claude.updateOpenSessionTabIds(SessionDetailStateModel.persistedIDs(in: [id], for: .claude), window: window)
          codex.updateOpenSessionTabIds(SessionDetailStateModel.persistedIDs(in: [id], for: .codex), window: window)
        }
        restoreSavedSessions()
        stateModel.show(navigationModel.primarySessionId)
      }
      .onChange(of: navigationModel.primarySessionId) { _, newValue in
        stateModel.show(newValue)
      }
      .onChange(of: claude.resolvedPendingSessionHistory) { _, history in
        stateModel.migrateResolvedPendingSessions(history, provider: .claude)
      }
      .onChange(of: codex.resolvedPendingSessionHistory) { _, history in
        stateModel.migrateResolvedPendingSessions(history, provider: .codex)
      }
      .onChange(of: claude.restoredOpenSessionTabIds) { _, _ in restoreSavedSessions() }
      .onChange(of: codex.restoredOpenSessionTabIds) { _, _ in restoreSavedSessions() }
  }

  private func restoreSavedSessions() {
    for (provider, viewModel) in [(SessionProviderKind.claude, claude), (.codex, codex)]
    where !stateModel.hasRestored(provider) {
      if let ids = viewModel.claimRestoredOpenSessionTabIds() {
        stateModel.restore(ids, provider: provider)
      }
    }
  }
}
