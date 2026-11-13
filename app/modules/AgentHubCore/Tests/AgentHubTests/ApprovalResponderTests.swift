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

  @Test("A text backend that can't read the screen right now refuses; it never uses the sidecar")
  func scrolledBackTextBackendRefuses() {
    // SwiftTerm scrolled back: the backend reads text, but the live rows aren't readable now.
    let terminal = MockApprovalTerminal(screen: nil, canReadScreen: true)
    let withOpenSidecar = responder(openToolUseId: "t1")
    for decision in [ApprovalDecision.approveOnce, .approveAlways, .deny] {
      #expect(
        withOpenSidecar.respond(to: request(), decision: decision, terminal: terminal)
          == .answerInTerminal(.menuNotVisible))
    }
    #expect(terminal.sentNothing)
  }

  // MARK: Backends that can't read text

  @Test("Without screen text, the open sidecar request must be this tool use")
  func nonTextBackendNeedsMatchingSidecar() {
    let terminal = MockApprovalTerminal(screen: nil)
    #expect(
      responder(openToolUseId: nil).respond(to: request(), decision: .approveOnce, terminal: terminal)
        == .answerInTerminal(.noOpenSidecarRequest))
    #expect(
      responder(openToolUseId: "t0").respond(to: request(), decision: .deny, terminal: terminal)
        == .answerInTerminal(.noOpenSidecarRequest))
    #expect(terminal.sentNothing)

    let open = responder(openToolUseId: "t1")
    #expect(open.respond(to: request(), decision: .approveOnce, terminal: terminal) == .sent)
    #expect(open.respond(to: request(), decision: .deny, terminal: terminal) == .sent)
    #expect(terminal.agentTyped == ["1"])
    #expect(terminal.escapes == 1)
  }

  @Test("Without screen text, Always allow is refused: option 2 can't be checked")
  func nonTextBackendRefusesAlwaysAllow() {
    let terminal = MockApprovalTerminal(screen: nil)
    #expect(
      responder(openToolUseId: "t1").respond(to: request(), decision: .approveAlways, terminal: terminal)
        == .answerInTerminal(.menuNotVisible))
    #expect(terminal.sentNothing)
  }

  // MARK: Shared predicate

  @Test("Approvable: Claude permission prompts only, never input questions or Codex")
  func approvablePredicate() {
    #expect(ApprovablePermission.matches(toolName: "Bash", providerKind: .claude))
    #expect(ApprovablePermission.matches(toolName: "mcp__github__create_pr", providerKind: .claude))
    #expect(!ApprovablePermission.matches(toolName: "AskUserQuestion", providerKind: .claude))
    #expect(!ApprovablePermission.matches(toolName: "mcp__codex__request_user_input", providerKind: .claude))
    #expect(!ApprovablePermission.matches(toolName: "Bash", providerKind: .codex))
    #expect(!ApprovablePermission.matches(toolName: nil, providerKind: .claude))
    let pending = PendingToolUse(toolName: "Edit", toolUseId: "t1", timestamp: Date())
    #expect(pending.isApprovablePermission(providerKind: .claude))
    #expect(!pending.isApprovablePermission(providerKind: .codex))
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

  @Test("The open request is the last pending line with no later resolved/denied")
  func sidecarState() {
    func open(_ lines: [String]) -> String? {
      ApprovalSidecarState.openRequestToolUseId(lines: lines.map { Substring($0) }, sessionId: "s1")
    }
    let pending = #"{"event":"pending","toolName":"Bash","toolUseId":"t1"}"#
    let observed = #"{"event":"observed","toolName":"Bash","toolUseId":"t1"}"#
    let resolved = #"{"event":"resolved","toolName":"Bash","toolUseId":"t1"}"#
    let denied = #"{"event":"denied","toolName":"Bash","toolUseId":"t1"}"#
    #expect(open([pending]) == "t1")
    #expect(open([pending, observed]) == "t1")
    #expect(open([pending, resolved]) == nil)
    #expect(open([pending, denied]) == nil)
    #expect(open([resolved, pending, "{broken"]) == "t1")
    #expect(open([]) == nil)
    // Same fallbacks as ClaudeHookSidecarWatcher: no id → hook-<sid>, empty stays empty.
    #expect(open([#"{"event":"pending"}"#]) == "hook-s1")
    #expect(open([#"{"event":"pending","toolUseId":""}"#]) == "")
  }

  @Test("The file reader reads only the tail and ignores a cut first line")
  func sidecarFileReader() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApprovalResponderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = FileApprovalSidecarReader(
      fileURL: { directory.appendingPathComponent("\($0).jsonl") }, maxBytes: 64)

    #expect(reader.openRequestToolUseId(sessionId: "missing") == nil)

    let filler = String(repeating: #"{"event":"observed"}"# + "\n", count: 20)
    try (#"{"event":"resolved"}"# + "\n" + filler + #"{"event":"pending","toolUseId":"t9"}"# + "\n")
      .write(to: directory.appendingPathComponent("open.jsonl"), atomically: true, encoding: .utf8)
    #expect(reader.openRequestToolUseId(sessionId: "open") == "t9")

    try (#"{"event":"pending"}"# + "\n" + #"{"event":"denied"}"# + "\n")
      .write(to: directory.appendingPathComponent("closed.jsonl"), atomically: true, encoding: .utf8)
    #expect(reader.openRequestToolUseId(sessionId: "closed") == nil)
  }

  // MARK: View model

  @Test("The view model answers through the agent tab, once per request")
  func viewModelRoutesToAgentTabOnce() async throws {
    let (viewModel, watcher) = makeViewModel()
    let surface = ApprovalSurface(screen: ClaudePermissionMenuFixtures.bashPlain, canReadScreen: true)
    viewModel.activeTerminals["s1"] = surface
    try await seedPending(viewModel, watcher, toolUseId: "t1")

    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce) == .sent)
    #expect(surface.agentTyped == ["1"])
    #expect(surface.activeTyped.isEmpty)
    #expect(viewModel.approvalTracker.phase(for: "s1", request: currentRequest(viewModel)) == .sending(.approveOnce))

    // The menu still shows (or the tool runs): a second answer is refused.
    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .deny) == .answerInTerminal(.alreadyAnswered))
    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce) == .answerInTerminal(.alreadyAnswered))
    #expect(surface.escapes == 0)
    #expect(surface.agentTyped == ["1"])

    // A new request can be answered again.
    try await seedPending(viewModel, watcher, toolUseId: "t2")
    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .deny) == .sent)
    #expect(surface.escapes == 1)
  }

  @Test("No screen text: an approved tool still pending in the sidecar never gets a second key")
  func viewModelNonTextBackendRunningTool() async throws {
    // The hook writes `resolved` only after the tool finishes, so while it runs
    // the sidecar still shows this request open.
    let (viewModel, watcher) = makeViewModel(openToolUseId: "t1")
    let surface = ApprovalSurface(screen: nil, canReadScreen: false)
    viewModel.activeTerminals["s1"] = surface
    try await seedPending(viewModel, watcher, toolUseId: "t1")

    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce) == .sent)
    for decision in [ApprovalDecision.approveOnce, .deny] {
      #expect(viewModel.respondToApproval(sessionId: "s1", decision: decision) == .answerInTerminal(.alreadyAnswered))
    }
    #expect(surface.agentTyped == ["1"])
    #expect(surface.escapes == 0)
    #expect(viewModel.approvalTracker.hasAnswered(sessionId: "s1", request: currentRequest(viewModel)!))
  }

  @Test("The view model fails closed without a terminal and allows a retry")
  func viewModelWithoutTerminal() async throws {
    let (viewModel, watcher) = makeViewModel()
    try await seedPending(viewModel, watcher, toolUseId: "t1")
    #expect(
      viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce)
        == .answerInTerminal(.terminalUnavailable))
    #expect(viewModel.approvalTracker.phase(for: "s1", request: currentRequest(viewModel)) == .answerInTerminal)

    let surface = ApprovalSurface(screen: ClaudePermissionMenuFixtures.bashPlain, canReadScreen: true)
    viewModel.activeTerminals["s1"] = surface
    #expect(viewModel.respondToApproval(sessionId: "s1", decision: .approveOnce) == .sent)
  }

  @Test("The ⌘↩ handler is set and cleared on the session's surface")
  func shortcutHandlerRegistration() {
    let (viewModel, _) = makeViewModel()
    let surface = ApprovalSurface(screen: nil, canReadScreen: false)
    viewModel.activeTerminals["s1"] = surface
    viewModel.setApprovalShortcutHandler(forKey: "s1") {}
    #expect(surface.approvalShortcutHandler != nil)
    viewModel.setApprovalShortcutHandler(forKey: "s1", nil)
    #expect(surface.approvalShortcutHandler == nil)
  }

  // MARK: Refusal fallbacks

  @Test("The tree pill opens the session only when the app could not answer")
  func sidebarOpensSessionOnRefusalOnly() {
    let node = SessionNode(
      id: "s1", session: CLISession(id: "s1", projectPath: "/tmp/Repo"), providerKind: .claude,
      isPending: false, status: .awaitingApproval(tool: "Bash"), pendingToolName: "Bash")
    var opened: [String] = []
    var outcome = ApprovalResponseOutcome.sent
    let approve = SidebarApproval.respond(
      answer: { _ in outcome }, openSession: { opened.append($0.id) })

    approve(node)
    #expect(opened.isEmpty)
    outcome = .answerInTerminal(.menuNotVisible)
    approve(node)
    outcome = .answerInTerminal(.alreadyAnswered)
    approve(node)
    #expect(opened == ["s1", "s1"])
  }

  @Test("The chat Approve switches to the terminal only when the app could not answer")
  func chatFallsBackToTerminalOnRefusal() {
    var shown = 0
    ChatApprovalAction.approve({ true }, fallback: { shown += 1 })
    #expect(shown == 0)
    ChatApprovalAction.approve({ false }, fallback: { shown += 1 })
    #expect(shown == 1)
  }

  // MARK: Helpers

  private func responder(openToolUseId: String? = nil) -> TerminalKeystrokeApprovalResponder {
    TerminalKeystrokeApprovalResponder(sidecar: StubSidecar(openToolUseId: openToolUseId))
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

  private func currentRequest(_ viewModel: CLISessionsViewModel) -> ApprovalRequestKey? {
    ApprovalRequestKey(state: viewModel.monitorStates["s1"])
  }

  /// Seeds a pending Bash request the way the file watcher delivers it.
  private func seedPending(
    _ viewModel: CLISessionsViewModel, _ watcher: StubFileWatcher, toolUseId: String
  ) async throws {
    if viewModel.monitorStates["s1"] == nil {
      viewModel.startMonitoring(session: CLISession(id: "s1", projectPath: "/tmp/approval-project"))
    }
    watcher.send(
      sessionId: "s1",
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "Bash"),
        pendingToolUse: PendingToolUse(toolName: "Bash", toolUseId: toolUseId, timestamp: Date(), input: "ls")))
    for _ in 0..<50 where viewModel.monitorStates["s1"]?.pendingToolUse?.toolUseId != toolUseId {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(viewModel.monitorStates["s1"]?.pendingToolUse?.toolUseId == toolUseId)
  }
}

