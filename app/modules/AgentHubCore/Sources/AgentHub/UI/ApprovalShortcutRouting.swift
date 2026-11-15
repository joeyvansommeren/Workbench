//
//  ApprovalShortcutRouting.swift
//  AgentHub
//
//  The terminal's local key monitor sees ⌘↩ before SwiftUI does and turns it
//  into a newline or a submit (per `NewlineShortcut`). While an approval banner
//  shows, ⌘↩ must approve instead. Pure, so both terminal backends share it.
//

import AppKit

public enum ApprovalShortcutRoute: Equatable {
  case approve
  /// Not an approval: what the terminal does without a banner.
  case terminal(TerminalReturnKeyAction)
}

public enum ApprovalShortcutRouting {
  /// macOS virtual key code for Return.
  public static let returnKeyCode: UInt16 = 36

  public static func route(
    shortcut: NewlineShortcut,
    isReturn: Bool,
    flags: NSEvent.ModifierFlags,
    isApprovalBannerVisible: Bool
  ) -> ApprovalShortcutRoute {
    if isApprovalBannerVisible, isReturn, flags == .command {
      return .approve
    }
    return .terminal(
      TerminalSubmitInterception.keyAction(shortcut: shortcut, isReturn: isReturn, flags: flags))
  }
}
