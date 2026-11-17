import AppKit
import Testing

@testable import AgentHubCore

@Suite("Auxiliary shell terminal host view")
struct AuxiliaryShellTerminalHostViewTests {

  @Test("Mounting a different terminal replaces the current terminal view")
  @MainActor
  func mountReplacesMountedTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let firstTerminal = TerminalContainerView()
    let secondTerminal = TerminalContainerView()

    hostView.mount(firstTerminal, key: "session-a")
    hostView.mount(secondTerminal, key: "session-b")

    #expect(hostView.subviews.count == 1)
    #expect(hostView.subviews.first === secondTerminal)
    #expect(firstTerminal.superview == nil)
    #expect(hostView.mountedTerminalKey == "session-b")
  }

  @Test("Remounting a cached terminal restores the same terminal instance")
  @MainActor
  func remountRestoresCachedTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let firstTerminal = TerminalContainerView()
    let secondTerminal = TerminalContainerView()

    hostView.mount(firstTerminal, key: "session-a")
    hostView.mount(secondTerminal, key: "session-b")
    hostView.mount(firstTerminal, key: "session-a")

    #expect(hostView.subviews.count == 1)
    #expect(hostView.subviews.first === firstTerminal)
    #expect(secondTerminal.superview == nil)
    #expect(hostView.mountedTerminalKey == "session-a")
  }

  @Test("Mounted state matches the terminal instance and key")
  @MainActor
  func mountedStateRequiresSameTerminalAndKey() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let firstTerminal = TerminalContainerView()
    let secondTerminal = TerminalContainerView()

    hostView.mount(firstTerminal, key: "session-a")

    #expect(hostView.isMounted(firstTerminal, key: "session-a"))
    #expect(!hostView.isMounted(firstTerminal, key: "session-b"))
    #expect(!hostView.isMounted(secondTerminal, key: "session-a"))
  }

  @Test("Unmount removes the currently mounted terminal")
  @MainActor
  func unmountRemovesTerminal() {
    let hostView = AuxiliaryShellTerminalHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    let terminal = TerminalContainerView()

    hostView.mount(terminal, key: "session-a")
    hostView.unmountTerminal()

    #expect(hostView.subviews.isEmpty)
    #expect(terminal.superview == nil)
    #expect(hostView.mountedTerminalKey == nil)
  }

  @Test("Concealment releases native focus and approval routing without unmounting")
  @MainActor
  func concealmentReleasesFocusAndShortcut() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let focused = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(focused)
    host.mount(terminal, key: "session")
    window.contentView = host
    #expect(window.makeFirstResponder(focused))
    var approvals = 0
    terminal.approvalShortcutHandler = { approvals += 1 }
    host.setConcealed(true)
    #expect(host.isHidden)
    #expect(terminal.isHiddenOrHasHiddenAncestor)
    #expect(window.firstResponder !== focused)
    #expect(terminal.approvalShortcutHandler == nil)
    terminal.approvalShortcutHandler?()
    #expect(approvals == 0)
    #expect(host.isMounted(terminal, key: "session"))
    host.setConcealed(false)
    #expect(!host.isHidden)
    #expect(host.isMounted(terminal, key: "session"))
    #expect(terminal.approvalShortcutHandler == nil)
  }

  @Test("A concealed old host cannot clear a terminal that moved to another host")
  @MainActor
  func movedTerminalKeepsNewHostsShortcut() {
    let old = EmbeddedTerminalHostView()
    let current = EmbeddedTerminalHostView()
    let terminal = TerminalContainerView()
    old.mount(terminal, key: "session")
    current.mount(terminal, key: "session")
    terminal.approvalShortcutHandler = {}
    old.setConcealed(true)
    #expect(terminal.approvalShortcutHandler != nil)
    #expect(terminal.superview === current)
  }
}

// MARK: - Focus restoration (TES-267)

@Suite("Terminal host focus restoration")
struct TerminalHostFocusRestorationTests {

