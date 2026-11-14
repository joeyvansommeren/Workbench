//
//  ShellWindowControls.swift
//  AgentHub
//
//  The window controls next to the traffic lights (`.window-controls` in the
//  prototype): the sidebar toggle, drawn by SwiftUI at a fixed position in
//  the title band, so it stays put when the sidebar hides. Plus
//  `ShellWindowChrome`, which reports full screen and the title-bar metrics.
//
//  No NSToolbar. P12 made this toggle the window's only toolbar item, for a
//  52 pt title bar with the traffic lights centred in it. With a toolbar,
//  AppKit sends a click under the titlebar to the content only inside the
//  region SwiftUI reports as opaque, and SwiftUI leaves the row's controls
//  out of it once the content has composited layers (the content panel's
//  clip and shadow): every click on the tabs and Search became a window
//  drag. Without a toolbar, clicks reach the content as usual. The traffic
//  lights then sit where AppKit puts them for a hidden title bar, so the
//  title band follows them instead: its height is the system title bar's
//  (`ShellTitleBarMetrics`), and every control is centred on the lights'
//  line. Shell/README.md, "Title row clicks".
//

import AppKit
import SwiftUI

/// Where AppKit puts the traffic lights in this window. The title band is
/// twice the lights' centre high, so the row's controls share their line.
///
/// Read from the real window buttons when the window is hooked up, and again
/// on window notifications (leaving full screen, screen or backing change,
/// becoming key; `ShellWindowChrome`), never from layout:
/// the buttons' place does not depend on our content, so nothing can feed
/// back. The default is the measurement on macOS 27 (a 32 pt title bar,
/// lights at x 9, 32, 55, centred 16 pt from the top); older systems can
/// differ, which is why it is measured.
struct ShellTitleBarMetrics: Equatable {
  /// Height of the title band: the system title bar.
  var bandHeight: CGFloat
  /// Right edge of the zoom button, in window points.
  var trafficLightsTrailing: CGFloat

  static let standard = ShellTitleBarMetrics(bandHeight: 32, trafficLightsTrailing: 69)

  /// The metrics of `window`, or nil while the lights are hidden (full
  /// screen) or report something implausible.
  @MainActor
  static func measured(in window: NSWindow) -> ShellTitleBarMetrics? {
    guard
      let frameView = window.contentView?.superview,
      let close = window.standardWindowButton(.closeButton),
      let zoom = window.standardWindowButton(.zoomButton)
    else { return nil }
    return measured(
      isFullScreen: window.styleMask.contains(.fullScreen),
      isCloseButtonHidden: close.isHidden,
      frameHeight: frameView.bounds.height,
      closeFrame: close.convert(close.bounds, to: nil),
      zoomFrame: zoom.convert(zoom.bounds, to: nil)
    )
  }

  /// The rule behind `measured(in:)`, on plain values. Frames are in window
  /// coordinates: the frame view is not flipped, so y grows upward from the
  /// bottom edge.
  static func measured(
    isFullScreen: Bool,
    isCloseButtonHidden: Bool,
    frameHeight: CGFloat,
    closeFrame: CGRect,
    zoomFrame: CGRect
  ) -> ShellTitleBarMetrics? {
    guard !isFullScreen, !isCloseButtonHidden else { return nil }
    let closeCentreFromTop = frameHeight - closeFrame.midY
    let metrics = ShellTitleBarMetrics(
      bandHeight: (2 * closeCentreFromTop).rounded(),
      trafficLightsTrailing: zoomFrame.maxX.rounded()
    )
    guard (20...60).contains(metrics.bandHeight), (30...140).contains(metrics.trafficLightsTrailing) else {
      return nil
    }
    return metrics
  }
}

/// The sidebar toggle at a fixed place right of the traffic lights, over a
/// drag area that covers the title band above the sidebar. An overlay on
/// `ShellFrame`, so it never moves with the sidebar animation.
struct ShellWindowControls: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    ShellSidebarToggle(shellModel: shellModel)
      .padding(
        .leading,
        ShellLayout.sidebarToggleLeading(isFullScreen: shellModel.isFullScreen, titleBar: shellModel.titleBar)
      )
      // Over the sidebar, the empty band drags the window like the rest of
      // the row. With the sidebar hidden the title row's own drag area
      // starts at the window edge, so only the toggle's own width is needed.
      .frame(
        width: shellModel.sidebarVisible ? DesignTokens.Width.sidebar : nil,
        height: shellModel.titleBar.bandHeight,
        alignment: .leading
      )
      .background(TitleBarDragArea())
  }
}

