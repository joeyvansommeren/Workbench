import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Workbench shell model")
struct WorkbenchShellModelTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "WorkbenchShellModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("Starts on Sessions with the sidebar and side panel shown")
  func initialState() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    #expect(model.destination == .sessions)
    #expect(model.sidebarVisible)
    #expect(model.sidePanelVisible)
    #expect(model.sprintTracker == .jira)
  }

  @Test("Selecting a destination switches to it")
  func destinationSwitching() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    for destination in [ShellDestination.reviews, .sprint, .sessions, .sprint] {
      model.select(destination)
      #expect(model.destination == destination)
    }
  }

  @Test(
    "Legacy sections map onto shell destinations",
    arguments: [
      (AgentHubWorkspaceSection.workflows, ShellDestination.sessions, SprintTracker?.none),
      (.sessions, .sessions, nil),
      (.reviews, .reviews, nil),
      (.sprint, .sprint, .jira),
      (.linear, .sprint, .linear),
    ]
  )
  func legacyMapping(
    section: AgentHubWorkspaceSection,
    destination: ShellDestination,
    tracker: SprintTracker?
  ) {
    let target = LegacySectionMapper.target(for: section)
    #expect(target.destination == destination)
    #expect(target.sprintTracker == tracker)
  }

  @Test("A legacy Linear request opens Sprint on the Linear tracker")
  func legacyLinearSelectsTracker() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    model.select(legacySection: .linear)
    #expect(model.destination == .sprint)
    #expect(model.sprintTracker == .linear)

    model.select(legacySection: .sprint)
    #expect(model.sprintTracker == .jira)
  }

  @Test("A legacy request without a tracker keeps the current tracker")
  func legacyReviewsKeepsTracker() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    model.setSprintTracker(.linear)
    model.select(legacySection: .reviews)
    model.select(legacySection: .workflows)
    #expect(model.destination == .sessions)
    #expect(model.sprintTracker == .linear)
  }

  @Test("Sidebar and side panel toggle independently")
  func toggles() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    model.toggleSidebar()
    #expect(!model.sidebarVisible)
    #expect(model.sidePanelVisible)
    model.toggleSidePanel()
    #expect(!model.sidePanelVisible)
    model.toggleSidebar()
    model.toggleSidePanel()
    #expect(model.sidebarVisible)
    #expect(model.sidePanelVisible)
  }

  @Test("The tracker is persisted and restored")
  func trackerPersisted() {
    let defaults = makeDefaults()
    let model = WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true })
    model.setSprintTracker(.linear)
    #expect(defaults.string(forKey: AgentHubDefaults.sprintTracker) == "linear")

    let restored = WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true })
    #expect(restored.sprintTracker == .linear)
  }

  @Test("Title-bar double-click follows the system preference")
  func titleBarDoubleClickPreference() {
    #expect(TitleBarDoubleClickAction.from(preference: nil) == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Maximize") == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Fill") == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Minimize") == .minimize)
    #expect(TitleBarDoubleClickAction.from(preference: "None") == .none)
  }

  @Test("An unknown stored tracker falls back to Jira")
  func unknownTrackerFallsBack() {
    let defaults = makeDefaults()
    defaults.set("trello", forKey: AgentHubDefaults.sprintTracker)
    #expect(WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true }).sprintTracker == .jira)
  }
}
