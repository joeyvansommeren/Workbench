import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Workbench shell model")
struct WorkbenchShellModelTests {
  @Test("Starts on Sessions with the sidebar and side panel shown")
  func initialState() {
    let model = WorkbenchShellModel()
    #expect(model.destination == .sessions)
    #expect(model.sidebarVisible)
    #expect(model.sidePanelVisible)
  }

  @Test("The destinations are the four tabs, in order")
  func destinationOrder() {
    #expect(ShellDestination.allCases == [.sessions, .reviews, .jira, .linear])
    #expect(ShellDestination.allCases.map(\.title) == ["Sessions", "Reviews", "Jira", "Linear"])
    #expect(ShellDestination.allCases.map(\.shortcut.keyCaps) == [
      ["⌘", "1"], ["⌘", "2"], ["⌘", "3"], ["⌘", "4"],
    ])
  }

  @Test("Selecting a destination switches to it")
  func destinationSwitching() {
    let model = WorkbenchShellModel()
    for destination in [ShellDestination.reviews, .jira, .linear, .sessions, .linear] {
      model.select(destination)
      #expect(model.destination == destination)
    }
  }

  @Test(
    "Legacy sections map onto shell destinations",
    arguments: [
      (AgentHubWorkspaceSection.workflows, ShellDestination.sessions),
      (.sessions, .sessions),
      (.reviews, .reviews),
      (.sprint, .jira),
      (.linear, .linear),
    ]
  )
  func legacyMapping(section: AgentHubWorkspaceSection, destination: ShellDestination) {
    #expect(LegacySectionMapper.destination(for: section) == destination)
  }

  @Test("A legacy Sprint request opens Jira; a legacy Linear request opens Linear")
  func legacyTrackerRequests() {
    let model = WorkbenchShellModel()
    model.select(legacySection: .linear)
    #expect(model.destination == .linear)
    model.select(legacySection: .sprint)
    #expect(model.destination == .jira)
    model.select(legacySection: .workflows)
    #expect(model.destination == .sessions)
  }

  @Test("Sidebar and side panel toggle independently")
  func toggles() {
    let model = WorkbenchShellModel()
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

  @Test("Title-bar double-click follows the system preference")
  func titleBarDoubleClickPreference() {
    #expect(TitleBarDoubleClickAction.from(preference: nil) == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Maximize") == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Fill") == .zoom)
    #expect(TitleBarDoubleClickAction.from(preference: "Minimize") == .minimize)
    #expect(TitleBarDoubleClickAction.from(preference: "None") == .none)
  }
}
