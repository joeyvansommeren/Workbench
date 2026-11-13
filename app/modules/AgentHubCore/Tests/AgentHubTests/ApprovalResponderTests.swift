import AppKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Approval responder")
struct ApprovalResponderTests {
  // MARK: Keystrokes

  @Test("Approve types 1 into the agent tab only")
  func approveTypesOneIntoAgentTab() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.bashPlain)
    let outcome = responder().respond(to: request(), decision: .approveOnce, terminal: terminal)
    #expect(outcome == .sent)
    #expect(terminal.agentTyped == ["1"])
    #expect(terminal.activeTabTyped.isEmpty)
    #expect(terminal.escapes == 0)
  }

  @Test("Always allow types 2 only when option 2 is a Yes")
  func approveAlways() {
    let edit = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.edit)
    #expect(responder().respond(to: request(tool: "Edit"), decision: .approveAlways, terminal: edit) == .sent)
    #expect(edit.agentTyped == ["2"])

    let yesNo = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.yesNoOnly)
    #expect(
      responder().respond(to: request(tool: "WebFetch"), decision: .approveAlways, terminal: yesNo)
        == .answerInTerminal(.menuNotVisible))
    #expect(yesNo.agentTyped.isEmpty)
  }

  @Test("Deny sends Escape, never a number")
  func denySendsEscape() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.bashBoxed)
    #expect(responder().respond(to: request(), decision: .deny, terminal: terminal) == .sent)
    #expect(terminal.escapes == 1)
    #expect(terminal.agentTyped.isEmpty)
  }

  // MARK: Fail closed

  @Test("Refuses when nothing is pending")
  func refusesWithoutPending() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.bashPlain)
    let outcome = responder().respond(to: request(pending: false), decision: .approveOnce, terminal: terminal)
    #expect(outcome == .answerInTerminal(.nothingPending))
    #expect(terminal.sentNothing)
  }

  @Test("Refuses when the tail lacks the menu, for approve and deny")
  func refusesWithoutMenu() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.idlePrompt)
    for decision in [ApprovalDecision.approveOnce, .approveAlways, .deny] {
      #expect(
        responder().respond(to: request(), decision: decision, terminal: terminal)
          == .answerInTerminal(.menuNotVisible))
    }
    #expect(terminal.sentNothing)
  }

  @Test("Refuses for interactive input tools")
  func refusesInputTools() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.question)
    for tool in ["AskUserQuestion", "request_user_input"] {
      #expect(
        responder().respond(to: request(tool: tool), decision: .approveOnce, terminal: terminal)
          == .answerInTerminal(.interactiveInput))
    }
    #expect(terminal.sentNothing)
  }

  @Test("Refuses for Codex and without a terminal")
  func refusesCodexAndMissingTerminal() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.bashPlain)
    #expect(
      responder().respond(to: request(provider: .codex), decision: .approveOnce, terminal: terminal)
        == .answerInTerminal(.unsupportedProvider))
    #expect(
      responder().respond(to: request(), decision: .approveOnce, terminal: nil)
        == .answerInTerminal(.terminalUnavailable))
    #expect(terminal.sentNothing)
  }

  @Test("A terminal without an agent tab reports it, it does not fall back")
  func agentTabGone() {
    let terminal = MockApprovalTerminal(screen: ClaudePermissionMenuFixtures.bashPlain, hasAgentTab: false)
    #expect(
      responder().respond(to: request(), decision: .approveOnce, terminal: terminal)
        == .answerInTerminal(.terminalUnavailable))
    #expect(terminal.activeTabTyped.isEmpty)
  }

  // MARK: Backends that can't read text

  @Test("Without screen text, an open sidecar request is required")
  func nonTextBackendNeedsSidecar() {
    let terminal = MockApprovalTerminal(screen: nil)
    let closed = responder(sidecarOpen: false)
    #expect(
      closed.respond(to: request(), decision: .approveOnce, terminal: terminal)
        == .answerInTerminal(.noOpenSidecarRequest))
    #expect(
      closed.respond(to: request(), decision: .deny, terminal: terminal)
        == .answerInTerminal(.noOpenSidecarRequest))
    #expect(terminal.sentNothing)

    let open = responder(sidecarOpen: true)
    #expect(open.respond(to: request(), decision: .approveOnce, terminal: terminal) == .sent)
    #expect(open.respond(to: request(), decision: .deny, terminal: terminal) == .sent)
    #expect(terminal.agentTyped == ["1"])
    #expect(terminal.escapes == 1)
  }

  @Test("Without screen text, Always allow is refused: option 2 can't be checked")
  func nonTextBackendRefusesAlwaysAllow() {
    let terminal = MockApprovalTerminal(screen: nil)
    #expect(
      responder(sidecarOpen: true).respond(to: request(), decision: .approveAlways, terminal: terminal)
        == .answerInTerminal(.menuNotVisible))
    #expect(terminal.sentNothing)
  }

  // MARK: Menu detection (fixture wording)

  @Test("Detects every permission menu fixture and nothing else")
  func menuDetection() {
    #expect(ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.bashBoxed))
    #expect(ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.bashPlain))
    #expect(ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.edit))
    #expect(ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.yesNoOnly))
    #expect(!ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.idlePrompt))
    #expect(!ClaudePermissionMenu.isVisible(in: ClaudePermissionMenuFixtures.question))
    #expect(!ClaudePermissionMenu.isVisible(in: []))
    // The option must come after the question.
    #expect(!ClaudePermissionMenu.isVisible(in: ["❯ 1. Yes", "Do you want to proceed?"]))
  }

  // MARK: Sidecar

  @Test("The last pending/resolved/denied line decides; observed lines don't")
  func sidecarState() {
    let pending = #"{"event":"pending","toolName":"Bash"}"#
    let observed = #"{"event":"observed","toolName":"Bash"}"#
    let resolved = #"{"event":"resolved","toolName":"Bash"}"#
    let denied = #"{"event":"denied","toolName":"Bash"}"#
    #expect(ApprovalSidecarState.hasOpenRequest(lines: [Substring(pending)]))
    #expect(ApprovalSidecarState.hasOpenRequest(lines: [Substring(pending), Substring(observed)]))
    #expect(!ApprovalSidecarState.hasOpenRequest(lines: [Substring(pending), Substring(resolved)]))
    #expect(!ApprovalSidecarState.hasOpenRequest(lines: [Substring(pending), Substring(denied)]))
    #expect(ApprovalSidecarState.hasOpenRequest(lines: [Substring(resolved), Substring(pending), "{broken"]))
    #expect(!ApprovalSidecarState.hasOpenRequest(lines: []))
  }

  @Test("The file reader reads only the tail and ignores a cut first line")
  func sidecarFileReader() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApprovalResponderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = FileApprovalSidecarReader(
      fileURL: { directory.appendingPathComponent("\($0).jsonl") }, maxBytes: 64)

    #expect(!reader.hasOpenRequest(sessionId: "missing"))

    let filler = String(repeating: #"{"event":"observed"}"# + "\n", count: 20)
    try (#"{"event":"resolved"}"# + "\n" + filler + #"{"event":"pending"}"# + "\n")
      .write(to: directory.appendingPathComponent("open.jsonl"), atomically: true, encoding: .utf8)
    #expect(reader.hasOpenRequest(sessionId: "open"))

    try (#"{"event":"pending"}"# + "\n" + #"{"event":"denied"}"# + "\n")
      .write(to: directory.appendingPathComponent("closed.jsonl"), atomically: true, encoding: .utf8)
    #expect(!reader.hasOpenRequest(sessionId: "closed"))
  }

  // MARK: View model

  @Test("The view model answers through the agent tab and records progress")
  func viewModelRoutesToAgentTab() async throws {
    let (viewModel, watcher) = makeViewModel()
    let surface = ApprovalSurface(screen: ClaudePermissionMenuFixtures.bashPlain)
    viewModel.activeTerminals["s1"] = surface
    try await seedPending(viewModel, watcher)

    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce) == .sent)
    #expect(surface.agentTyped == ["1"])
    #expect(surface.activeTyped.isEmpty)
    let signature = ApprovalSignature(state: viewModel.monitorStates["s1"])
    #expect(viewModel.approvalTracker.phase(for: "s1", current: signature) == .sending(.approveOnce))

    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .deny) == .sent)
    #expect(surface.escapes == 1)
  }

  @Test("The view model fails closed without a terminal and says so")
  func viewModelWithoutTerminal() async throws {
    let (viewModel, watcher) = makeViewModel()
    try await seedPending(viewModel, watcher)
    #expect(
      viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce)
        == .answerInTerminal(.terminalUnavailable))
    let signature = ApprovalSignature(state: viewModel.monitorStates["s1"])
    #expect(viewModel.approvalTracker.phase(for: "s1", current: signature) == .answerInTerminal)
  }

  @Test("The ⌘↩ handler is set and cleared on the session's surface")
  func shortcutHandlerRegistration() {
    let (viewModel, _) = makeViewModel()
    let surface = ApprovalSurface(screen: nil)
    viewModel.activeTerminals["s1"] = surface
    viewModel.setApprovalShortcutHandler(forKey: "s1") {}
    #expect(surface.approvalShortcutHandler != nil)
    viewModel.setApprovalShortcutHandler(forKey: "s1", nil)
    #expect(surface.approvalShortcutHandler == nil)
  }

  // MARK: Helpers

  private func responder(sidecarOpen: Bool = false) -> TerminalKeystrokeApprovalResponder {
    TerminalKeystrokeApprovalResponder(sidecar: StubSidecar(isOpen: sidecarOpen))
  }

  private func request(
    tool: String = "Bash",
    provider: SessionProviderKind = .claude,
    pending: Bool = true
  ) -> ApprovalRequestContext {
    ApprovalRequestContext(
      sessionId: "s1",
      providerKind: provider,
      pendingToolUse: pending ? PendingToolUse(toolName: tool, toolUseId: "t1", timestamp: Date()) : nil)
  }

  /// Seeds a pending Bash request the way the file watcher delivers it.
  private func seedPending(_ viewModel: CLISessionsViewModel, _ watcher: StubFileWatcher) async throws {
    viewModel.startMonitoring(session: CLISession(id: "s1", projectPath: "/tmp/approval-project"))
    watcher.send(
      sessionId: "s1",
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "Bash"),
        pendingToolUse: PendingToolUse(toolName: "Bash", toolUseId: "t1", timestamp: Date(), input: "ls")))
    for _ in 0..<50 where viewModel.monitorStates["s1"]?.pendingToolUse == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(viewModel.monitorStates["s1"]?.pendingToolUse != nil)
  }
}

