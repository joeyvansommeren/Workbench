import AgentHubGitHub
import AppKit
import Combine
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import AgentHubCore

private final class OriginMonitor: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    subject.send(repositories)
  }
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor OriginWatcher: SessionFileWatcherProtocol {
  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    Empty().eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
@Suite("Ticket launch identity", .serialized)
struct SessionLaunchOriginTests {
  private func makeViewModel(
    store: SessionMetadataStore?, provider: SessionProviderKind, available: Bool = true,
    monitor: OriginMonitor = OriginMonitor(),
    codexPath: String = "/tmp/tes317-no-provider-data",
    claudePath: String = "/tmp/tes317-no-claude-data",
    ownership: any PendingSessionFileOwning = PendingSessionFileOwnership(),
    terminalFactory: any EmbeddedTerminalSurfaceFactory = DefaultEmbeddedTerminalSurfaceFactory(),
    terminalBackend: EmbeddedTerminalBackend = .regular
  ) -> CLISessionsViewModel {
    CLISessionsViewModel(
      monitorService: monitor, fileWatcher: OriginWatcher(), searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider, metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService(),
      cliAvailabilityService: CLIAvailabilityService(findExecutable: { _, _, _ in
        available ? "/fixture/agent" : nil
      }),
      codexDataPath: codexPath, claudeDataPath: claudePath,
      terminalSurfaceFactory: terminalFactory, terminalBackend: terminalBackend,
      pendingSessionFileOwnership: ownership)
  }

  private func origin(_ source: SessionLaunchOrigin.Source = .linear) -> SessionLaunchOrigin {
    SessionLaunchOrigin(
      source: source, accountID: "account-333@example.test", sourceID: "issue-333",
      key: "TEST-333", title: String(repeating: "長い題名 🌻 ", count: 40))
  }

  @Test(
    "Workspace ticket action persists full source identity before publishing pending state",
    arguments: [SessionProviderKind.claude, .codex], [SessionLaunchOrigin.Source.linear, .jira])
  func ticketAction(provider: SessionProviderKind, source: SessionLaunchOrigin.Source) throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: provider)
    let sourceOrigin = origin(source)
    let pendingID = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: sourceOrigin, prompt: "Synthetic fixture prompt", repositoryPath: "/tmp/ticket-333",
        viewModel: vm))
    let pending = try #require(vm.pendingHubSessions.first)
    defer { vm.cancelPendingSession(pending) }
    #expect(pending.id == pendingID)
    #expect(vm.displayName(for: pending.placeholderSession) == sourceOrigin.displayName)
    let record = try #require(store.launchOrigins(provider: provider).first)
    #expect(record.pendingID == pendingID.uuidString)
    #expect(try record.launch().origin == sourceOrigin)
    #expect(!String(decoding: record.payload, as: UTF8.self).contains("Synthetic fixture prompt"))
    #expect((pending.expectedSessionID != nil) == (provider == .claude))
  }

  @Test("Failed launch returns nil instead of another launch's pending ID")
  func failedLaunch() throws {
    let vm = makeViewModel(store: nil, provider: .claude)
    vm.lastCreatedPendingId = UUID()
    #expect(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(), prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm) == nil)
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(vm.launchError != nil)
    let unavailable = makeViewModel(
      store: try SessionMetadataStore(path: ":memory:"), provider: .codex, available: false)
    unavailable.lastCreatedPendingId = UUID()
    #expect(
      unavailable.startAutomatedSessionInHub(
        WorktreeBranch(name: "main", path: "/tmp/test-333"), initialPrompt: "") == nil)
  }

  @Test(
    "Resolution survives restart, repeats safely, and preserves manual title precedence",
    arguments: [SessionProviderKind.claude, .codex])
  func resolution(provider: SessionProviderKind) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "origin-\(UUID()).sqlite"
    ).path
    let store = try SessionMetadataStore(path: path)
    let vm = makeViewModel(store: store, provider: provider)
    let id = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(), prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm))
    let pending = try #require(vm.pendingHubSessions.first)
    let sessionID = pending.expectedSessionID ?? "resolved-333"
    try store.resolveLaunchOrigin(pendingID: id, provider: provider, sessionID: sessionID)
    try store.resolveLaunchOrigin(pendingID: id, provider: provider, sessionID: sessionID)
    try await store.setCustomName("My manual title", for: sessionID)
    let reopened = try SessionMetadataStore(path: path)
    let recovered = makeViewModel(store: reopened, provider: provider)
    let session = CLISession(id: sessionID, projectPath: "/tmp/test-333", slug: "Provider title")
    #expect(recovered.displayName(for: session) == "My manual title")
    recovered.setCustomName("My manual title", for: session)
    for _ in 0..<100 where recovered.sessionCustomNames[sessionID] == nil { await Task.yield() }
    #expect(recovered.displayName(for: session) == "My manual title")
    #expect(recovered.resolvedPendingSessionHistory[id] == sessionID)
    #expect(recovered.pendingHubSessions.isEmpty)
    vm.cancelPendingSession(pending)
  }

  @Test(
    "Restart before resolution restores origin without replaying prompt",
    arguments: [SessionProviderKind.claude, .codex])
  func unresolvedRestart(provider: SessionProviderKind) throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: provider)
    let id = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(.jira), prompt: "Do not replay", repositoryPath: "/tmp/test-333",
        viewModel: vm))
    let restored = makeViewModel(store: store, provider: provider)
    let pending = try #require(restored.pendingHubSessions.first)
    #expect(pending.id == id)
    #expect(pending.origin == origin(.jira))
    #expect(pending.initialPrompt == nil)
    #expect(restored.restoredLaunchMessage(for: pending.placeholderSession.id) != nil)
    #expect(pending.needsIdentification == (provider == .codex))
    for row in vm.pendingHubSessions { vm.cancelPendingSession(row) }
    restored.cancelPendingSession(pending)
  }

  @Test(
    "Explicit recovery after restart binds only the confirmed candidate and preserves manual names",
    arguments: [SessionProviderKind.claude, .codex], [SessionLaunchOrigin.Source.linear, .jira])
  func confirmedRestartRecovery(
    provider: SessionProviderKind, source: SessionLaunchOrigin.Source
  ) async throws {
    for resolvedRename in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = try SessionMetadataStore(path: directory.appendingPathComponent("metadata.sqlite").path)
      let sessionID = "11111111-2222-3333-4444-555555555555"
      let startedAt = Date().addingTimeInterval(-30)
      let file = directory.appendingPathComponent("session.jsonl")
      let oldFile = directory.appendingPathComponent("old.jsonl")
      let pending = PendingHubSession(
        worktree: WorktreeBranch(name: "main", path: directory.path), startedAt: startedAt,
        origin: origin(source), expectedSessionID: provider == .claude ? sessionID : nil,
        needsIdentification: true, existingSessionIdentifiers: [oldFile.path, "old-session"])
      try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: provider))
      try await store.setCustomName("Pending rename", for: "pending-\(pending.id.uuidString)")
      if resolvedRename { try await store.setCustomName("Existing manual rename", for: sessionID) }
      let payload: [String: Any] = [
        "type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: Date()),
        "payload": ["id": sessionID, "cwd": directory.path, "source": "cli"]]
      var data = try JSONSerialization.data(withJSONObject: payload)
      data.append(0x0a)
      try data.write(to: file)
      try data.write(to: oldFile)
      let candidate = CLISession(
        id: sessionID, projectPath: directory.path, slug: "Provider title", sessionFilePath: file.path)
      let unrelated = CLISession(id: "unrelated", projectPath: "/different/repository")
      let old = CLISession(
        id: "old-session", projectPath: directory.path, sessionFilePath: oldFile.path)
      let monitor = OriginMonitor()
      let restored = makeViewModel(store: store, provider: provider, monitor: monitor)
      var repository = SelectedRepository(path: directory.path)
      repository.worktrees = [
        WorktreeBranch(name: "main", path: directory.path, sessions: [candidate, unrelated, old])]
      await monitor.setSelectedRepositories([repository])
      for _ in 0..<100 where restored.allSessions.isEmpty { await Task.yield() }
      let recovered = try #require(restored.pendingHubSessions.first)
      #expect(restored.recoveryCandidates(for: recovered).map(\.id) == [sessionID])
      #expect(!restored.confirmRecoveredLaunch(pending.id, sessionID: unrelated.id))
      #expect(!restored.confirmRecoveredLaunch(pending.id, sessionID: old.id))
      #expect(try store.launchOrigins(provider: provider).first?.sessionID == nil)
      #expect(restored.confirmRecoveredLaunch(pending.id, sessionID: sessionID))
      #expect(restored.pendingHubSessions.isEmpty)
      #expect(restored.resolvedPendingSessionHistory[pending.id] == sessionID)
      #expect(restored.displayName(for: candidate) == (resolvedRename ? "Existing manual rename" : "Pending rename"))
      #expect(restored.sessionOrigins[unrelated.id] == nil)
      #expect(!restored.confirmRecoveredLaunch(pending.id, sessionID: sessionID))
      let reopened = makeViewModel(store: store, provider: provider)
      #expect(reopened.sessionOrigins[sessionID] == origin(source))
      #expect(reopened.displayName(for: candidate) == restored.displayName(for: candidate))
      restored.stopMonitoring(sessionId: sessionID)
    }
  }

  @Test("Concurrent Codex launches cannot resolve without process evidence")
  func concurrentCodex() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: .codex)
    for _ in 0..<2 {
      _ = try #require(
        WorkspaceLaunchActions.startTicketSession(
          origin: origin(), prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm))
    }
    #expect(vm.pendingHubSessions.count == 2)
    for pending in vm.pendingHubSessions {
      #expect(
        !vm.handleNewSessionFound(
          sessionId: "unrelated", pending: pending, worktree: pending.worktree))
    }
    let restored = makeViewModel(store: store, provider: .codex)
    #expect(restored.pendingHubSessions.allSatisfy { $0.needsIdentification })
    for pending in vm.pendingHubSessions { vm.cancelPendingSession(pending) }
  }

  @Test("Claude ignores a different launch's session UUID and a failed launch cannot resolve")
  func exactClaudeIdentity() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: .claude)
    for _ in 0..<2 {
      _ = try #require(
        WorkspaceLaunchActions.startTicketSession(
          origin: origin(), prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm))
    }
    let first = vm.pendingHubSessions[0]
    let second = vm.pendingHubSessions[1]
    #expect(
      !vm.handleNewSessionFound(
        sessionId: second.expectedSessionID!, pending: first, worktree: first.worktree))
    vm.markPendingSessionFailed(first.id)
    #expect(
      !vm.handleNewSessionFound(
        sessionId: first.expectedSessionID!, pending: first, worktree: first.worktree))
    #expect(
      try store.launchOrigins(provider: .claude).first { $0.pendingID == first.id.uuidString }?
        .launch().failed == true)
    for pending in vm.pendingHubSessions { vm.cancelPendingSession(pending) }
  }

  @Test("Assigned Claude ID is a new-session flag and never changes resume")
  func assignedIDFlag() {
    var config = CLICommandConfiguration.claudeDefault
    config.newSessionID = "11111111-2222-3333-4444-555555555555"
    #expect(config.argumentsForSession(sessionId: nil, prompt: nil).contains("--session-id"))
    #expect(
      !config.argumentsForSession(sessionId: "existing", prompt: nil).contains("--session-id"))
    config.mode = .codex
    #expect(!config.argumentsForSession(sessionId: nil, prompt: nil).contains("--session-id"))
  }

  @Test(
    "Exact resolution moves the pending title onto the monitored session",
    arguments: [SessionProviderKind.claude, .codex], [SessionLaunchOrigin.Source.linear, .jira])
  func pendingToResolved(provider: SessionProviderKind, source: SessionLaunchOrigin.Source)
    async throws
  {
    let store = try SessionMetadataStore(path: ":memory:")
    let monitor = OriginMonitor()
    let vm = makeViewModel(store: store, provider: provider, monitor: monitor)
    let id = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(source), prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm))
    let pending = try #require(vm.pendingHubSessions.first)
    let session = CLISession(
      id: pending.expectedSessionID ?? "codex-resolved-333", projectPath: pending.projectPath)
    var repository = SelectedRepository(path: pending.projectPath)
    repository.worktrees = [
      WorktreeBranch(name: "main", path: pending.projectPath, sessions: [session])
    ]
    await monitor.setSelectedRepositories([repository])
    for _ in 0..<100 where vm.allSessions.isEmpty { await Task.yield() }
    #expect(
      vm.handleNewSessionFound(
        sessionId: session.id, pending: pending, worktree: pending.worktree,
        verifiedProcessFile: provider == .codex))
    for _ in 0..<100 where vm.resolvedPendingSessionHistory[id] == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(vm.resolvedPendingSessionHistory[id] == session.id)
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(vm.displayName(for: session) == origin(source).displayName)
    #expect(try store.launchOrigins(provider: provider).first?.sessionID == session.id)
    vm.stopMonitoring(sessionId: session.id)
  }

  @Test("Pending renames follow resolution regardless of save order")
  func pendingRename() async throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/test-333"),
      origin: origin(), expectedSessionID: "resolved-333")
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: .claude))
    let pendingKey = "pending-\(pending.id.uuidString)"
    try await store.setCustomName("Before", for: pendingKey)
    try store.resolveLaunchOrigin(
      pendingID: pending.id, provider: .claude, sessionID: "resolved-333")
    #expect(try await store.getCustomName(for: "resolved-333") == "Before")
    try await store.setCustomName("After", for: pendingKey)
    #expect(try await store.getCustomName(for: "resolved-333") == "After")
    try await store.setCustomName(nil, for: pendingKey)
    #expect(try await store.getCustomName(for: "resolved-333") == nil)
    try store.resolveLaunchOrigin(
      pendingID: pending.id, provider: .claude, sessionID: "resolved-333")
    #expect(try await store.getCustomName(for: "resolved-333") == nil)
    try await store.setCustomName("Later manual name", for: "resolved-333")
    try store.resolveLaunchOrigin(
      pendingID: pending.id, provider: .claude, sessionID: "resolved-333")
    #expect(try await store.getCustomName(for: "resolved-333") == "Later manual name")
    #expect(throws: (any Error).self) {
      try store.resolveLaunchOrigin(pendingID: pending.id, provider: .claude, sessionID: "wrong")
    }
  }

  @Test("Ticket link titles use immutable identity and reject another source account")
  func linkedTitles() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: .claude)
    let source = origin()
    _ = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: source, prompt: "", repositoryPath: "/tmp/test-333", viewModel: vm))
    let linker = LinearSessionLinker()
    let links = linker.links(
      from: [vm], knownLinearTeamKeys: ["TEST"], knownJiraProjectKeys: [],
      sourceAccountID: source.accountID, sourceIssueKeys: [source.sourceID: "RENAMED-333"])
    #expect(links["RENAMED-333"]?.first?.title == source.displayName)
    #expect(
      linker.links(
        from: [vm], knownLinearTeamKeys: ["TEST"], knownJiraProjectKeys: [],
        sourceAccountID: "another-account", sourceIssueKeys: [source.sourceID: "TEST-333"]
      ).isEmpty)
    #expect(
      linker.links(
        from: [vm], knownLinearTeamKeys: ["TEST"], knownJiraProjectKeys: [],
        sourceAccountID: source.accountID, sourceIssueKeys: [:]
      ).isEmpty)
    for pending in vm.pendingHubSessions { vm.cancelPendingSession(pending) }
  }

  @Test("PR-origin title remains below manual rename and above provider title")
  func pullRequestTitle() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/test-333"),
      origin: SessionLaunchOrigin(
        source: .pullRequest, accountID: "github.example.test/test/repo",
        sourceID: "pr-id-333", key: "#333", title: "Review title"),
      expectedSessionID: "pr-session-333")
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: .claude))
    try store.resolveLaunchOrigin(
      pendingID: pending.id, provider: .claude, sessionID: "pr-session-333")
    let vm = makeViewModel(store: store, provider: .claude)
    let session = CLISession(id: "pr-session-333", projectPath: "/tmp/test-333", slug: "Provider")
    #expect(vm.displayName(for: session) == "#333 Review title")
    let result = SessionSearchResult(
      id: session.id, slug: "Provider", projectPath: session.projectPath,
      gitBranch: nil, firstMessage: nil, summaries: [], lastActivityAt: Date(), matchedField: .slug,
      matchedText: "Provider")
    #expect(
      vm.applyingSessionTitles(to: [result], query: "Review", filterPath: nil).first?.slug
        == "#333 Review title")
    #expect(
      vm.displayName(
        for: CLISession(id: "unrelated", projectPath: "/tmp/test-333", slug: "Unrelated"))
        == "Unrelated")
  }

  @Test("Actual sidebar, browser and selected rows retain origin above a later PR and branch")
  func presentationBoundaries() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/test-333"),
      origin: origin(), expectedSessionID: "session-333")
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: .claude))
    try store.resolveLaunchOrigin(
      pendingID: pending.id, provider: .claude, sessionID: "session-333")
    let vm = makeViewModel(store: store, provider: .claude)
    let session = CLISession(
      id: "session-333", projectPath: "/tmp/test-333", branchName: "codex/unrelated-branch",
      slug: "Provider")
    let pr = try #require(
      GitHubPullRequestURLReference(urlString: "https://github.com/example/repository/pull/333"))
    let row = CollapsibleSessionRow(
      session: session, providerKind: .claude,
      timestamp: Date(), isPending: false, isPrimary: false,
      customName: vm.sessionCustomNames[session.id], displayTitle: vm.displayName(for: session),
      sessionStatus: nil, linkedPullRequests: [pr], colorScheme: .dark, isPinned: false,
      onPin: nil, onArchive: nil, onSelect: {})
    #expect(row.presentation.title == origin().displayName)
    #expect(row.customName == nil)
    let browser = SessionBrowserRow(
      session: session, state: nil, providerKind: .claude,
      isFocused: false, isHighlighted: false, displayTitle: vm.displayName(for: session),
      onSelect: {})
    #expect(browser.displayName == origin().displayName)
    let selected = SelectedSessionRow(
      session: session, providerKind: .claude,
      timestamp: Date(), isPending: false, isPrimary: false,
      displayTitle: vm.displayName(for: session), onSelect: {})
    #expect(selected.displayTitle == origin().displayName)
    let legacy = CLISessionRow(
      session: session, customName: nil, displayTitle: vm.displayName(for: session),
      isMonitoring: true, onConnect: {}, onCopyId: {}, onOpenFile: {}, onToggleMonitoring: {})
    #expect(legacy.displayTitle == origin().displayName)
    #expect(legacy.customName == nil)
  }

  @Test("Codex polling retains all unresolved candidates and stops after a failed launch")
  func codexCandidateSetAndFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-candidates-\(UUID())")
    let sessions = directory.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let spy = OriginOwnershipSpy()
    let vm = makeViewModel(store: nil, provider: .codex, codexPath: directory.path, ownership: spy)
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/test-333"), origin: origin())
    vm.pendingHubSessions = [pending]
    let child = Process()
    let input = Pipe()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
      try? input.fileHandleForWriting.close()
      child.waitUntilExit()
    }
    vm.recordPendingLaunchProcess(
      forKey: pending.placeholderSession.id, processID: child.processIdentifier)
    func write(_ name: String) throws -> String {
      let file = sessions.appendingPathComponent(name + ".jsonl")
      let data = try JSONSerialization.data(withJSONObject: [
        "type": "session_meta",
        "payload": ["id": name, "cwd": pending.projectPath, "source": "cli"],
      ])
      try data.write(to: file)
      return file.resolvingSymlinksInPath().path
    }
    let ownFile = try write("already-seen")
    let task = Task {
      await vm.watchForNewCodexSession(pending: pending, worktree: pending.worktree)
    }
    for _ in 0..<100 where await spy.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    let foreignFile = try write("new-foreign")
    for _ in 0..<200 where await spy.calls.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    let observedCalls = await spy.calls
    let latestPaths = observedCalls.last.map { paths in
      Set(paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
    }
    #expect(latestPaths == [ownFile, foreignFile], "Observed candidates: \(observedCalls)")
    vm.markPendingSessionFailed(pending.id)
    await task.value
    let callCount = await spy.calls.count
    await vm.watchForNewCodexSession(pending: pending, worktree: pending.worktree)
    #expect(await spy.calls.count == callCount)
    #expect(!vm.shouldWatchPendingSession(pending.id))
  }

  @Test(
    "Wrapper child writer offers explicit live recovery without replacing the terminal",
    arguments: [false, true], [false, true])
  func wrapperWriterRecovery(withOrigin: Bool, resolvedRename: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wrapper-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("wrapper-session.jsonl")
    let sessionID = "wrapper-session"
    let store = try SessionMetadataStore(path: ":memory:")
    let monitor = OriginMonitor()
    let factory = OriginTerminalFactory()
    let vm = makeViewModel(
      store: store, provider: .codex, monitor: monitor, terminalFactory: factory)
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: directory.path),
      startedAt: Date().addingTimeInterval(-10), origin: withOrigin ? origin() : nil)
    vm.pendingHubSessions = [pending]
    if withOrigin {
      try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: .codex))
    }
    let pendingKey = pending.placeholderSession.id
    try await store.setCustomName("Pending manual name", for: pendingKey)
    if resolvedRename { try await store.setCustomName("Resolved manual name", for: sessionID) }
    _ = vm.getOrCreateTerminal(forKey: pendingKey, sessionId: nil, projectPath: directory.path)
    let terminal = try #require(factory.surfaces.first)
    let payload: [String: Any] = [
      "type": "session_meta", "timestamp": ISO8601DateFormatter().string(from: Date()),
      "payload": ["id": sessionID, "cwd": directory.path, "source": "cli"]]
    var data = try JSONSerialization.data(withJSONObject: payload)
    data.append(0x0a)
    try data.write(to: file)
    let wrapper = Process()
    let input = Pipe()
    let output = Pipe()
    wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Reproduce a launcher that waits while its native child owns the session file.
    wrapper.arguments = [
      "-c",
      "exec 4<&0; /bin/sh -c 'exec 3>> \"$1\"; printf \"ready\\n\"; read -r line' fixture \"$1\" <&4 & wait",
      "wrapper", file.path,
    ]
    wrapper.standardInput = input
    wrapper.standardOutput = output
    wrapper.standardError = FileHandle.nullDevice
    try wrapper.run()
    defer {
      try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
      try? input.fileHandleForWriting.close()
      wrapper.waitUntilExit()
      for row in vm.pendingHubSessions { vm.cancelPendingSession(row) }
      vm.stopMonitoring(sessionId: sessionID)
    }
    _ = try output.fileHandleForReading.read(upToCount: 6)
    vm.recordPendingLaunchProcess(forKey: pendingKey, processID: wrapper.processIdentifier)
    let session = CLISession(
      id: sessionID, projectPath: directory.path, slug: "Provider title", sessionFilePath: file.path)
    var repository = SelectedRepository(path: directory.path)
    repository.worktrees = [
      WorktreeBranch(name: "main", path: directory.path, sessions: [session])]
    await monitor.setSelectedRepositories([repository])
    for _ in 0..<100 where vm.allSessions.isEmpty { await Task.yield() }
    #expect(await vm.findRecentCodexSession(
      in: [file.path], pending: pending, worktree: pending.worktree,
      pendingStartedAt: pending.startedAt) == nil)
    let recovery = try #require(vm.pendingHubSessions.first)
    #expect(recovery.needsIdentification)
    #expect(!vm.shouldWatchPendingSession(pending.id))
    #expect(vm.pendingLaunchRecoveryMessage(for: pendingKey)?.contains("Link session") == true)
    #expect(vm.recoveryCandidates(for: recovery).map(\.id) == [sessionID])
    #expect(vm.activeTerminals[pendingKey] as? OriginTerminalSurface === terminal)
    #expect(vm.confirmRecoveredLaunch(pending.id, sessionID: sessionID))
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(vm.activeTerminals[pendingKey] == nil)
    #expect(vm.activeTerminals[sessionID] as? OriginTerminalSurface === terminal)
    #expect(terminal.configureCount == 1)
    #expect(terminal.restartCount == 0)
    #expect(terminal.terminateCount == 0)
    #expect(vm.displayName(for: session)
      == (resolvedRename ? "Resolved manual name" : "Pending manual name"))
    if withOrigin { #expect(vm.sessionOrigins[sessionID] == origin()) }
  }

  @Test("Claude directory fallback returns for a failed row")
  func failedClaudePolling() async throws {
    let vm = makeViewModel(store: nil, provider: .claude)
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "main", path: "/tmp/absent-\(UUID())"))
    vm.pendingHubSessions = [pending]
    vm.markPendingSessionFailed(pending.id)
    #expect(!vm.shouldWatchPendingSession(pending.id))
    await vm.watchForNewClaudeSession(pending: pending, worktree: pending.worktree)
    await vm.pollForNewClaudeSessionFallback(pending: pending, worktree: pending.worktree)
    #expect(vm.pendingHubSessions.first?.isFailed == true)
  }

  @Test(
    "Concurrent Codex polling resolves each direct writer and rejects a competing file",
    arguments: [false, true])
  func concurrentCodexWriterResolution(withOrigin: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-writers-\(UUID())")
    let sessionsDirectory = directory.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(
      at: sessionsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SessionMetadataStore(path: ":memory:")
    let monitor = OriginMonitor()
    let ownership = OriginOwnershipGate()
    let vm = makeViewModel(
      store: store, provider: .codex, monitor: monitor, codexPath: directory.path,
      ownership: ownership)
    let worktree = WorktreeBranch(name: "main", path: "/tmp/two-writers")
    let pending = (0..<2).map { index in
      PendingHubSession(
        worktree: worktree,
        origin: withOrigin
          ? SessionLaunchOrigin(
            source: .linear, accountID: "fixture-account", sourceID: "issue-\(index)",
            key: "TEST-\(index)", title: "Distinct title \(index)") : nil)
    }
    vm.pendingHubSessions = pending
    if withOrigin {
      for item in pending {
        try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: item, provider: .codex))
      }
    }
    let sessions = (0..<2).map { index in
      CLISession(id: "owned-\(index)", projectPath: worktree.path, slug: "Provider \(index)")
    }
    var repository = SelectedRepository(path: worktree.path)
    repository.worktrees = [WorktreeBranch(name: "main", path: worktree.path, sessions: sessions)]
    await monitor.setSelectedRepositories([repository])
    for _ in 0..<100 where vm.allSessions.count != 2 { await Task.yield() }
    #expect(vm.allSessions.count == 2)
    var children: [(Process, Pipe)] = []
    defer {
      for item in pending { vm.cancelPendingSession(item) }
      for session in sessions { vm.stopMonitoring(sessionId: session.id) }
      for (child, input) in children {
        try? input.fileHandleForWriting.close()
        child.waitUntilExit()
      }
    }
    for index in 0..<3 {
      let file = sessionsDirectory.appendingPathComponent(
        index < 2 ? "owned-\(index).jsonl" : "foreign.jsonl")
      let id = index < 2 ? sessions[index].id : "foreign"
      try JSONSerialization.data(withJSONObject: [
        "type": "session_meta", "payload": ["id": id, "cwd": worktree.path, "source": "cli"],
      ]).write(to: file)
      guard index < 2 else { continue }
      let child = Process()
      let input = Pipe()
      let output = Pipe()
      child.executableURL = URL(fileURLWithPath: "/bin/sh")
      child.arguments = [
        "-c", "exec 3>> \"$1\"; printf 'ready\\n'; read -r line", "fixture", file.path,
      ]
      child.standardInput = input
      child.standardOutput = output
      child.standardError = FileHandle.nullDevice
      try child.run()
      children.append((child, input))
      _ = try output.fileHandleForReading.read(upToCount: 6)
      vm.recordPendingLaunchProcess(
        forKey: pending[index].placeholderSession.id, processID: child.processIdentifier)
    }
    // Both watches see both owned files and a foreign candidate on their first scan.
    let watches = pending.map { item in
      Task { await vm.watchForNewCodexSession(pending: item, worktree: worktree) }
    }
    for _ in 0..<100 where await ownership.observedProcesses.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await ownership.observedProcesses.count == 2)
    #expect(vm.resolvedPendingSessionHistory.isEmpty)
    // Release real FD evidence only after both initial scans. Resolution must use polling.
    await ownership.allowEvidence()
    for _ in 0..<200 where vm.resolvedPendingSessionHistory.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    for index in 0..<2 {
      #expect(vm.resolvedPendingSessionHistory[pending[index].id] == sessions[index].id)
      #expect(
        vm.displayName(for: sessions[index])
          == (pending[index].origin?.displayName ?? "Provider \(index)"))
      if withOrigin {
        #expect(
          try store.launchOrigins(provider: .codex).first {
            $0.pendingID == pending[index].id.uuidString
          }?.sessionID == sessions[index].id)
      }
    }
    #expect(vm.pendingHubSessions.isEmpty)
    for item in pending { vm.cancelPendingSession(item) }
    for watch in watches { await watch.value }
  }

  @Test(
    "Pending investigation exports the effective origin or manual title", arguments: [false, true])
  func pendingInvestigationTitle(manualName: Bool) async throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let vm = makeViewModel(store: store, provider: .claude)
    let other = makeViewModel(store: nil, provider: .codex)
    _ = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(), prompt: "", repositoryPath: "/tmp/snapshot-title", viewModel: vm))
    let pending = try #require(vm.pendingHubSessions.first)
    defer { vm.cancelPendingSession(pending) }
    if manualName {
      vm.setCustomName("Manual title", for: pending.placeholderSession)
      for _ in 0..<100 where vm.sessionCustomNames[pending.placeholderSession.id] == nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(vm.displayName(for: pending.placeholderSession) == "Manual title")
    }
    let snapshot = SessionInvestigationSnapshotBuilder.make(
      claudeViewModel: vm, codexViewModel: other)
    let encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    let rows = try #require(encoded?["pendingSessions"] as? [[String: Any]])
    #expect(
      rows.first?["displayName"] as? String == vm.displayName(for: pending.placeholderSession))
  }

  @Test("Restored failed or unidentified launches are pending but are not active or working")
  func investigationRecoveryState() throws {
    let store = try SessionMetadataStore(path: ":memory:")
    let worktree = WorktreeBranch(name: "main", path: "/tmp/recovery-snapshot")
    var failed = PendingHubSession(
      worktree: worktree, origin: origin(), expectedSessionID: "failed")
    failed.isFailed = true
    let unidentified = PendingHubSession(worktree: worktree, origin: origin())
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: failed, provider: .claude))
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: unidentified, provider: .codex))
    let claude = makeViewModel(store: store, provider: .claude)
    let codex = makeViewModel(store: store, provider: .codex)
    defer {
      claude.cancelPendingSession(failed)
      codex.cancelPendingSession(unidentified)
    }
    let snapshot = SessionInvestigationSnapshotBuilder.make(
      claudeViewModel: claude, codexViewModel: codex)
    #expect(snapshot.overview.pendingSessionCount == 2)
    #expect(snapshot.overview.activeSessionCount == 0)
    #expect(snapshot.overview.workingSessionCount == 0)
    let encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
    let rows = try #require(encoded?["pendingSessions"] as? [[String: Any]])
    #expect(
      rows.first { $0["id"] as? String == failed.id.uuidString }?["isFailed"] as? Bool == true)
    #expect(
      rows.first { $0["id"] as? String == unidentified.id.uuidString }?["needsIdentification"]
        as? Bool == true)

    let starting = PendingHubSession(worktree: worktree)
    claude.pendingHubSessions.append(starting)
    let withStarting = SessionInvestigationSnapshotBuilder.make(
      claudeViewModel: claude, codexViewModel: codex)
    #expect(withStarting.overview.pendingSessionCount == 3)
    #expect(withStarting.overview.activeSessionCount == 1)
    #expect(withStarting.overview.workingSessionCount == 1)
    claude.cancelPendingSession(starting)
  }

  @Test("Failed cancellation keeps a stopped row and allows deletion to be retried")
  func cancellationPersistenceFailure() throws {
    let queue = try DatabaseQueue()
    let store = try SessionMetadataStore(databaseQueue: queue)
    let vm = makeViewModel(store: store, provider: .claude)
    _ = try #require(
      WorkspaceLaunchActions.startTicketSession(
        origin: origin(), prompt: "", repositoryPath: "/tmp/cancel-origin", viewModel: vm))
    let pending = try #require(vm.pendingHubSessions.first)
    try queue.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER reject_delete BEFORE DELETE ON session_launch_origins BEGIN SELECT RAISE(FAIL, 'fixture failure'); END"
      )
    }
    vm.cancelPendingSession(pending)
    #expect(vm.pendingHubSessions.contains { $0.id == pending.id })
    #expect(!vm.shouldWatchPendingSession(pending.id))
    #expect(vm.pendingLaunchRecoveryMessage(for: pending.placeholderSession.id) != nil)
    #expect(try store.launchOrigins(provider: .claude).count == 1)
    #expect(try store.launchOrigins(provider: .claude).first?.launch().failed == true)
    vm.retryPendingSession(pending)
    #expect(vm.pendingHubSessions.map(\.id) == [pending.id])
    try queue.write { db in try db.execute(sql: "DROP TRIGGER reject_delete") }
    vm.cancelPendingSession(pending)
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(try store.launchOrigins(provider: .claude).isEmpty)
  }

  @Test(
    "A failed cancellation cannot launch an agent when its terminal is remounted",
    arguments: [SessionProviderKind.claude, .codex], [EmbeddedTerminalBackend.regular, .ghostty])
  func cancelledTerminalRemount(provider: SessionProviderKind, backend: EmbeddedTerminalBackend)
    throws
  {
    let queue = try DatabaseQueue()
    let store = try SessionMetadataStore(databaseQueue: queue)
    let factory = OriginTerminalFactory()
    let vm = makeViewModel(
      store: store, provider: provider, terminalFactory: factory, terminalBackend: backend)
    let worktree = WorktreeBranch(name: "main", path: "/tmp/cancelled-terminal-fixture")
    _ = try #require(vm.startNewSessionInHub(worktree, origin: origin()))
    let pending = try #require(vm.pendingHubSessions.first)
    let key = pending.placeholderSession.id
    func requestTerminal() {
      _ = vm.getOrCreateTerminal(
        forKey: key, sessionId: nil, projectPath: pending.projectPath,
        cliConfiguration: CLICommandConfiguration(
          command: "/fixture/inert-agent", mode: provider == .claude ? .claude : .codex),
        initialPrompt: nil)
    }
    requestTerminal()
    #expect(factory.surfaces.count == 1)
    #expect(factory.surfaces.first?.configureCount == 1)
    try queue.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER reject_delete BEFORE DELETE ON session_launch_origins BEGIN SELECT RAISE(FAIL, 'fixture failure'); END"
      )
    }
    vm.cancelPendingSession(pending)
    #expect(factory.surfaces.first?.terminateCount == 1)
    #expect(vm.activeTerminals[key] == nil)
    #expect(vm.pendingHubSessions.first?.removalError != nil)
    #expect(vm.pendingLaunchRecoveryMessage(for: key) != nil)
    // makeNSView and updateNSView both request this same shared terminal path.
    requestTerminal()
    requestTerminal()
    #expect(factory.surfaces.count == 2)
    #expect(factory.surfaces.dropFirst().allSatisfy { $0.configureCount == 0 })
    #expect(factory.surfaces.allSatisfy { $0.restartCount == 0 })
    #expect(factory.surfaces.reduce(0) { $0 + $1.configureCount } == 1)
    #expect(factory.requestedBackends == [backend, backend])
    try queue.write { db in try db.execute(sql: "DROP TRIGGER reject_delete") }
    vm.cancelPendingSession(pending)
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(vm.activeTerminals[key] == nil)
    #expect(try store.launchOrigins(provider: provider).isEmpty)
  }

  @Test(
    "Claude retries saving its known file after the database recovers, or stops on cancellation",
    arguments: [true, false])
  func claudeResolutionPersistenceRetry(recover: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "claude-origin-retry-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabaseQueue()
    let store = try SessionMetadataStore(databaseQueue: queue)
    let monitor = OriginMonitor()
    let vm = makeViewModel(
      store: store, provider: .claude, monitor: monitor, claudePath: directory.path)
    let worktree = WorktreeBranch(name: "main", path: "/tmp/claude-retry")
    let pending = PendingHubSession(
      worktree: worktree, origin: origin(), expectedSessionID: "known-claude")
    try store.saveLaunchOrigin(SessionLaunchOriginRecord(pending: pending, provider: .claude))
    vm.pendingHubSessions = [pending]
    let session = CLISession(id: "known-claude", projectPath: worktree.path)
    var repository = SelectedRepository(path: worktree.path)
    repository.worktrees = [WorktreeBranch(name: "main", path: worktree.path, sessions: [session])]
    await monitor.setSelectedRepositories([repository])
    let project = directory.appendingPathComponent(
      "projects/" + worktree.path.claudeProjectPathEncoded)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: project.appendingPathComponent(session.id + ".jsonl"))
    try await queue.write { db in
      try db.execute(
        sql:
          "CREATE TRIGGER reject_resolution BEFORE UPDATE OF sessionID ON session_launch_origins BEGIN SELECT RAISE(FAIL, 'fixture failure'); END"
      )
    }
    let watch = Task { await vm.watchForNewClaudeSession(pending: pending, worktree: worktree) }
    for _ in 0..<100 where vm.launchError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(vm.launchError != nil)
    #expect(try store.launchOrigins(provider: .claude).first?.sessionID == nil)
    if !recover {
      vm.cancelPendingSession(pending)
      await watch.value
      #expect(vm.pendingHubSessions.isEmpty)
      #expect(try store.launchOrigins(provider: .claude).isEmpty)
      return
    }
    try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_resolution") }
    for _ in 0..<200 where vm.resolvedPendingSessionHistory[pending.id] == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(vm.resolvedPendingSessionHistory[pending.id] == session.id)
    #expect(try store.launchOrigins(provider: .claude).first?.sessionID == session.id)
    #expect(vm.displayName(for: session) == origin().displayName)
    vm.cancelPendingSession(pending)
    vm.stopMonitoring(sessionId: session.id)
    await watch.value
  }

  @Test("v21 preserves rows from the complete v20 schema")
  func migrationPreservation() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "migration-\(UUID()).sqlite"
    ).path
    let queue = try DatabaseQueue(path: path)
    let template = try SessionMetadataStore(path: ":memory:")
    try template.migrator.migrate(
      queue, upTo: SessionMetadataStore.MigrationID.createSessionReadCursors)
    try await queue.write { db in
      try SessionMetadata(sessionId: "unrelated-333", customName: "Keep this", isPinned: true)
        .insert(db)
      try db.execute(
        sql: "INSERT INTO session_read_cursors VALUES (?, ?, ?)",
        arguments: ["Claude", "unrelated-333", 123.0])
      try db.execute(
        sql: "INSERT INTO session_results VALUES (?, ?)",
        arguments: ["result-333", Data("preserve".utf8)])
    }
    let migrated = try SessionMetadataStore(path: path)
    #expect(
      try await migrated.getMetadata(for: ["unrelated-333"])["unrelated-333"]?.customName
        == "Keep this")
    try await queue.read { db throws -> Void in
      #expect(
        try Bool.fetchOne(
          db, sql: "SELECT isPinned FROM session_metadata WHERE sessionId = 'unrelated-333'")
          == true)
      #expect(
        try Double.fetchOne(db, sql: "SELECT lastReadActivityAt FROM session_read_cursors") == 123)
      #expect(
        try Data.fetchOne(db, sql: "SELECT payload FROM session_results") == Data("preserve".utf8))
    }
  }
}

