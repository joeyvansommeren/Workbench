//
//  SessionsToolbarContent.swift
//  AgentHub
//
//  The Sessions destination's toolbar slot: the session tab strip.
//

import SwiftUI

struct SessionsToolbarContent: View {
  let onNewSession: () -> Void

  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(SessionTabsModel.self) private var tabsModel

  var body: some View {
    SessionTabStrip(
      tabs: presentations,
      selectedID: navigationModel?.primarySessionId,
      onSelect: { navigationModel?.selectSession($0) },
      onClose: close,
      onNewSession: onNewSession
    )
  }

  private var presentations: [SessionTabPresentation] {
    guard let agentHub else { return [] }
    let claude = agentHub.claudeSessionsViewModel
    let codex = agentHub.codexSessionsViewModel
    let items = ShellSessionItems.items(claude: claude, codex: codex)
    let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let repositories = ShellSessionItems.repositories(claude: claude, codex: codex)
    return tabsModel.visibleTabIDs(availableIDs: Set(itemsByID.keys)).compactMap { id in
      guard let item = itemsByID[id] else { return nil }
      let viewModel = item.providerKind == .claude ? claude : codex
      return SessionTabPresentation.make(
        item: item,
        title: viewModel.displayName(for: item.session),
        repositories: repositories
      )
    }
  }

  /// Closing never stops the session. When the shown tab closes, its right
  /// neighbour (else the left one) is shown; with no tabs left, nothing is.
  private func close(_ id: String) {
    let wasShown = navigationModel?.primarySessionId == id
    // Pick the neighbour among visible tabs, so a restored tab whose session
    // has not loaded yet is never selected.
    let visible = presentations.map(\.id)
    let index = visible.firstIndex(of: id)
    tabsModel.close(id)
    guard wasShown, let navigationModel else { return }
    let next = index.flatMap {
      SessionTabsModel.neighbour(afterRemovingAt: $0, in: visible.filter { $0 != id })
    }
    if let next {
      navigationModel.selectSession(next)
    } else {
      navigationModel.primarySessionId = nil
    }
  }
}