// MARK: - Mocks

@MainActor
private final class MockApprovalTerminal: ApprovalKeystrokeTarget {
  let screen: [String]?
  let canReadScreen: Bool
  let hasAgentTab: Bool
  private(set) var agentTyped: [String] = []
  private(set) var escapes = 0
  /// The responder has no way to reach the active tab; this stays empty.
  private(set) var activeTabTyped: [String] = []

  /// `canReadScreen` defaults to "a screen was given" (SwiftTerm vs Ghostty).
  init(screen: [String]?, canReadScreen: Bool? = nil, hasAgentTab: Bool = true) {
    self.screen = screen
    self.canReadScreen = canReadScreen ?? (screen != nil)
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
  let openToolUseId: String?
  func openRequestToolUseId(sessionId: String) -> String? { openToolUseId }
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
  let canReadAgentScreen: Bool
  private(set) var activeTyped: [String] = []
  private(set) var agentTyped: [String] = []
  private(set) var escapes = 0

  init(screen: [String]?, canReadScreen: Bool) {
    self.screen = screen
    self.canReadAgentScreen = canReadScreen
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
private func makeViewModel(openToolUseId: String? = nil) -> (CLISessionsViewModel, StubFileWatcher) {
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
  viewModel.approvalResponder = TerminalKeystrokeApprovalResponder(
    sidecar: StubSidecar(openToolUseId: openToolUseId))
  return (viewModel, watcher)
}
