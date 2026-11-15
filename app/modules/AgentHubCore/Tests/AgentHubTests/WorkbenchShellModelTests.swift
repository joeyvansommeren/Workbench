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

  @Test("Full screen is a flag; the title row clears less in full screen")
  func fullScreenLeading() {
    let model = WorkbenchShellModel()
    #expect(!model.isFullScreen)
    model.setFullScreen(true)
    #expect(model.isFullScreen)
    model.setFullScreen(false)
    #expect(!model.isFullScreen)

    let bar = ShellTitleBarMetrics.standard
    #expect(ShellLayout.toolbarLeading(sidebarVisible: true, isFullScreen: false, titleBar: bar) == 0)
    #expect(ShellLayout.toolbarLeading(sidebarVisible: true, isFullScreen: true, titleBar: bar) == 0)
    // Lights end at 79, toggle 12 pt later (91–119), row 14 pt after it.
    #expect(ShellLayout.sidebarToggleLeading(isFullScreen: false, titleBar: bar) == 91)
    #expect(ShellLayout.toolbarLeading(sidebarVisible: false, isFullScreen: false, titleBar: bar) == 133)
    #expect(ShellLayout.sidebarToggleLeading(isFullScreen: true, titleBar: bar) == 8)
    #expect(ShellLayout.toolbarLeading(sidebarVisible: false, isFullScreen: true, titleBar: bar) == 50)
  }

  @Test("The title band follows the measured title bar; the content starts 8 pt below it")
  func titleBarMetrics() {
    let model = WorkbenchShellModel()
    #expect(model.titleBar == .standard)
    #expect(ShellLayout.contentTop(titleBar: model.titleBar) == 60)
    let older = ShellTitleBarMetrics(bandHeight: 28, trafficLightsTrailing: 68)
    model.setTitleBar(older)
    #expect(model.titleBar == older)
    #expect(ShellLayout.contentTop(titleBar: older) == 36)
    #expect(ShellLayout.sidebarToggleLeading(isFullScreen: false, titleBar: older) == 80)
  }

  @Test("Title-bar measurement: the placed macOS 27 buttons give the standard metrics; hidden or implausible give nil")
  func titleBarMeasurementRule() {
    // macOS 27 after `ShellTrafficLights`, 800 pt window: close button
    // centred 26 pt from the top (y grows upward), zoom ending at x 79.
    let close = CGRect(x: 19, y: 768, width: 14, height: 12)
    let zoom = CGRect(x: 65, y: 768, width: 14, height: 12)
    func measure(
      fullScreen: Bool = false, closeHidden: Bool = false, close: CGRect = close, zoom: CGRect = zoom
    ) -> ShellTitleBarMetrics? {
      ShellTitleBarMetrics.measured(
        isFullScreen: fullScreen, isCloseButtonHidden: closeHidden,
        frameHeight: 800, closeFrame: close, zoomFrame: zoom
      )
    }
    #expect(measure() == .standard)
    // Full screen: the lights are gone, keep what the model has.
    #expect(measure(fullScreen: true) == nil)
    #expect(measure(closeHidden: true) == nil)
    // A band outside 20–60 pt (close centred 6 pt or 36 pt from the top).
    #expect(measure(close: close.offsetBy(dx: 0, dy: 20)) == nil)
    #expect(measure(close: close.offsetBy(dx: 0, dy: -10)) == nil)
    // Lights ending outside x 30–140.
    #expect(measure(zoom: zoom.offsetBy(dx: 100, dy: 0)) == nil)
    #expect(measure(zoom: zoom.offsetBy(dx: -50, dy: 0)) == nil)
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
