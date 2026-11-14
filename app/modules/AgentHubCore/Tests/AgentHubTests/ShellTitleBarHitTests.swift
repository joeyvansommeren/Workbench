import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

/// Regression test for the title row (release blocker, 2026-11-14): in the
/// real window no control in the title row took a click.
///
/// Cause: with an `NSToolbar` (P12 used one for the 52 pt bar), AppKit sends
/// a mouse-down under the titlebar to the content only inside the region the
/// content's hosting view reports as opaque. SwiftUI reports a region without
/// the row's controls once the content has composited layers (the content
/// panel's clip and shadow), so every click in the band became a window
/// drag. Shell/README.md, "Title row clicks", has the trace.
///
/// The window is built the way the app's `WindowGroup` builds it under
/// `.windowStyle(.hiddenTitleBar)`: an `NSHostingController` as the content
/// view controller (SwiftUI toolbars bridged to the window, as a scene does),
/// full-size content view, transparent titlebar, hidden title. The content is
/// the real `ShellFrame` with the real `ShellToolbar`; only the sidebar and
/// detail slots are stubbed. Clicks go through `NSWindow.sendEvent(_:)`, so
/// AppKit's titlebar routing runs exactly as for a real click.
///
/// Controls are found by clicking along the row and watching the models:
/// SwiftUI builds no accessibility tree in a headless test.
@MainActor
@Suite("Shell title bar hit testing", .serialized)
struct ShellTitleBarHitTests {
  @Test("The window has no NSToolbar")
  func noToolbar() throws {
    let host = try ShellTitleBarTestWindow(width: 1440)
    defer { host.close() }
    // A toolbar makes AppKit route band clicks by SwiftUI's opaque region,
    // which drops the row's controls (see the suite comment).
    #expect(host.window.toolbar == nil)
  }

  @Test("Clicks on the destination tabs switch the destination", arguments: [1440.0, 900.0])
  func tabsReceiveClicks(width: Double) throws {
    let host = try ShellTitleBarTestWindow(width: width)
    defer { host.close() }
    let centres = host.tabCentres()
    for destination in ShellDestination.allCases {
      let centre = try #require(centres[destination], "no click selected the \(destination.title) tab at \(width) pt")
      host.expectHitLandsInContent(at: centre, "\(destination.title) tab")
      host.shellModel.select(destination == .sessions ? .linear : .sessions)
      host.click(at: centre)
      #expect(host.shellModel.destination == destination, "click on the centre of the \(destination.title) tab")
    }
  }

  @Test("A click on Search opens the palette", arguments: [1440.0, 900.0])
  func searchReceivesClicks(width: Double) throws {
    let host = try ShellTitleBarTestWindow(width: width)
    defer { host.close() }
    let centre = try #require(host.searchCentre(), "no click opened the palette at \(width) pt")
    host.expectHitLandsInContent(at: centre, "Search")
    host.overlays.closePalette()
    host.click(at: centre)
    #expect(host.overlays.isPaletteOpen)
  }

  @Test("A click on the sidebar toggle hides and shows the sidebar", arguments: [1440.0, 900.0])
  func sidebarToggleReceivesClicks(width: Double) throws {
    let host = try ShellTitleBarTestWindow(width: width)
    defer { host.close() }
    let centre = try #require(host.sidebarToggleCentre(), "no click toggled the sidebar at \(width) pt")
    host.click(at: centre)
    #expect(!host.shellModel.sidebarVisible)
    // The toggle stays put when the sidebar hides.
    host.click(at: centre)
    #expect(host.shellModel.sidebarVisible)
  }

  @Test("The empty bar drags the window and a double-click zooms it")
  func emptyBarActsAsTitleBar() throws {
    let host = try ShellTitleBarTestWindow(width: 1440)
    defer { host.close() }
    // Between the last tab and Search: no control there.
    let point = host.bandPoint(x: 800)
    let hit = host.frameViewHit(at: point)
    #expect(hit?.mouseDownCanMoveWindow == true, "empty bar hit \(String(describing: hit)) cannot move the window")
    host.doubleClick(at: point)
    #expect(host.zoomRequests == 1, "a double-click on the empty bar must zoom")
  }

