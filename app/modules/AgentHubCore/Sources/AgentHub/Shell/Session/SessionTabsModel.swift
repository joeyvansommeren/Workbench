//
//  SessionTabsModel.swift
//  AgentHub
//
//  Per-window session tabs of the new shell. A tab is an open session, keyed
//  by its sidebar item id (`SidebarSessionItemID`). Closing a tab never stops
//  the session; the terminal stays keyed by `terminalKey` in the view model.
//
//  The model follows `SessionNavigationModel.primarySessionId` (see
//  `SessionTabsSync`), so any surface that selects a session (sidebar tree,
//  palette, router) opens or selects its tab without knowing about tabs.
//

import Foundation

@MainActor
@Observable
final class SessionTabsModel {
  /// Open tabs, in strip order.
  private(set) var openTabIDs: [String] = []
  /// The tab shown in the content panel.
  private(set) var selectedTabID: String?
  /// Content mode (Terminal, Chat, Files, Diffs), Files project and open
  /// file per tab. Same store the legacy panel uses.
  private(set) var editorStates: [String: MonitoringEditorState] = [:]
  /// Side-panel segment per tab.
  private(set) var sidePanelSegments: [String: SidePanelSegment] = [:]

  /// Identifies this window's list in the cross-window persisted union
  /// (`OpenSessionTabsAggregate`).
  let windowID = UUID()

  /// True after the user closed the last tab this run. The detail then shows
  /// its empty state instead of opening a session by itself.
  private(set) var hasClosedAllTabs = false

  /// Called with the full tab list after every change, for persistence.
  @ObservationIgnored var onTabsChanged: (([String]) -> Void)?

  /// Side-panel auto-open bookkeeping (edits and plan), per window so it
  /// survives tab switches.
  @ObservationIgnored var autoOpen = SidePanelAutoOpenTracker()

  /// Providers whose persisted tabs were already merged in.
  @ObservationIgnored private var restoredProviders: Set<SessionProviderKind> = []
  /// Ids that resolved to a session at least once. Only those are pruned when
  /// they disappear, so restored tabs survive a slow launch restore.
  @ObservationIgnored private var everAvailableIDs: Set<String> = []

  init() {}

  // MARK: - Open, select, close

  /// Opens a tab for the session (or selects it when it is already open).
  func open(_ id: String) {
    hasClosedAllTabs = false
    if !openTabIDs.contains(id) {
      openTabIDs.append(id)
      MainThreadStallMonitor.breadcrumb("tab: open \(id.prefix(20))")
      tabsChanged()
    }
    select(id)
  }

  func select(_ id: String) {
    guard openTabIDs.contains(id), selectedTabID != id else { return }
    selectedTabID = id
    MainThreadStallMonitor.breadcrumb("tab: select \(id.prefix(20))")
  }

  /// The user closes a tab. When it was selected, the right neighbour is
  /// selected, else the left one, else nothing. Returns the new selection.
  @discardableResult
  func close(_ id: String) -> String? {
    let next = remove(id)
    if openTabIDs.isEmpty { hasClosedAllTabs = true }
    return next
  }

  /// Removes a tab (user close or prune) and moves the selection.
  @discardableResult
  private func remove(_ id: String) -> String? {
    guard let index = openTabIDs.firstIndex(of: id) else { return selectedTabID }
    openTabIDs.remove(at: index)
    editorStates[id] = nil
    sidePanelSegments[id] = nil
    MainThreadStallMonitor.breadcrumb("tab: close \(id.prefix(20))")
    if selectedTabID == id {
      selectedTabID = Self.neighbour(afterRemovingAt: index, in: openTabIDs)
      if let selectedTabID {
        MainThreadStallMonitor.breadcrumb("tab: select \(selectedTabID.prefix(20))")
      }
    }
    tabsChanged()
    return selectedTabID
  }

  /// Right neighbour (the tab that moved into `index`), else the left one.
  static func neighbour(afterRemovingAt index: Int, in remaining: [String]) -> String? {
    if remaining.indices.contains(index) { return remaining[index] }
    return remaining.last
  }

  // MARK: - Per-tab state

