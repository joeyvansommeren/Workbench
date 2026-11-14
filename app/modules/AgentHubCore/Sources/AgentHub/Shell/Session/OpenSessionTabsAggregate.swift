//
//  OpenSessionTabsAggregate.swift
//  AgentHub
//
//  One provider's saved session list when several windows are open. Each
//  window reports the session it shows (P6 reported its open tabs; the name
//  stays). Rule: the saved list is the ordered union of every window's ids
//  this run, so a window never drops another window's session.
//
//  A closed window's entry stays in the union for the rest of the run
//  (closing the last window must not wipe the saved session on quit).
//

import Foundation

struct OpenSessionTabsAggregate: Equatable {
  private var windowOrder: [UUID] = []
  private var idsByWindow: [UUID: [String]] = [:]

  /// Records a window's current tabs and returns the new union.
  mutating func update(window: UUID, ids: [String]) -> [String] {
    if idsByWindow[window] == nil { windowOrder.append(window) }
    idsByWindow[window] = ids
    return union
  }

  var union: [String] {
    var seen: Set<String> = []
    return windowOrder.flatMap { idsByWindow[$0] ?? [] }.filter { seen.insert($0).inserted }
  }
}