  @Test("Traffic lights, toggle, tabs and Search share one centre line", arguments: [1440.0, 900.0])
  func oneLine(width: Double) throws {
    let host = try ShellTitleBarTestWindow(width: width)
    defer { host.close() }
    // The band follows the real window buttons, measured at hookup.
    let measured = try #require(ShellTitleBarMetrics.measured(in: host.window))
    #expect(host.shellModel.titleBar == measured)
    let lightsLine = host.trafficLightsCentreFromTop()

    // Each control's clickable run, swept top to bottom: its middle is the
    // control's centre line.
    let tabs = host.tabCentres()
    let reviews = try #require(tabs[.reviews])
    let tabLine = try #require(host.verticalCentre(atX: reviews.x) {
      host.shellModel.select(.sessions)
    } hit: { host.shellModel.destination == .reviews })
    #expect(abs(tabLine - lightsLine) <= 1, "tabs centred \(tabLine) pt from the top, lights \(lightsLine)")

    let search = try #require(host.searchCentre())
    let searchLine = try #require(host.verticalCentre(atX: search.x) {
      host.overlays.closePalette()
    } hit: { host.overlays.isPaletteOpen })
    #expect(abs(searchLine - lightsLine) <= 1, "Search centred \(searchLine) pt from the top, lights \(lightsLine)")

    let toggle = try #require(host.sidebarToggleCentre())
    let toggleLine = try #require(host.verticalCentre(atX: toggle.x) {
      if !host.shellModel.sidebarVisible { host.shellModel.toggleSidebar() }
    } hit: { !host.shellModel.sidebarVisible })
    #expect(abs(toggleLine - lightsLine) <= 1, "toggle centred \(toggleLine) pt from the top, lights \(lightsLine)")

    // Nothing overlaps the lights: the toggle starts the prototype's 12 pt
    // after the zoom button.
    let zoom = try #require(host.window.standardWindowButton(.zoomButton))
    let toggleLeading = toggle.x - DesignTokens.Size.control / 2
    #expect(abs(toggleLeading - (zoom.convert(zoom.bounds, to: nil).maxX + ShellLayout.trafficLightsToToggleGap)) <= 4)
  }

  @Test("In full screen the toggle moves to the edge and the row still takes clicks")
  func fullScreenRow() throws {
    let host = try ShellTitleBarTestWindow(width: 1440)
    defer { host.close() }
    // A real full-screen window takes over the display, so this sets what
    // full screen changes: the lights hide and the model's flag flips.
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      host.window.standardWindowButton(button)?.isHidden = true
    }
    host.shellModel.setFullScreen(true)
    host.settle()
    let toggle = try #require(host.sidebarToggleCentre(from: 2), "no click toggled the sidebar in full screen")
    #expect(abs(toggle.x - (ShellLayout.fullScreenSidebarToggleLeading + DesignTokens.Size.control / 2)) <= 4)
    // Sidebar hidden: the tabs start right after the toggle.
    host.click(at: toggle)
    #expect(!host.shellModel.sidebarVisible)
    let tabs = host.tabCentres(from: ShellLayout.toolbarLeading(
      sidebarVisible: false, isFullScreen: true, titleBar: host.shellModel.titleBar))
    for destination in ShellDestination.allCases {
      #expect(tabs[destination] != nil, "no click selected the \(destination.title) tab in full screen")
    }
  }
}

/// A window configured like the app's main window, ordered in offscreen.
@MainActor
private final class ShellTitleBarTestWindow: NSObject, NSWindowDelegate {
  let window: NSWindow
  let shellModel = WorkbenchShellModel()
  let overlays = ShellOverlayModel()
  private(set) var zoomRequests = 0

  init(width: Double) throws {
    let content = ShellFrame(
      sidebar: { Color.clear.frame(width: DesignTokens.Width.sidebar) },
      toolbar: { ShellToolbar() },
      detail: { Color.clear }
    )
    .frame(minWidth: ShellLayout.windowMinWidth, minHeight: ShellLayout.windowMinHeight)
    .environment(shellModel)
    .environment(overlays)
    let controller = NSHostingController(rootView: AnyView(content))
    // What a scene does for its hosting controller: SwiftUI toolbars, if
    // any, become the window's `NSToolbar`.
    controller.sceneBridgingOptions = [.toolbars, .title]
    // `.windowStyle(.hiddenTitleBar)`.
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    super.init()
    window.delegate = self
    window.setContentSize(CGSize(width: width, height: 800))
    // Offscreen, so the run never shows a window on the user's display.
    window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    settle()
  }