  func contentMode(for id: String) -> MonitoringCardContentMode {
    editorStates[id]?.contentMode ?? .terminal
  }

  func editorState(for id: String, defaultProjectPath: String) -> MonitoringEditorState {
    MonitoringEditorStateStore.state(for: id, defaultProjectPath: defaultProjectPath, in: editorStates)
  }

  func setContentMode(_ mode: MonitoringCardContentMode, for id: String, defaultProjectPath: String) {
    guard editorStates[id]?.contentMode != mode else { return }
    editorStates = MonitoringEditorStateStore.setContentMode(
      mode, for: id, defaultProjectPath: defaultProjectPath, in: editorStates)
    MainThreadStallMonitor.breadcrumb("content mode: \(mode.rawValue)")
  }

  func setSelectedFilePath(_ path: String?, for id: String, defaultProjectPath: String) {
    editorStates = MonitoringEditorStateStore.setSelectedFilePath(
      path, for: id, defaultProjectPath: defaultProjectPath, in: editorStates)
  }

  /// Cmd+click on a file path in a terminal: show it in that tab's Files view.
  func openFile(_ filePath: String, lineNumber: Int?, projectPath: String, for id: String) {
    editorStates = MonitoringEditorStateStore.openFile(
      filePath, lineNumber: lineNumber, projectPath: projectPath, for: id, in: editorStates)
    MainThreadStallMonitor.breadcrumb("content mode: \(MonitoringCardContentMode.editor.rawValue)")
  }

  func sidePanelSegment(for id: String) -> SidePanelSegment {
    sidePanelSegments[id] ?? .diff
  }

  func setSidePanelSegment(_ segment: SidePanelSegment, for id: String) {
    guard sidePanelSegments[id] != segment else { return }
    sidePanelSegments[id] = segment
    MainThreadStallMonitor.breadcrumb("side panel: \(segment.rawValue)")
  }

  // MARK: - Pending → resolved