// MARK: - Mocks

@MainActor
private final class MockApprovalTerminal: ApprovalKeystrokeTarget {
  let screen: [String]?
  let hasAgentTab: Bool
  private(set) var agentTyped: [String] = []
  private(set) var escapes = 0
  /// The responder has no way to reach the active tab; this stays empty.
  private(set) var activeTabTyped: [String] = []

  init(screen: [String]?, hasAgentTab: Bool = true) {
    self.screen = screen
    self.hasAgentTab = hasAgentTab
  }

  var sentNothing: Bool { agentTyped.isEmpty && escapes == 0 && activeTabTyped.isEmpty }

  func agentScreenTail(maxRows: Int) -> [String]? { screen.map { Array($0.suffix(maxRows)) } }

  func typeTextToAgentSession(_ text: String) -> Bool {
    guard hasAgentTab else { return false }
    agentTyped.append(text)
    return true
  }

  func sendEscapeToAgentSession() -> Bool {
    guard hasAgentTab else { return false }
    escapes += 1
    return true
  }
}

private struct StubSidecar: ApprovalSidecarReading {
  let isOpen: Bool
  func hasOpenRequest(sessionId: String) -> Bool { isOpen }
}

/// A surface with a separate agent tab and active tab.
@MainActor
private final class ApprovalSurface: NSView, EmbeddedTerminalSurface {
  var view: NSView { self }
  var currentProcessPID: Int32?
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  var approvalShortcutHandler: (() -> Void)?
  let screen: [String]?
  private(set) var activeTyped: [String] = []
  private(set) var agentTyped: [String] = []
  private(set) var escapes = 0

  init(screen: [String]?) {
    self.screen = screen
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

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
  func agentScreenTail(maxRows: Int) -> [String]? { screen }
  func typeTextToAgentSession(_ text: String) -> Bool {
    agentTyped.append(text)
    return true
  }
  func sendEscapeToAgentSession() -> Bool {
    escapes += 1
    return true
  }
}

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

private final class StubFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }
  func send(sessionId: String, state: SessionMonitorState) {
    subject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: state))
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
private func makeViewModel() -> (CLISessionsViewModel, StubFileWatcher) {
  let watcher = StubFileWatcher()
  let viewModel = CLISessionsViewModel(
    monitorService: StubMonitorService(),
    fileWatcher: watcher,
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
  // Never read the real sidecar directory from a test.
  viewModel.approvalResponder = TerminalKeystrokeApprovalResponder(sidecar: StubSidecar(isOpen: false))
  return (viewModel, watcher)
}
