//
//  SessionDetailStateModel.swift
//  AgentHub
//
//  Per-window state of the Sessions detail: each session's content mode,
//  Files state and side-panel segment, the side-panel auto-open bookkeeping,
//  and which session to show when nothing is shown yet.
//
//  The Sessions destination shows one session: the one selected in the
//  sidebar (`SessionNavigationModel.primarySessionId`). `ShownSessionSync`
//  reports every change here, so the last shown session is saved and shown
//  again after a relaunch.
//

import Foundation

@MainActor
@Observable
final class SessionDetailStateModel {
  /// Content mode (Terminal, Chat, Files, Diffs), Files project and open
  /// file per session. Same store the legacy panel uses.
  private(set) var editorStates: [String: MonitoringEditorState] = [:]
  /// Side-panel segment per session.
  private(set) var sidePanelSegments: [String: SidePanelSegment] = [:]

  /// Identifies this window's entry in the cross-window saved list
  /// (`OpenSessionTabsAggregate`).
  let windowID = UUID()

  /// Called with the shown session id each time it changes, for saving.
  /// Pending launches are never reported.
  @ObservationIgnored var onShownChanged: ((String) -> Void)?

  /// Side-panel auto-open bookkeeping (edits and plan), per window so it
  /// survives switching sessions.
  @ObservationIgnored var autoOpen = SidePanelAutoOpenTracker()

  /// Sessions shown at the last run, in saved order. Preferred by the
  /// selection upkeep once they load.
  @ObservationIgnored private(set) var restoredIDs: [String] = []
  @ObservationIgnored private var restoredProviders: Set<SessionProviderKind> = []
  @ObservationIgnored private var lastReportedID: String?
  /// Ids that resolved to a session at least once. A shown id that is not
  /// available only counts as gone once it was seen, so a session that is
  /// still loading (restore, pending → resolved) is never replaced.
  @ObservationIgnored private var everAvailableIDs: Set<String> = []

  init() {}

  // MARK: - Per-session state

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

  /// Cmd+click on a file path in a terminal: show it in that session's Files view.
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

  /// A launching session keeps its content mode and side-panel segment when
  /// it takes its real id.
  func migrateResolvedPendingSessions(_ history: [UUID: String], provider: SessionProviderKind) {
    for (pendingID, sessionID) in history {
      let pendingKey = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      guard editorStates[pendingKey] != nil || sidePanelSegments[pendingKey] != nil else { continue }
      let resolvedKey = SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID)
      editorStates[resolvedKey] = editorStates[resolvedKey] ?? editorStates[pendingKey]
      sidePanelSegments[resolvedKey] = sidePanelSegments[resolvedKey] ?? sidePanelSegments[pendingKey]
      editorStates[pendingKey] = nil
      sidePanelSegments[pendingKey] = nil
    }
  }

  // MARK: - Shown session

  /// Follows the window's shown session and reports it for saving.
  func show(_ id: String?) {
    guard let id, !Self.isPending(id), id != lastReportedID else { return }
    lastReportedID = id
    onShownChanged?(id)
  }

  /// What to show next. Acts while nothing is shown (launch, sessions still
  /// loading) and when the shown session went away (archived, stopped,
  /// cancelled launch).
  func selectionUpkeep(primarySessionId: String?, availableIDs: [String]) -> SelectionUpkeep {
    let available = Set(availableIDs)
    everAvailableIDs.formUnion(available)
    guard !availableIDs.isEmpty else { return .none }
    if let primarySessionId {
      let isGone = !available.contains(primarySessionId) && everAvailableIDs.contains(primarySessionId)
      return isGone ? .selectFirstAvailable : .none
    }
    if let restored = restoredIDs.first(where: available.contains) {
      return .select(restored)
    }
    return .selectFirstAvailable
  }

  // MARK: - Persistence

  /// Takes a provider's saved ids once, after its workspace state was read.
  func restore(_ persistedIDs: [String], provider: SessionProviderKind) {
    guard !restoredProviders.contains(provider) else { return }
    restoredProviders.insert(provider)
    restoredIDs.append(contentsOf: persistedIDs.filter { !restoredIDs.contains($0) && !Self.isPending($0) })
    // Report again: the read replaced whatever was reported before it.
    if let lastReportedID { onShownChanged?(lastReportedID) }
  }

  func hasRestored(_ provider: SessionProviderKind) -> Bool {
    restoredProviders.contains(provider)
  }

  /// The ids to save for one provider, in order.
  static func persistedIDs(in ids: [String], for provider: SessionProviderKind) -> [String] {
    let prefix = "\(provider.rawValue.lowercased())-"
    return ids.filter { $0.hasPrefix(prefix) }
  }

  static func isPending(_ id: String) -> Bool {
    id.hasPrefix("pending-")
  }
}

enum SelectionUpkeep: Equatable {
  case none
  /// Show this session shown at the last run.
  case select(String)
  /// Let `SessionNavigationModel.ensurePrimarySelection` pick (newest first).
  case selectFirstAvailable
}
