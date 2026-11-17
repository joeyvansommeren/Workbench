import AppKit
import Testing

@MainActor
@Suite("Background test windows", .serialized)
struct BackgroundTestWindowTests {
  @Test("Default native fixtures cannot take focus or occupy a display")
  func fixturePresentationPolicy() {
    let window = BackgroundTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.close() }
    window.presentForTesting()

    if BackgroundTestWindow.usesVisibleWindows {
      #expect(NSApplication.shared.activationPolicy() == .accessory)
    } else {
      #expect(NSApplication.shared.activationPolicy() == .prohibited)
      #expect(!window.canBecomeKey)
      #expect(!window.canBecomeMain)
      #expect(!window.isKeyWindow)
      #expect(!window.isMainWindow)
      #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
      #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
      let requested = NSRect(x: -50_000, y: -50_000, width: 400, height: 300)
      #expect(window.constrainFrameRect(requested, to: NSScreen.main) == requested)
    }
  }
}
