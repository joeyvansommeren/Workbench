//
//  WorkbenchShellModel.swift
//  AgentHub
//
//  Per-window state of the new shell: which destination is shown, and whether
//  the sidebar and the session side panel are visible.
//

import Foundation
import SwiftUI

/// The places the new shell can show in its content panel, in tab order.
public enum ShellDestination: String, CaseIterable, Sendable {
  case sessions
  case reviews
  case jira
  case linear
}

@MainActor
@Observable
final class WorkbenchShellModel {
  private(set) var destination: ShellDestination = .sessions
  private(set) var sidebarVisible = true
  /// Only toggled by ⌥⌘0 for now. P6 binds the session side panel to it.
  private(set) var sidePanelVisible = true

  init() {}

  func select(_ newDestination: ShellDestination) {
    guard newDestination != destination else { return }
    destination = newDestination
    MainThreadStallMonitor.breadcrumb("shell: \(newDestination.rawValue)")
  }

  /// Routes a legacy `selectWorkspace` request into the shell.
  func select(legacySection section: AgentHubWorkspaceSection) {
    select(LegacySectionMapper.destination(for: section))
  }

  func toggleSidebar() {
    sidebarVisible.toggle()
    MainThreadStallMonitor.breadcrumb("sidebar: \(sidebarVisible ? "shown" : "hidden")")
  }

  func toggleSidePanel() {
    sidePanelVisible.toggle()
    MainThreadStallMonitor.breadcrumb("side panel: \(sidePanelVisible ? "shown" : "hidden")")
  }
}
