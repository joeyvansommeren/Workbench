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
  /// From the window's full-screen notifications (`ShellWindowChrome`). The
  /// traffic lights hide in full screen, so the title row needs less room.
  private(set) var isFullScreen = false
  /// Where AppKit puts the traffic lights (`ShellWindowChrome`, measured at
  /// window hookup). The title band follows them.
  private(set) var titleBar = ShellTitleBarMetrics.standard
  /// Set when the side panel opens, consumed when it appears: only that
  /// appearance fades in (motion plan item 6). Not observed: reading or
  /// consuming it must not re-render anything.
  @ObservationIgnored var sidePanelEntrance = PanelEntranceGate()

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

  func setFullScreen(_ isFullScreen: Bool) {
    guard isFullScreen != self.isFullScreen else { return }
    self.isFullScreen = isFullScreen
  }

  func setTitleBar(_ metrics: ShellTitleBarMetrics) {
    guard metrics != titleBar else { return }
    titleBar = metrics
  }

  func toggleSidePanel() {
    sidePanelVisible.toggle()
    if sidePanelVisible {
      sidePanelEntrance.panelOpened()
    } else {
      sidePanelEntrance.panelClosed()
    }
    MainThreadStallMonitor.breadcrumb("side panel: \(sidePanelVisible ? "shown" : "hidden")")
  }
}