/// The sidebar toggle (⌃⌘S). Fixed 28 pt frame, so it never resizes.
struct ShellSidebarToggle: View {
  let shellModel: WorkbenchShellModel

  var body: some View {
    IconButton(
      systemImage: "sidebar.left",
      accessibilityLabel: shellModel.sidebarVisible ? "Hide sidebar" : "Show sidebar",
      accessibilityIdentifier: "shell.toggleSidebar"
    ) {
      shellModel.toggleSidebar()
    }
    .help("\(shellModel.sidebarVisible ? "Hide" : "Show") sidebar  \(ShellShortcut.toggleSidebar.keyCaps.joined())")
    .fixedSize()
  }
}

/// Reports full screen and the title-bar metrics from window notifications,
/// hooked up once per window. Never driven by geometry or layout callbacks.
struct ShellWindowChrome: NSViewRepresentable {
  let onFullScreenChange: (Bool) -> Void
  let onTitleBarMetrics: (ShellTitleBarMetrics) -> Void

  func makeNSView(context: Context) -> ShellWindowChromeView {
    let view = ShellWindowChromeView()
    view.onFullScreenChange = onFullScreenChange
    view.onTitleBarMetrics = onTitleBarMetrics
    return view
  }

  func updateNSView(_ nsView: ShellWindowChromeView, context: Context) {}

  static func dismantleNSView(_ nsView: ShellWindowChromeView, coordinator: ()) {
    nsView.stopObserving()
  }
}

extension View {
  /// Feeds `shellModel` the window's full-screen state and title-bar
  /// metrics. Apply it outside `.wbRedrawsOnPaletteChange()`: inside, every
  /// palette switch would rebuild the listener and hook up its observers
  /// again.
  func shellWindowChrome(_ shellModel: WorkbenchShellModel) -> some View {
    background(
      ShellWindowChrome(
        onFullScreenChange: { shellModel.setFullScreen($0) },
        onTitleBarMetrics: { shellModel.setTitleBar($0) }
      )
    )
  }
}

final class ShellWindowChromeView: NSView {
  var onFullScreenChange: (Bool) -> Void = { _ in }
  var onTitleBarMetrics: (ShellTitleBarMetrics) -> Void = { _ in }
  // Only touched on the main thread; `nonisolated(unsafe)` lets deinit
  // remove the observers (NotificationCenter is thread-safe).
  nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  // A listener only: it sits behind the whole frame and must never take a click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    guard let window else { return }
    // Next turn: state must not change during a view update, and AppKit has
    // laid out the window buttons by then.
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window else { return }
      self.onFullScreenChange(window.styleMask.contains(.fullScreen))
      self.reportMetrics(of: window)
    }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onFullScreenChange(true) }
      },
      center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onFullScreenChange(false) }
      },
    ]
    // Measure again whenever the lights can have moved: leaving full screen
    // (also the first real measurement of a window that opened in full
    // screen; until then the default stands), another screen or backing
    // scale, and becoming key (catches a system change made meanwhile).
    // `measured(in:)` returns nil while the lights are hidden, and the model
    // ignores equal metrics, so a repeat costs nothing.
    let remeasureOn: [Notification.Name] = [
      NSWindow.didExitFullScreenNotification,
      NSWindow.didChangeScreenNotification,
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didBecomeKeyNotification,
    ]
    observers += remeasureOn.map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
        MainActor.assumeIsolated {
          guard let self, let window else { return }
          self.reportMetrics(of: window)
        }
      }
    }
  }

  func stopObserving() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }

  private func reportMetrics(of window: NSWindow) {
    guard let metrics = ShellTitleBarMetrics.measured(in: window) else { return }
    onTitleBarMetrics(metrics)
  }
}
