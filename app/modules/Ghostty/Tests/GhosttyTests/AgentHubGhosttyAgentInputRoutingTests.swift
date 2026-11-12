import AppKit
import Testing

import AgentHubCore
@testable import Ghostty

/// Chat approvals must reach the protected agent tab or nobody. Without a
/// mounted agent tab there is no safe destination, so the surface refuses.
@MainActor
@Suite("Ghostty agent input routing")
struct AgentHubGhosttyAgentInputRoutingTests {
  @Test("No agent tab: typing to the agent session fails closed")
  func failsClosedWithoutAgentTab() {
    let surface = AgentHubGhosttyTerminalSurface(frame: .zero)
    #expect(surface.typeTextToAgentSession("1") == false)
    #expect(surface.submitPromptImmediately("hello") == false)
  }

  @Test("The protocol default fails closed for surfaces without an agent tab")
  func protocolDefaultFailsClosed() {
    let surface = BareSurface()
    #expect((surface as any EmbeddedTerminalSurface).typeTextToAgentSession("1") == false)
    #expect(surface.typed.isEmpty)
  }
}

/// A surface that only implements the required members; it never gets the
/// default `typeTextToAgentSession` routed to its active terminal.
@MainActor
private final class BareSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private(set) var typed: [String] = []

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {}
  func configure(
    sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?, initialInputText: String?, launchContext: String?, isDark: Bool,
    dangerouslySkipPermissions: Bool, permissionModePlan: Bool, worktreeName: String?,
    metadataStore: SessionMetadataStore?
  ) {}
  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) {}
  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {}
  func terminateProcess() {}
  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { false }
  func typeText(_ text: String) { typed.append(text) }
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
}
