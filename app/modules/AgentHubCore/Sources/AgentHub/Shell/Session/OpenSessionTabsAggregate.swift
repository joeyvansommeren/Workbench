//
//  OpenSessionTabsAggregate.swift
//  AgentHub
//
//  One provider's saved tab list when several windows are open. Rule: the
//  saved list is the ordered union of every window's tabs this run (window
//  order, then tab order). So a window never drops another window's tabs, and
//  a tab the user closed is saved only while another window still has it open.
//
//  A closed window's list stays in the union for the rest of the run (closing
//  the last window must not wipe the saved tabs on quit); the next new window
//  opens those tabs again.
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
