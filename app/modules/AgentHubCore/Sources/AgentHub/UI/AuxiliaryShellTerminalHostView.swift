//
//  AuxiliaryShellTerminalHostView.swift
//  AgentHub
//

import AppKit

public final class EmbeddedTerminalHostView: NSView {
  public private(set) var mountedTerminalKey: String?
  private weak var mountedTerminalView: NSView?
  private weak var mountedSurface: (any EmbeddedTerminalSurface)?

  public func mount(_ terminal: any EmbeddedTerminalSurface, key: String) {
    mountedSurface = terminal
    mountView(terminal.view, key: key)
  }

  public func isMounted(_ terminal: any EmbeddedTerminalSurface, key: String) -> Bool {
    mountedTerminalKey == key && mountedTerminalView === terminal.view
  }

  private func mountView(_ terminalView: NSView, key: String) {
    guard mountedTerminalView !== terminalView else {
      mountedTerminalKey = key
      return
    }

    mountedTerminalView?.removeFromSuperview()

    if terminalView.superview !== self {
      terminalView.removeFromSuperview()
      terminalView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(terminalView)
      NSLayoutConstraint.activate([
        terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
        terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        terminalView.topAnchor.constraint(equalTo: topAnchor),
        terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
      ])
    }

    mountedTerminalView = terminalView
    mountedTerminalKey = key
  }

  /// Conceal the native host without unmounting or terminating its terminal.
  func setConcealed(_ concealed: Bool) {
    if concealed {
      // A terminal can move to another host; an old host must not clear its new owner's shortcut.
      if mountedTerminalView?.superview === self { mountedSurface?.approvalShortcutHandler = nil }
      if let responder = window?.firstResponder as? NSView,
        responder === self || responder.isDescendant(of: self) {
        window?.makeFirstResponder(nil)
      }
    }
    isHidden = concealed
  }

  public func unmountTerminal() {
    mountedTerminalView?.removeFromSuperview()
    mountedTerminalView = nil
    mountedSurface = nil
    mountedTerminalKey = nil
  }
}

public typealias AuxiliaryShellTerminalHostView = EmbeddedTerminalHostView