/// Records the actual configure/restart boundary without creating a native terminal or process.
@MainActor
private final class OriginTerminalSurface: EmbeddedTerminalSurface {
  var view: NSView {
    preconditionFailure("The inert terminal fixture must not mount a native view")
  }
  var currentProcessPID: Int32? { nil }
  var onUserInteraction: (() -> Void)?
  var onRequestShowEditor: (() -> Void)?
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)?
  private(set) var configureCount = 0
  private(set) var restartCount = 0
  private(set) var terminateCount = 0

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {}
  func configure(
    sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?, initialInputText: String?, launchContext: String?, isDark: Bool,
    dangerouslySkipPermissions: Bool, permissionModePlan: Bool, worktreeName: String?,
    metadataStore: SessionMetadataStore?
  ) { configureCount += 1 }
  func configureShell(projectPath: String, isDark: Bool, shellPath: String?) { configureCount += 1 }
  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration) {
    restartCount += 1
  }
  func terminateProcess() { terminateCount += 1 }
  func resetPromptDeliveryFlag() {}
  func sendPromptIfNeeded(_ prompt: String) {}
  func submitPromptImmediately(_ prompt: String) -> Bool { false }
  func typeText(_ text: String) {}
  func typeInitialTextIfNeeded(_ text: String) {}
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?) {}
  func focus() {}
}

