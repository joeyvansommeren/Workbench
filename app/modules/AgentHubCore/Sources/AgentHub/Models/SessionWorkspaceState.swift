//
//  SessionWorkspaceState.swift
//  AgentHub
//

import Foundation

/// Persisted workspace/session selection state for one CLI provider.
public struct SessionWorkspaceState: Codable, Equatable, Sendable {
  public var selectedRepositoryPaths: [String]
  public var selectedFolderPaths: [String]
  public var monitoredSessionIds: [String]
  public var archivedSessionIds: [String]
  public var ownedWorktreePaths: [String]
  public var expansionState: [String: Bool]
  /// Session tabs open in the new shell, as sidebar item ids
  /// (`SidebarSessionItemID.monitored`) of this provider, in tab order.
  /// Pending sessions are never stored: they do not survive a relaunch.
  public var openSessionTabIds: [String]

  public init(
    selectedRepositoryPaths: [String] = [],
    selectedFolderPaths: [String] = [],
    monitoredSessionIds: [String] = [],
    archivedSessionIds: [String] = [],
    ownedWorktreePaths: [String] = [],
    expansionState: [String: Bool] = [:],
    openSessionTabIds: [String] = []
  ) {
    self.selectedRepositoryPaths = selectedRepositoryPaths
    self.selectedFolderPaths = selectedFolderPaths
    self.monitoredSessionIds = monitoredSessionIds
    self.archivedSessionIds = archivedSessionIds
    self.ownedWorktreePaths = ownedWorktreePaths
    self.expansionState = expansionState
    self.openSessionTabIds = openSessionTabIds
  }
}
