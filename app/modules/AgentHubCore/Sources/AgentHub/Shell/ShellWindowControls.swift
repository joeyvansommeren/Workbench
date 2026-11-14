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
//  drag. Without a toolbar, clicks reach the content as usual, but AppKit's
//  title bar is only 32 pt. `ShellTrafficLights` grows it to the prototype's
//  52 pt and centres the lights in it; the title band is then measured from
//  the lights (`ShellTitleBarMetrics`), so every control shares their line.
//  Shell/README.md, "Title row clicks" and "Title band".
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
/// back. The default is what `ShellTrafficLights` gives on macOS 27: a 52 pt
/// band, lights centred 26 pt from the top, the zoom button ending at x 79.
/// If AppKit refuses the move, the measurement still follows the lights.
struct ShellTitleBarMetrics: Equatable {
  /// Height of the title band: the system title bar.
  var bandHeight: CGFloat
  /// Right edge of the zoom button, in window points.
  var trafficLightsTrailing: CGFloat

  static let standard = ShellTitleBarMetrics(bandHeight: 52, trafficLightsTrailing: 79)

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

/// Puts the traffic lights in the prototype's 52 pt title bar: centred
/// 26 pt from the top, the close button's centre 26 pt from the leading edge.
///
/// AppKit's titlebar for a hidden title bar is 32 pt. This makes its
/// container 52 pt high and moves the three buttons, keeping AppKit's spacing
/// between them. AppKit lays the titlebar out again on resize, key changes and
/// full screen, so `ShellWindowChromeView` calls this again from those window
/// notifications and from the container's and buttons' frame-change
/// notifications. Those are AppKit frame changes, never SwiftUI layout, and
/// `place(in:)` writes a frame only when it differs, so a call after its own
/// change finds nothing to do and ends. Skipped in full screen, where AppKit
/// owns the titlebar.
enum ShellTrafficLights {
  static let bandHeight: CGFloat = 52
  static let closeCentreX: CGFloat = 26

  /// Moves the titlebar container and the buttons into place; true if any
  /// frame changed.
  @MainActor
  @discardableResult
  static func place(in window: NSWindow) -> Bool {
    guard
      !window.styleMask.contains(.fullScreen),
      let close = window.standardWindowButton(.closeButton),
      !close.isHidden,
      let titlebarView = close.superview,
      let container = titlebarView.superview,
      let containerParent = container.superview
    else { return false }
    var changed = false
    func setFrame(_ view: NSView, _ frame: CGRect) {
      guard view.frame != frame else { return }
      view.frame = frame
      changed = true
    }

    setFrame(container, CGRect(
      x: container.frame.minX,
      y: containerParent.bounds.height - bandHeight,
      width: container.frame.width,
      height: bandHeight
    ))
    setFrame(titlebarView, container.bounds)

    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap { window.standardWindowButton($0) }
      .filter { $0.superview === titlebarView }
    let shift = (closeCentreX - close.frame.midX).rounded()
    for button in buttons {
      let size = button.frame.size
      setFrame(button, CGRect(
        origin: CGPoint(
          x: button.frame.minX + shift,
          y: ((titlebarView.bounds.height - size.height) / 2).rounded()
        ),
        size: size
      ))
    }
    return changed
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
      self.placeLightsAndMeasure(in: window)
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
    // Place the lights again and measure whenever AppKit can have laid the
    // titlebar out again: a resize, leaving full screen (also the first real
    // measurement of a window that opened in full screen; until then the
    // default stands), another screen or backing scale, a key change.
    // `measured(in:)` returns nil while the lights are hidden, and the model
    // ignores equal metrics, so a repeat costs nothing.
    let windowEvents: [Notification.Name] = [
      NSWindow.didResizeNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didChangeScreenNotification,
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
    ]
    // AppKit can also lay the titlebar out on its own (appearance or title
    // change). Frame changes of the container and close button post these.
    let titlebarViews: [NSView] = [
      window.standardWindowButton(.closeButton),
      window.standardWindowButton(.closeButton)?.superview?.superview,
    ].compactMap { $0 }
    let sources: [(Notification.Name, AnyObject)] =
      windowEvents.map { ($0, window) } + titlebarViews.map { (NSView.frameDidChangeNotification, $0) }
    observers += sources.map { name, object in
      center.addObserver(forName: name, object: object, queue: .main) { [weak self, weak window] _ in
        MainActor.assumeIsolated {
          guard let self, let window else { return }
          self.placeLightsAndMeasure(in: window)
        }
      }
    }
  }

  /// Times `ShellTrafficLights` moved something; tests check it settles.
  private(set) var lightPlacements = 0
  private var isPlacingLights = false

  func stopObserving() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }

  private func placeLightsAndMeasure(in window: NSWindow) {
    // Our own frame changes post frame notifications synchronously; skip
    // them, this call already handles their result.
    guard !isPlacingLights else { return }
    isPlacingLights = true
    if ShellTrafficLights.place(in: window) { lightPlacements += 1 }
    isPlacingLights = false
    guard let metrics = ShellTitleBarMetrics.measured(in: window) else { return }
    onTitleBarMetrics(metrics)
  }
}
