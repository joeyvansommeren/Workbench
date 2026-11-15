//
//  SidePanelAutoOpenTracker.swift
//  AgentHub
//
//  The legacy panel's side-panel auto-open bookkeeping
//  (`MultiProviderMonitoringPanelView.openAutoSidePanelIfNeeded`), as a pure
//  value for the new shell. The trigger rules stay in
//  `MonitoringAutoOpenSidePanelPolicy`; this decides whether a candidate
//  opens, with the same rules:
//
//  - a key opens at most once;
//  - triggers already present when the window first showed sessions (or when
//    a session is first seen with old activity) never open;
//  - auto-open only replaces nothing or another auto-opened panel (Edits,
//    Plan), never a panel the user picked.
//

import Foundation

struct SidePanelAutoOpenTracker {
  private(set) var baselineDate: Date?
  private(set) var openedKeys: Set<MonitoringAutoOpenSidePanelKey> = []
  private var observedKeysBySessionID: [String: Set<MonitoringAutoOpenSidePanelKey>] = [:]

  /// Starts the baseline once and marks every current trigger as observed.
  mutating func start(now: Date = Date(), items: [MonitoringAutoOpenSidePanelItem]) {
    if baselineDate == nil { baselineDate = now }
    for item in items where item.state != nil {
      observedKeysBySessionID[item.session.id, default: []]
        .formUnion(MonitoringAutoOpenSidePanelPolicy.keys(for: item))
    }
  }

  func candidate(for item: MonitoringAutoOpenSidePanelItem?) -> MonitoringAutoOpenSidePanelCandidate? {
    MonitoringAutoOpenSidePanelPolicy.candidate(
      activeModuleLandingPath: nil,
      visibleItem: item,
      openedKeys: openedKeys,
      detectedAfter: baselineDate
    )
  }

  /// Decides whether `candidate` opens. `shownSegment` is the side panel's
  /// current segment, or nil when the panel is hidden. Returns the segment to
  /// show, or nil to leave the panel alone.
  mutating func decide(
    _ candidate: MonitoringAutoOpenSidePanelCandidate,
    shownSegment: SidePanelSegment?
  ) -> SidePanelSegment? {
    let sessionID = candidate.session.id
    if let observed = observedKeysBySessionID[sessionID] {
      guard !observed.contains(candidate.key) else { return nil }
    } else if suppressesFirstObserved(candidate) {
      observedKeysBySessionID[sessionID, default: []].insert(candidate.key)
      return nil
    }

    openedKeys.insert(candidate.key)
    observedKeysBySessionID[sessionID, default: []].insert(candidate.key)

    // Never replace a panel the user opened deliberately.
    if let shownSegment, !Self.isAutoOpenable(shownSegment) { return nil }

    switch candidate.target {
    case .edits: return .edits
    case .plan: return .plan
    }
  }

  /// Forgets sessions that are gone.
  mutating func prune(activeSessionIDs: Set<String>) {
    openedKeys = openedKeys.filter { activeSessionIDs.contains($0.sessionID) }
    observedKeysBySessionID = observedKeysBySessionID.filter { activeSessionIDs.contains($0.key) }
  }

  static func isAutoOpenable(_ segment: SidePanelSegment) -> Bool {
    segment == .edits || segment == .plan
  }

  private func suppressesFirstObserved(_ candidate: MonitoringAutoOpenSidePanelCandidate) -> Bool {
    guard let baselineDate else { return true }
    return candidate.session.lastActivityAt <= baselineDate
  }
}
