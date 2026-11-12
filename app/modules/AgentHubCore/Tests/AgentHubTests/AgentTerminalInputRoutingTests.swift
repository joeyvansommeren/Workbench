import AppKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

/// Chat approvals go to the agent's own tab or nowhere. These tests pin the
/// dispatch in the view model, the SwiftTerm surface, and the protocol default.
@MainActor
@Suite("Agent terminal input routing", .serialized)
struct AgentTerminalInputRoutingTests {
  @Test("The view model only reports success when the surface accepted the agent target")
  func viewModelDispatch() {
    let viewModel = makeViewModel()
    let accepting = RoutingSurface(acceptsAgentInput: true)
    let refusing = RoutingSurface(acceptsAgentInput: false)
    viewModel.activeTerminals["a"] = accepting
    viewModel.activeTerminals["b"] = refusing

    #expect(viewModel.typeTextInAgentTerminal(forKey: "a", text: "1"))
    #expect(accepting.agentTyped == ["1"])
    #expect(accepting.activeTyped.isEmpty)
    #expect(viewModel.lastFocusedSessionId == "a")

    #expect(!viewModel.typeTextInAgentTerminal(forKey: "b", text: "1"))
    #expect(refusing.activeTyped.isEmpty)  // never falls back to the active tab
    #expect(viewModel.lastFocusedSessionId == "a")

    #expect(!viewModel.typeTextInAgentTerminal(forKey: "missing", text: "1"))
    #expect(!viewModel.typeTextInAgentTerminal(forKey: "a", text: ""))
  }

  @Test("The protocol default fails closed and never touches the active terminal")
  func protocolDefaultFailsClosed() {
    let surface = DefaultSurface()
    #expect((surface as any EmbeddedTerminalSurface).typeTextToAgentSession("1") == false)
    #expect(surface.activeTyped.isEmpty)
  }

  @Test("SwiftTerm surface without an agent tab refuses; its active-tab path is separate")
  func swiftTermSurfaceWithoutAgentTab() {
    let surface = TerminalContainerView()
    #expect(surface.typeTextToAgentSession("1") == false)
    #expect(surface.activeLinkedSession == nil)
  }
}

// MARK: - Helpers

private actor StubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor StubFileWatcher: SessionFileWatcherProtocol {
  private nonisolated let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
private func makeViewModel() -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: StubMonitorService(),
    fileWatcher: StubFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

/// Only the required protocol members: the default agent routing applies.
@MainActor
private class DefaultSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private(set) var activeTyped: [String] = []

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
  func typeText(_ text: String) { activeTyped.append(text) }
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
}

/// A surface with an explicit agent destination that can be present or absent.
@MainActor
private class BareSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private(set) var activeTyped: [String] = []

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
  func typeText(_ text: String) { activeTyped.append(text) }
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
  func typeTextToAgentSession(_ text: String) -> Bool { false }
}

@MainActor
private final class RoutingSurface: BareSurface {
  let acceptsAgentInput: Bool
  private(set) var agentTyped: [String] = []

  init(acceptsAgentInput: Bool) {
    self.acceptsAgentInput = acceptsAgentInput
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func typeTextToAgentSession(_ text: String) -> Bool {
    guard acceptsAgentInput else { return false }
    agentTyped.append(text)
    return true
  }
}