@MainActor
private final class OriginTerminalFactory: EmbeddedTerminalSurfaceFactory {
  private(set) var surfaces: [OriginTerminalSurface] = []
  private(set) var requestedBackends: [EmbeddedTerminalBackend] = []

  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    requestedBackends.append(backend)
    let surface = OriginTerminalSurface()
    surfaces.append(surface)
    return surface
  }
}

private actor OriginOwnershipGate: PendingSessionFileOwning {
  private let service = PendingSessionFileOwnership()
  private var isAllowed = false
  var observedProcesses: Set<Int32> = []

  func allowEvidence() { isAllowed = true }

  func ownedFiles(in candidates: Set<String>, process: PendingSessionProcessIdentity) async -> Set<
    String
  > {
    observedProcesses.insert(process.processID)
    guard isAllowed else { return [] }
    return await service.ownedFiles(in: candidates, process: process)
  }
}

private actor OriginOwnershipSpy: PendingSessionFileOwning {
  var calls: [Set<String>] = []
  func ownedFiles(in candidates: Set<String>, process: PendingSessionProcessIdentity) -> Set<String>
  {
    calls.append(candidates)
    return []
  }
}

@Suite("Pending session file ownership")
struct PendingSessionFileOwnershipTests {
  @Test("Read-only handles are rejected; the captured process writer is accepted")
  func writableFileEvidence() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ownership-\(UUID()).jsonl")
    try Data("{}\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let identity = try #require(
      PendingSessionProcessIdentity.capture(processID: ProcessInfo.processInfo.processIdentifier))
    let service = PendingSessionFileOwnership()
    let reader = try FileHandle(forReadingFrom: file)
    #expect(await service.ownedFiles(in: [file.path], process: identity).isEmpty)
    try reader.close()
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    #expect(await service.ownedFiles(in: [file.path], process: identity) == [file.path])
    let reusedPID = PendingSessionProcessIdentity(
      processID: identity.processID,
      startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
    #expect(await service.ownedFiles(in: [file.path], process: reusedPID).isEmpty)
  }

  @Test("A descendant writer cannot establish the parent launch identity")
  func descendantWriterRejected() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "child-writer-\(UUID()).jsonl")
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = [
      "-c", "exec 3> \"$1\"; printf 'ready\\n'; read -r line", "fixture", file.path,
    ]
    child.standardInput = input
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    try child.run()
    defer {
      try? input.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
      child.waitUntilExit()
      try? FileManager.default.removeItem(at: file)
    }
    _ = try output.fileHandleForReading.read(upToCount: 6)
    let parent = try #require(
      PendingSessionProcessIdentity.capture(processID: ProcessInfo.processInfo.processIdentifier))
    let childIdentity = try #require(
      PendingSessionProcessIdentity.capture(processID: child.processIdentifier))
    #expect(
      PendingSessionProcessIdentity.capture(
        processID: child.processIdentifier, parentProcessID: parent.processID) == childIdentity)
    #expect(
      PendingSessionProcessIdentity.capture(
        processID: child.processIdentifier, parentProcessID: child.processIdentifier) == nil)
    let service = PendingSessionFileOwnership()
    #expect(await service.ownedFiles(in: [file.path], process: parent).isEmpty)
    #expect(await service.ownedFiles(in: [file.path], process: childIdentity) == [file.path])
  }
}
