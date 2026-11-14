//
//  ShellWindowControls.swift
//  AgentHub
//
//  The window controls next to the traffic lights (`.window-controls` in the
//  prototype): the sidebar toggle, drawn by SwiftUI at a fixed position in
//  the 52 pt title row, so it stays put when the sidebar hides. Plus
//  `ShellWindowChrome`, which reports full screen.
//
//  No NSToolbar. P12 made this toggle the window's only toolbar item, for a
//  52 pt title bar with the traffic lights centred in it. With a toolbar,
//  AppKit sends a click under the titlebar to the content only inside the
//  region SwiftUI reports as opaque, and SwiftUI leaves the row's controls
//  out of it once the content has composited layers (the content panel's
//  clip and shadow): every click on the tabs and Search became a window
//  drag. Without a toolbar, clicks reach the content as usual, and the
//  traffic lights sit where AppKit puts them for a hidden title bar
//  (x 9–69, centred 16 pt from the top). Shell/README.md, "Title row clicks".
//

import AppKit
import SwiftUI

/// The sidebar toggle at a fixed place right of the traffic lights, over a
/// drag area that covers the title row above the sidebar. An overlay on
/// `ShellFrame`, so it never moves with the sidebar animation.
struct ShellWindowControls: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    ShellSidebarToggle(shellModel: shellModel)
      .padding(.leading, ShellLayout.sidebarToggleLeading(isFullScreen: shellModel.isFullScreen))
      // Over the sidebar, the empty band drags the window like the rest of
      // the row. With the sidebar hidden the title row's own drag area
      // starts at the window edge, so only the toggle's own width is needed.
      .frame(
        width: shellModel.sidebarVisible ? DesignTokens.Width.sidebar : nil,
        height: DesignTokens.Size.titlebar,
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

/// Reports full screen from the window's full-screen notifications, hooked up
/// once per window. Never driven by geometry or layout callbacks.
struct ShellWindowChrome: NSViewRepresentable {
  let onFullScreenChange: (Bool) -> Void

  func makeNSView(context: Context) -> ShellWindowChromeView {
    let view = ShellWindowChromeView()
    view.onFullScreenChange = onFullScreenChange
    return view
  }

  func updateNSView(_ nsView: ShellWindowChromeView, context: Context) {}
}

final class ShellWindowChromeView: NSView {
  var onFullScreenChange: (Bool) -> Void = { _ in }
  private var observers: [NSObjectProtocol] = []

  // A listener only: it sits behind the whole frame and must never take a click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    guard let window else { return }
    let isFullScreen = window.styleMask.contains(.fullScreen)
    // Next turn: state must not change during a view update.
    DispatchQueue.main.async { [weak self] in
      self?.onFullScreenChange(isFullScreen)
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
  }
}
