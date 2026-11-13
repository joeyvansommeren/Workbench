//
//  WorkbenchShellModel.swift
//  AgentHub
//
//  Per-window state of the new shell: which destination is shown, and whether
//  the sidebar and the session side panel are visible.
//

import AgentWorkflowJiraCLI
import Foundation
import SwiftUI

/// The three places the new shell can show in its content panel.
public enum ShellDestination: String, CaseIterable, Sendable {
  case sessions
  case reviews
  case sprint
}

/// Which tracker the Sprint destination shows.
public enum SprintTracker: String, CaseIterable, Sendable, CustomStringConvertible {
  case jira
  case linear

  public var description: String {
    switch self {
    case .jira: return "Jira"
    case .linear: return "Linear"
    }
  }
}

@MainActor
@Observable
final class WorkbenchShellModel {
  private(set) var destination: ShellDestination = .sessions
  private(set) var sidebarVisible = true
  /// Only toggled by ⌥⌘0 for now. P6 binds the session side panel to it.
  private(set) var sidePanelVisible = true
  private(set) var sprintTracker: SprintTracker

  @ObservationIgnored private let defaults: UserDefaults

  /// - Parameter isJiraCLIAvailable: asked only when no tracker is saved yet:
  ///   Sprint opens on Jira when `acli` is installed, else on Linear.
  init(
    defaults: UserDefaults = .standard,
    isJiraCLIAvailable: () -> Bool = JiraCLIProcessRunner.isInstalled
  ) {
    self.defaults = defaults
    self.sprintTracker =
      defaults.string(forKey: AgentHubDefaults.sprintTracker)
      .flatMap(SprintTracker.init(rawValue:)) ?? (isJiraCLIAvailable() ? .jira : .linear)
  }

  func select(_ newDestination: ShellDestination) {
    guard newDestination != destination else { return }
    destination = newDestination
    MainThreadStallMonitor.breadcrumb("shell: \(newDestination.rawValue)")
  }

  /// Routes a legacy `selectWorkspace` request into the shell.
  func select(legacySection section: AgentHubWorkspaceSection) {
    let target = LegacySectionMapper.target(for: section)
    if let tracker = target.sprintTracker {
      setSprintTracker(tracker)
    }
    select(target.destination)
  }

  func toggleSidebar() {
    sidebarVisible.toggle()
    MainThreadStallMonitor.breadcrumb("sidebar: \(sidebarVisible ? "shown" : "hidden")")
  }

  func toggleSidePanel() {
    sidePanelVisible.toggle()
    MainThreadStallMonitor.breadcrumb("side panel: \(sidePanelVisible ? "shown" : "hidden")")
  }

  func setSprintTracker(_ tracker: SprintTracker) {
    guard tracker != sprintTracker else { return }
    sprintTracker = tracker
    defaults.set(tracker.rawValue, forKey: AgentHubDefaults.sprintTracker)
    MainThreadStallMonitor.breadcrumb("sprint tracker: \(tracker.rawValue)")
  }
}
