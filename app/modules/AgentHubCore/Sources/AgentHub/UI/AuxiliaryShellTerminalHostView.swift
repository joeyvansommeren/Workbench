//
//  AuxiliaryShellTerminalHostView.swift
//  AgentHub
//

import AppKit

public final class EmbeddedTerminalHostView: NSView {
  public private(set) var mountedTerminalKey: String?
  private weak var mountedTerminalView: NSView?
  private weak var mountedSurface: (any EmbeddedTerminalSurface)?

  // MARK: - Saved focus token

  /// Identity of the focused descendant cleared by `setConcealed(true)`.
  /// Ties restoration eligibility to the exact view, mounted key, mounted
  /// view, and window that were active at capture time.  Invalidated by
  /// mount replacement, key change, unmount, or window change.
  private struct SavedFocusToken {
    weak var focusedDescendant: NSView?
    let mountedKey: String
    let mountedViewIdentity: ObjectIdentifier
    weak var captureWindow: NSWindow?
  }

  private var savedFocus: SavedFocusToken?

  // MARK: - Mount

  public func mount(_ terminal: any EmbeddedTerminalSurface, key: String) {
    mountedSurface = terminal
    mountView(terminal.view, key: key)
  }

  public func isMounted(_ terminal: any EmbeddedTerminalSurface, key: String) -> Bool {
    mountedTerminalKey == key && mountedTerminalView === terminal.view
  }

  private func mountView(_ terminalView: NSView, key: String) {
    guard mountedTerminalView !== terminalView else {
      // SwiftUI updateNSView remounts the same surface — preserve the focus
      // token when both view and key are identical.
      if mountedTerminalKey != key {
        savedFocus = nil
        mountedTerminalKey = key
      }
      return
    }

    // Different view: invalidate any saved focus from the old terminal.
    savedFocus = nil
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

  // MARK: - Conceal / reveal

  /// Conceal the native host without unmounting or terminating its terminal.
  func setConcealed(_ concealed: Bool) {
    if concealed {
      // A terminal can move to another host; an old host must not clear its new owner's shortcut.
      if mountedTerminalView?.superview === self { mountedSurface?.approvalShortcutHandler = nil }
      if let responder = window?.firstResponder as? NSView,
        responder === self || responder.isDescendant(of: self),
        let mountedView = mountedTerminalView, let key = mountedTerminalKey {
        savedFocus = SavedFocusToken(
          focusedDescendant: responder,
          mountedKey: key,
          mountedViewIdentity: ObjectIdentifier(mountedView),
          captureWindow: window)
        window?.makeFirstResponder(nil)
      }
    } else {
      // Unhide before restoring focus — AppKit ignores makeFirstResponder
      // on views inside a hidden ancestor.
      isHidden = false
      restoreSavedFocusIfEligible()
      return
    }
    isHidden = concealed
  }

  /// Restore focus to the previously focused descendant only when every
  /// identity guard still holds and no other responder has claimed focus.
  private func restoreSavedFocusIfEligible() {
    guard let token = savedFocus else { return }
    savedFocus = nil

    guard let descendant = token.focusedDescendant,
      let mountedView = mountedTerminalView,
      let key = mountedTerminalKey,
      key == token.mountedKey,
      ObjectIdentifier(mountedView) == token.mountedViewIdentity,
      mountedView.superview === self,
      descendant === mountedView || descendant.isDescendant(of: mountedView),
      let window,
      window === token.captureWindow,
      window.firstResponder === window || window.firstResponder == nil
    else { return }

    window.makeFirstResponder(descendant)
  }

  // MARK: - Unmount

  public func unmountTerminal() {
    savedFocus = nil
    mountedTerminalView?.removeFromSuperview()
    mountedTerminalView = nil
    mountedSurface = nil
    mountedTerminalKey = nil
  }
}

public typealias AuxiliaryShellTerminalHostView = EmbeddedTerminalHostView
