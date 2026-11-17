import AppKit

/// Native fixtures remain in the test process without taking over the desktop.
/// Visible interaction is a separate, explicit opt-in for manual verification.
@MainActor
class BackgroundTestWindow: NSWindow {
  static var usesVisibleWindows: Bool {
    ProcessInfo.processInfo.environment["AGENTHUB_TEST_VISIBLE_WINDOWS"] == "1"
  }

  override var canBecomeKey: Bool { Self.usesVisibleWindows && super.canBecomeKey }
  override var canBecomeMain: Bool { Self.usesVisibleWindows && super.canBecomeMain }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    Self.usesVisibleWindows ? super.constrainFrameRect(frameRect, to: screen) : frameRect
  }

  func presentForTesting() {
    // xcodebuild runs these package tests in an unhosted xctest process.
    // This policy affects that process only, never the installed application.
    let application = NSApplication.shared
    if Self.usesVisibleWindows {
      application.setActivationPolicy(.accessory)
      center()
      makeKeyAndOrderFront(nil)
      application.activate(ignoringOtherApps: true)
    } else {
      // An unhosted runner can already be prohibited. AppKit's transition
      // return value is not proof of the resulting policy; check the state.
      if application.activationPolicy() != .prohibited {
        application.setActivationPolicy(.prohibited)
      }
      precondition(application.activationPolicy() == .prohibited,
                   "Background test runner must prohibit activation before ordering a window")
      let desktop = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
      setFrameOrigin(NSPoint(x: desktop.minX - frame.width - 1_000,
                            y: desktop.minY - frame.height - 1_000))
      // Some AppKit layout paths need an ordered window. Never make it key,
      // order it in front, or let AppKit constrain it back onto a display.
      order(.below, relativeTo: 0)
      contentView?.layoutSubtreeIfNeeded()
    }
  }
}
