import AppKit
import Testing

@testable import AgentHubCore

@Suite("Approval shortcut routing")
struct ApprovalShortcutRoutingTests {
  private static let modifierSets: [NSEvent.ModifierFlags] = [
    [], .command, .option, .shift, .control, [.command, .shift], [.command, .option],
  ]

  @Test("With a banner, ⌘↩ approves for every newline setting")
  func bannerCommandReturnApproves() {
    for shortcut in NewlineShortcut.allCases {
      #expect(
        ApprovalShortcutRouting.route(
          shortcut: shortcut, isReturn: true, flags: .command, isApprovalBannerVisible: true) == .approve)
    }
  }

  @Test("Without a banner, every key is unchanged for every newline setting")
  func noBannerUnchanged() {
    for shortcut in NewlineShortcut.allCases {
      for flags in Self.modifierSets {
        for isReturn in [true, false] {
          let expected = TerminalSubmitInterception.keyAction(shortcut: shortcut, isReturn: isReturn, flags: flags)
          #expect(
            ApprovalShortcutRouting.route(
              shortcut: shortcut, isReturn: isReturn, flags: flags, isApprovalBannerVisible: false)
              == .terminal(expected))
        }
      }
    }
  }

  @Test("With a banner, only ⌘↩ changes; other keys keep the terminal's action")
  func bannerLeavesOtherKeysAlone() {
    for shortcut in NewlineShortcut.allCases {
      for flags in Self.modifierSets {
        for isReturn in [true, false] where !(isReturn && flags == .command) {
          let expected = TerminalSubmitInterception.keyAction(shortcut: shortcut, isReturn: isReturn, flags: flags)
          #expect(
            ApprovalShortcutRouting.route(
              shortcut: shortcut, isReturn: isReturn, flags: flags, isApprovalBannerVisible: true)
              == .terminal(expected))
        }
      }
    }
  }

  @Test("⌘ with another key is not an approval")
  func commandWithoutReturn() {
    #expect(
      ApprovalShortcutRouting.route(
        shortcut: .cmdReturn, isReturn: false, flags: .command, isApprovalBannerVisible: true)
        == .terminal(.passthrough))
  }
}
