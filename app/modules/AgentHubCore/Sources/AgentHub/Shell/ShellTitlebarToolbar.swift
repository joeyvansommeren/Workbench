//
//  ShellTitlebarToolbar.swift
//  AgentHub
//
//  The window's only toolbar item: the sidebar toggle (`.window-controls` in
//  the prototype). Having a toolbar makes AppKit draw a 52 pt unified title
//  bar, so the real traffic lights centre at y 26 in the shell's title row;
//  the toggle sits right of them (x 100–128), centred too, and stays put when
//  the sidebar hides. Everything else in the row is SwiftUI (`ShellToolbar`).
//
//  Why a real item: an empty `NSToolbar` gives a 66 pt bar; one item gives
//  52 pt. Any item gets a 44 × 52 pt hit area right of the traffic lights
//  (measured), which would cover a SwiftUI toggle drawn there, so the toggle
//  is that item. Why not move the window buttons by hand: AppKit lays them
//  out again on resize, full screen and appearance changes, so they would
//  have to be moved from layout callbacks, a layout-loop risk. Details and
//  measurements: Shell/README.md, "P12".
//
//  Layout-loop safety: the item set is fixed for the window's life and never
//  shown or hidden at runtime. Only the toggle's label and help text change.
//  `ShellWindowChrome` locks the toolbar against customization and display
//  mode changes; `ShellCommands` removes View › Show/Hide Toolbar.
//

import AppKit
import SwiftUI

struct ShellTitlebarToolbar: ViewModifier {
  let shellModel: WorkbenchShellModel

  func body(content: Content) -> some View {
    toolbar(content)
      .background(ShellWindowChrome(onFullScreenChange: { shellModel.setFullScreen($0) }))
  }

  @ViewBuilder
  private func toolbar(_ content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .toolbar {
          ToolbarItem(placement: .navigation) { ShellSidebarToggle(shellModel: shellModel) }
            // No Liquid Glass capsule: the prototype draws a plain icon button.
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    } else {
      content
        .toolbar {
          ToolbarItem(placement: .navigation) { ShellSidebarToggle(shellModel: shellModel) }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
  }
}

/// The sidebar toggle (⌃⌘S). Fixed 28 pt frame, so the item never resizes.
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

/// Window-level upkeep for the title bar, hooked up once per window. Never
/// driven by geometry or layout callbacks:
/// - locks the toolbar (no customization, no display-mode menu), so its
///   height, and with it the top safe area, never changes at runtime and the
///   sidebar toggle cannot be removed;
/// - reports full screen from the window's full-screen notifications.
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    guard let window else { return }
    Self.lockToolbar(of: window)
    let isFullScreen = window.styleMask.contains(.fullScreen)
    // Next turn: SwiftUI may install the toolbar after this view joins the
    // window, and state must not change during a view update.
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window else { return }
      Self.lockToolbar(of: window)
      self.onFullScreenChange(isFullScreen)
    }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onFullScreenChange(true) }
      },
      center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.onFullScreenChange(false) }
      },
      center.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) {
        [weak window] _ in MainActor.assumeIsolated { window.map { Self.lockToolbar(of: $0) } }
      },
    ]
  }

  /// Idempotent: only writes what is not locked yet.
  static func lockToolbar(of window: NSWindow) {
    guard let toolbar = window.toolbar else { return }
    if toolbar.allowsUserCustomization { toolbar.allowsUserCustomization = false }
    if toolbar.autosavesConfiguration { toolbar.autosavesConfiguration = false }
    if #available(macOS 15, *), toolbar.allowsDisplayModeCustomization {
      toolbar.allowsDisplayModeCustomization = false
    }
  }
}
