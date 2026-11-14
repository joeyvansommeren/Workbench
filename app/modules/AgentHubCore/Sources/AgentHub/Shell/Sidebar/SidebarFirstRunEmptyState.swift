//
//  SidebarFirstRunEmptyState.swift
//  AgentHub
//
//  The sidebar on first run: no tracked projects and no sessions. Shown only
//  after both providers finished restoring their saved repositories, so it
//  never flashes at launch while the tree is still loading.
//

import SwiftUI

enum SidebarFirstRun {
  /// Both providers must have loaded: each restores its own saved repositories.
  static func showsEmptyState(
    claudeLoaded: Bool,
    codexLoaded: Bool,
    repositoryCount: Int,
    sessionCount: Int
  ) -> Bool {
    claudeLoaded && codexLoaded && repositoryCount == 0 && sessionCount == 0
  }

  @MainActor
  static func showsEmptyState(claude: CLISessionsViewModel, codex: CLISessionsViewModel) -> Bool {
    // Checked step by step, so a normal launch (projects present) reads
    // only the flags and repositories, never the session lists that change
    // with every bit of activity.
    guard claude.hasLoadedRepositories, codex.hasLoadedRepositories,
      claude.selectedRepositories.isEmpty, codex.selectedRepositories.isEmpty
    else { return false }
    return showsEmptyState(
      claudeLoaded: true,
      codexLoaded: true,
      repositoryCount: 0,
      sessionCount: claude.pendingHubSessions.count + codex.pendingHubSessions.count
        + claude.monitoredCLISessions.count + codex.monitoredCLISessions.count
    )
  }
}

/// The session tree, or the first-run empty state. Its own view, so the
/// reads it needs re-render only this switch.
struct SidebarTreeOrEmptyState: View {
  let openProject: () -> Void

  @Environment(\.agentHub) private var agentHub

  var body: some View {
    if let agentHub,
      SidebarFirstRun.showsEmptyState(
        claude: agentHub.claudeSessionsViewModel, codex: agentHub.codexSessionsViewModel)
    {
      SidebarFirstRunEmptyState(openProject: openProject)
    } else {
      SessionTreeView()
    }
  }
}

struct SidebarFirstRunEmptyState: View {
  let openProject: () -> Void

  var body: some View {
    WBEmptyState(systemImage: "folder", title: "No projects") {
      Button("Open project", action: openProject)
        .buttonStyle(WBPrimaryButtonStyle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