  @Test("Unconceal restores focus to the exact focused descendant")
  @MainActor
  func unconcealRestoresFocusedDescendant() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))
    #expect(window.firstResponder === child)

    host.setConcealed(true)
    #expect(window.firstResponder !== child)

    host.setConcealed(false)
    #expect(!host.isHidden, "Host should be visible after unconceal")
    #expect(window.firstResponder === child,
      "Focus should return to the exact descendant, not the container")
  }

  @Test("Repeated conceal/unconceal cycles restore correctly")
  @MainActor
  func repeatedConcealCycles() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    for _ in 0..<3 {
      host.setConcealed(true)
      #expect(window.firstResponder !== child)
      host.setConcealed(false)
      #expect(window.firstResponder === child)
    }
  }

  @Test("Identical view+key remount preserves saved focus token")
  @MainActor
  func identicalRemountPreservesToken() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    host.setConcealed(true)
    // SwiftUI updateNSView remount with same view+key — token must survive.
    host.mount(terminal, key: "s1")
    host.setConcealed(false)
    #expect(window.firstResponder === child,
      "Same view+key remount should not invalidate the focus token")
  }

  @Test("Different key on same view invalidates focus token")
  @MainActor
  func differentKeyInvalidatesToken() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    host.setConcealed(true)
    host.mount(terminal, key: "s2")
    host.setConcealed(false)
    #expect(window.firstResponder !== child,
      "Changed key should invalidate focus restoration")
  }

  @Test("Replacement terminal view invalidates focus token")
  @MainActor
  func replacementViewInvalidatesToken() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal1 = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal1.addSubview(child)
    host.mount(terminal1, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    host.setConcealed(true)
    let terminal2 = TerminalContainerView()
    host.mount(terminal2, key: "s1")
    host.setConcealed(false)
    #expect(window.firstResponder !== child,
      "Replacement view should invalidate focus restoration")
  }

  @Test("Unmount invalidates focus token")
  @MainActor
  func unmountInvalidatesToken() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    host.setConcealed(true)
    host.unmountTerminal()
    host.mount(terminal, key: "s1")
    host.setConcealed(false)
    #expect(window.firstResponder !== child,
      "Unmount should invalidate focus restoration")
  }

  @Test("External responder claim during concealment is preserved")
  @MainActor
  func externalResponderPreserved() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")

    let editor = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    let container = NSView(frame: window.contentView!.bounds)
    window.contentView = container
    container.addSubview(host)
    container.addSubview(editor)

    #expect(window.makeFirstResponder(child))
    host.setConcealed(true)
    #expect(window.makeFirstResponder(editor))
    host.setConcealed(false)
    #expect(window.firstResponder === editor,
      "External responder (palette/editor) must not be overridden")
  }

  @Test("No focus change when host had no focused descendant at conceal time")
  @MainActor
  func noFocusedDescendantNoRestore() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    host.mount(terminal, key: "s1")
    window.contentView = host

    host.setConcealed(true)
    host.setConcealed(false)
    #expect(window.firstResponder !== terminal,
      "Should not focus terminal when no descendant was focused before conceal")
  }

  @Test("Window change invalidates focus token")
  @MainActor
  func windowChangeInvalidatesToken() {
    let window1 = makeWindow()
    defer { teardown(window1) }
    let window2 = makeWindow()
    defer { teardown(window2) }
    let host = EmbeddedTerminalHostView(frame: window1.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window1.contentView = host
    #expect(window1.makeFirstResponder(child))

    host.setConcealed(true)
    // Move host to a different window.
    host.removeFromSuperview()
    window2.contentView = host
    host.setConcealed(false)
    #expect(window2.firstResponder !== child,
      "Focus token captured in window1 must not restore in window2")
  }

  @Test("Repeated setConcealed(true) before reveal does not crash or double-save")
  @MainActor
  func repeatedConcealBeforeReveal() {
    let window = makeWindow()
    defer { teardown(window) }
    let host = EmbeddedTerminalHostView(frame: window.contentView!.bounds)
    let terminal = TerminalContainerView()
    let child = ConcealmentResponderView(frame: NSRect(x: 0, y: 0, width: 50, height: 30))
    terminal.addSubview(child)
    host.mount(terminal, key: "s1")
    window.contentView = host
    #expect(window.makeFirstResponder(child))

    // Conceal twice before revealing.
    host.setConcealed(true)
    host.setConcealed(true)
    host.setConcealed(false)
    #expect(!host.isHidden)
    // The second conceal should not corrupt the token; restore should still work.
    #expect(window.firstResponder === child,
      "Double conceal before reveal should still restore correctly")
  }

  // MARK: - Helpers

  @MainActor
  private func makeWindow() -> BackgroundTestWindow {
    let window = BackgroundTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.presentForTesting()
    return window
  }

  @MainActor
  private func teardown(_ window: BackgroundTestWindow) {
    window.contentView = nil
    window.orderOut(nil)
    window.close()
  }
}

@MainActor
private final class ConcealmentResponderView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
