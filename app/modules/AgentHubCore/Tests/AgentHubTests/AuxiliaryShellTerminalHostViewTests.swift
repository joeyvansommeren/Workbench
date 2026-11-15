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


@MainActor
private final class ConcealmentResponderView: NSView {
  override var acceptsFirstResponder: Bool { true }
}
