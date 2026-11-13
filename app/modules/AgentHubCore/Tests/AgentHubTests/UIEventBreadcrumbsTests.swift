import Foundation
import Testing

@testable import AgentHubCore

@Suite("UI event breadcrumbs")
struct UIEventBreadcrumbsTests {
  @Test("A double-click in the top strip is reported as the title bar")
  func doubleClickInTitleBar() {
    let text = UIEventBreadcrumbs.doubleClickBreadcrumb(
      hitViewClass: "NSTitlebarView", parentClass: "NSThemeFrame",
      x: 412.4, distanceFromTop: 12, titleBarHeight: 28)
    #expect(text == "double-click in title bar on NSTitlebarView in NSThemeFrame at x 412, 12 pt from top")
  }

  @Test("A double-click below the title bar is reported as content")
  func doubleClickInContent() {
    let text = UIEventBreadcrumbs.doubleClickBreadcrumb(
      hitViewClass: "NSTableView", parentClass: nil,
      x: 900, distanceFromTop: 240.6, titleBarHeight: 28)
    #expect(text == "double-click in content on NSTableView at x 900, 241 pt from top")
  }

  @Test("A double-click that hits no view still produces a breadcrumb")
  func doubleClickOnNothing() {
    let text = UIEventBreadcrumbs.doubleClickBreadcrumb(
      hitViewClass: nil, parentClass: nil, x: 0, distanceFromTop: 50, titleBarHeight: 0)
    #expect(text == "double-click in content on nothing at x 0, 50 pt from top")
  }

  @Test("Window breadcrumbs carry the window size when there is one")
  func windowBreadcrumbSize() {
    #expect(
      UIEventBreadcrumbs.windowBreadcrumb("window resized by dragging", size: CGSize(width: 1885, height: 1099.4))
        == "window resized by dragging: 1885×1099")
    #expect(UIEventBreadcrumbs.windowBreadcrumb("window left full screen", size: nil) == "window left full screen")
  }
}

@Suite("Main thread stall monitor breadcrumbs", .serialized)
struct MainThreadStallMonitorBreadcrumbTests {
  @Test("Keeps only the most recent breadcrumbs, oldest first, with a millisecond timestamp")
  func keepsMostRecentBreadcrumbs() throws {
    let marker = UUID().uuidString
    let total = MainThreadStallMonitor.breadcrumbCapacity + 5
    for index in 0..<total {
      MainThreadStallMonitor.breadcrumb("\(marker) \(index)")
    }

    let recent = MainThreadStallMonitor.recentBreadcrumbs()
    #expect(recent.count == MainThreadStallMonitor.breadcrumbCapacity)
    #expect(recent.first?.hasSuffix("\(marker) 5") == true)
    #expect(recent.last?.hasSuffix("\(marker) \(total - 1)") == true)

    let timestamp = try #require(recent.last?.split(separator: " ").first)
    #expect(timestamp.wholeMatch(of: #/\d{2}:\d{2}:\d{2}\.\d{3}/#) != nil)
  }
}