  /// Renames tabs of launching sessions to their real ids, in place. When the
  /// real session already has a tab, the pending tab is dropped instead.
  func migrateResolvedPendingSessions(_ history: [UUID: String], provider: SessionProviderKind) {
    var changed = false
    for (pendingID, sessionID) in history {
      let pendingTabID = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      guard let index = openTabIDs.firstIndex(of: pendingTabID) else { continue }
      let resolvedTabID = SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID)
      if openTabIDs.contains(resolvedTabID) {
        openTabIDs.remove(at: index)
      } else {
        openTabIDs[index] = resolvedTabID
      }
      editorStates[resolvedTabID] = editorStates[resolvedTabID] ?? editorStates[pendingTabID]
      sidePanelSegments[resolvedTabID] =
        sidePanelSegments[resolvedTabID] ?? sidePanelSegments[pendingTabID]
      editorStates[pendingTabID] = nil
      sidePanelSegments[pendingTabID] = nil
      if selectedTabID == pendingTabID { selectedTabID = resolvedTabID }
      changed = true
    }
    if changed { tabsChanged() }
  }

  /// Follows the window's shown session: first renames resolved pending
  /// tabs (so a resolved selection reuses its tab), then opens or selects it.
  func follow(
    primarySessionId: String?,
    resolvedHistories: [(SessionProviderKind, [UUID: String])]
  ) {
    for (provider, history) in resolvedHistories {
      migrateResolvedPendingSessions(history, provider: provider)
    }
    guard let primarySessionId else { return }
    open(primarySessionId)
  }

  /// What to show when nothing is shown yet (launch, sessions loading in).
  /// Never acts after the user closed every tab.
  func selectionUpkeep(primarySessionId: String?, availableIDs: [String]) -> SelectionUpkeep {
    guard primarySessionId == nil, !hasClosedAllTabs, !availableIDs.isEmpty else { return .none }
    if let restored = visibleTabIDs(availableIDs: Set(availableIDs)).first {
      return .select(restored)
    }
    return .selectFirstAvailable
  }

  // MARK: - Persistence

  /// Merges a provider's persisted tabs once, after its workspace state was
  /// read. Tabs opened before the read keep their place; persisted ones follow.
  func restore(_ persistedIDs: [String], provider: SessionProviderKind) {
    guard !restoredProviders.contains(provider) else { return }
    restoredProviders.insert(provider)
    let newIDs = persistedIDs.filter { !openTabIDs.contains($0) && !Self.isPending($0) }
    openTabIDs.append(contentsOf: newIDs)
    // Always report, even with nothing new: tabs opened before the read was
    // done were held back from saving until now.
    tabsChanged()
  }

  func hasRestored(_ provider: SessionProviderKind) -> Bool {
    restoredProviders.contains(provider)
  }

  /// The ids to save for one provider: its monitored tabs, in order.
  func persistedIDs(for provider: SessionProviderKind) -> [String] {
    Self.persistedIDs(in: openTabIDs, for: provider)
  }

  static func persistedIDs(in ids: [String], for provider: SessionProviderKind) -> [String] {
    let prefix = "\(provider.rawValue.lowercased())-"
    return ids.filter { $0.hasPrefix(prefix) }
  }

  static func isPending(_ id: String) -> Bool {
    id.hasPrefix("pending-")
  }

  // MARK: - Pruning

  /// Drops tabs whose session went away (archived, stopped, cancelled launch).
  /// Ids never seen this run are kept: a restored session may still be loading.
  ///
  /// Returns what the window should show next: `.show(id)` when the shown
  /// session was pruned (its visible neighbour, or nil for nothing), and
  /// `.unchanged` otherwise, including when the shown session already moved on.
  @discardableResult
  func prune(availableIDs: Set<String>, shownID: String? = nil) -> TabSelectionChange {
    everAvailableIDs.formUnion(availableIDs.intersection(openTabIDs))
    let gone = openTabIDs.filter { everAvailableIDs.contains($0) && !availableIDs.contains($0) }
    guard !gone.isEmpty else { return .unchanged }
    let visibleBefore = visibleTabIDs(availableIDs: availableIDs.union(gone))
    for id in gone {
      everAvailableIDs.remove(id)
      remove(id)
    }
    guard let shownID, gone.contains(shownID) else { return .unchanged }
    let remaining = visibleBefore.filter { !gone.contains($0) }
    let index = visibleBefore.firstIndex(of: shownID) ?? remaining.count
    let survivorsBefore = visibleBefore[..<index].filter { !gone.contains($0) }.count
    let next = Self.neighbour(afterRemovingAt: survivorsBefore, in: remaining)
    if let next { select(next) }
    return .show(next)
  }

  /// The open tabs that resolve to a session right now, in strip order.
  func visibleTabIDs(availableIDs: Set<String>) -> [String] {
    openTabIDs.filter { availableIDs.contains($0) }
  }

  // MARK: - Overflow

  /// Splits tabs into the ones that fit the strip and the overflow menu.
  /// The selected tab always stays visible: it swaps in for the last fitting tab.
  static func layout(
    tabIDs: [String],
    selectedID: String?,
    capacity: Int
  ) -> (visible: [String], overflow: [String]) {
    let capacity = max(1, capacity)
    guard tabIDs.count > capacity else { return (tabIDs, []) }
    var visible = Array(tabIDs.prefix(capacity))
    if let selectedID, !visible.contains(selectedID), tabIDs.contains(selectedID) {
      visible[capacity - 1] = selectedID
    }
    let overflow = tabIDs.filter { !visible.contains($0) }
    return (visible, overflow)
  }

  /// How many tabs fit in `width` at their minimum width.
  static func capacity(forWidth width: CGFloat, minimumTabWidth: CGFloat, spacing: CGFloat) -> Int {
    guard width > 0 else { return 1 }
    return max(1, Int((width + spacing) / (minimumTabWidth + spacing)))
  }

  private func tabsChanged() {
    onTabsChanged?(openTabIDs)
  }
}

enum TabSelectionChange: Equatable {
  case unchanged
  /// Show this session, or nothing.
  case show(String?)
}

enum SelectionUpkeep: Equatable {
  case none
  /// Show this restored tab.
  case select(String)
  /// No tab to restore: let `SessionNavigationModel.ensurePrimarySelection` pick.
  case selectFirstAvailable
}