  func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
    zoomRequests += 1
    return false
  }

  func close() {
    window.orderOut(nil)
    window.delegate = nil
    window.contentViewController = nil
    window.close()
  }

  /// Lets SwiftUI and AppKit finish layout and animations.
  func settle(turns: Int = 5) {
    for _ in 0..<turns {
      window.contentView?.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    }
  }

  /// A point at `x`, `fromTop` points below the window's top edge (default:
  /// the title band's centre line), in window coordinates.
  func bandPoint(x: CGFloat, fromTop: CGFloat? = nil) -> CGPoint {
    CGPoint(x: x, y: window.frame.height - (fromTop ?? shellModel.titleBar.bandHeight / 2))
  }

  /// The close button's centre, in points below the window's top edge.
  func trafficLightsCentreFromTop() -> CGFloat {
    guard let close = window.standardWindowButton(.closeButton) else { return .nan }
    return window.frame.height - close.convert(close.bounds, to: nil).midY
  }

  // MARK: - Finding controls by clicking

  /// Clicks down a column at `x`, from the window's top edge to 20 pt below
  /// the band; the middle of the longest run where `hit` became true, in
  /// points below the top edge. `reset` runs before every click.
  func verticalCentre(atX x: CGFloat, reset: () -> Void, hit: () -> Bool) -> CGFloat? {
    var ys: [CGFloat] = []
    for fromTop in stride(from: 1, through: shellModel.titleBar.bandHeight + 20, by: 1) {
      reset()
      settle(turns: 1)
      click(at: bandPoint(x: x, fromTop: fromTop), turns: 2)
      if hit() { ys.append(fromTop) }
    }
    reset()
    settle()
    return Self.centreOfLongestRun(ys, step: 1)
  }

  /// Clicks along the tab strip; the centre of each run of points that
  /// selected a destination.
  func tabCentres(from start: CGFloat = DesignTokens.Width.sidebar) -> [ShellDestination: CGPoint] {
    var hits: [ShellDestination: [CGFloat]] = [:]
    let end = min(window.frame.width - 200, start + 560)
    // Two passes, so every tab, the selected one included, is found.
    for baseline in [ShellDestination.linear, .sessions] {
      for x in stride(from: start + 2, through: end, by: 6) {
        shellModel.select(baseline)
        click(at: bandPoint(x: x), turns: 2)
        if shellModel.destination != baseline { hits[shellModel.destination, default: []].append(x) }
      }
    }
    shellModel.select(.sessions)
    settle()
    return hits.compactMapValues { xs in Self.centreOfLongestRun(xs, step: 6).map { bandPoint(x: $0) } }
  }

  /// Clicks leftward from the window's trailing edge until Search opens the
  /// palette; the centre of the points that did.
  func searchCentre() -> CGPoint? {
    var xs: [CGFloat] = []
    for x in stride(from: window.frame.width - 4, through: window.frame.width - 440, by: -6) {
      overlays.closePalette()
      click(at: bandPoint(x: x), turns: 2)
      if overlays.isPaletteOpen { xs.append(x) }
    }
    overlays.closePalette()
    settle()
    return Self.centreOfLongestRun(xs, step: 6).map { bandPoint(x: $0) }
  }

  /// Clicks right of the traffic lights (never on them: that would close the
  /// window) until the sidebar hides; the centre of the points that did.
  /// Pass `from` only while the lights are hidden.
  func sidebarToggleCentre(from explicitStart: CGFloat? = nil) -> CGPoint? {
    guard let zoom = window.standardWindowButton(.zoomButton) else { return nil }
    let start = explicitStart ?? (zoom.convert(zoom.bounds, to: nil).maxX + 4)
    var xs: [CGFloat] = []
    for x in stride(from: start, through: start + 120, by: 4) {
      click(at: bandPoint(x: x), turns: 2)
      if !shellModel.sidebarVisible {
        xs.append(x)
        shellModel.toggleSidebar()
        settle()
      }
    }
    return Self.centreOfLongestRun(xs, step: 4).map { bandPoint(x: $0) }
  }

  /// The middle of the longest run of neighbouring sweep points, so one stray
  /// hit cannot pull the centre off the control.
  static func centreOfLongestRun(_ xs: [CGFloat], step: CGFloat) -> CGFloat? {
    var runs: [[CGFloat]] = []
    for x in xs.sorted() {
      if let last = runs.last?.last, x - last <= step + 0.5 {
        runs[runs.count - 1].append(x)
      } else {
        runs.append([x])
      }
    }
    guard let longest = runs.max(by: { $0.count < $1.count }) else { return nil }
    return (longest.first! + longest.last!) / 2
  }

  // MARK: - Hit testing and events

  /// The view AppKit's frame view (the window's root view) resolves for a
  /// click at `point` (window coordinates).
  func frameViewHit(at point: CGPoint) -> NSView? {
    guard let frameView = window.contentView?.superview else { return nil }
    // The frame view has no superview; its hit test takes window coordinates.
    return frameView.hitTest(point)
  }

  func expectHitLandsInContent(at point: CGPoint, _ what: String) {
    let hit = frameViewHit(at: point)
    let inContent = hit.map { view in window.contentView.map { view.isDescendant(of: $0) } ?? false } ?? false
    #expect(inContent, "\(what) at \(point): the frame view resolves \(String(describing: hit)), not the hosting view")
  }

  func click(at point: CGPoint, turns: Int = 5) {
    send(at: point, clickCount: 1)
    settle(turns: turns)
  }

  func doubleClick(at point: CGPoint) {
    // The pair a real double-click delivers. The first click starts a
    // window drag that ends at once on its queued mouse-up.
    send(at: point, clickCount: 1)
    send(at: point, clickCount: 2)
    settle()
  }

  private func send(at point: CGPoint, clickCount: Int) {
    let down = mouseEvent(.leftMouseDown, at: point, clickCount: clickCount)
    let up = mouseEvent(.leftMouseUp, at: point, clickCount: clickCount)
    // Queue the mouse-up first: if the mouse-down starts a tracking loop (a
    // window drag), the loop ends on this event instead of waiting.
    NSApplication.shared.postEvent(up, atStart: false)
    window.sendEvent(down)
    if let pending = NSApplication.shared.nextEvent(
      matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true
    ) {
      window.sendEvent(pending)
    }
  }

  private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: clickCount,
      pressure: type == .leftMouseDown ? 1 : 0
    )!
  }
}
