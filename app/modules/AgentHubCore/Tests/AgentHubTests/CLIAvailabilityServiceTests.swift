import Combine
import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Minimal mocks (local to this test file)

private final class StubMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
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
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

/// Controllable mock that returns pre-set availability per provider.
private final class MockCLIAvailability: CLIAvailabilityChecking, @unchecked Sendable {
  var results: [SessionProviderKind: Bool] = [.claude: true, .codex: true]

  func isAvailable(for provider: SessionProviderKind) -> Bool {
    results[provider] ?? false
  }

  @discardableResult
  func checkAvailability(for provider: SessionProviderKind) -> Bool {
    results[provider] ?? false
  }

  @discardableResult
  func checkAll() -> [SessionProviderKind: Bool] {
    results
  }
}

// MARK: - CLIAvailabilityService (concrete)

@Suite("CLI availability service")
struct CLIAvailabilityServiceTests {

  @Test("Returns true when the executable is found")
  func availableWhenExecutableFound() {
    let service = CLIAvailabilityService(
      findExecutable: { _, _, _ in "/usr/local/bin/claude" }
    )
    #expect(service.isAvailable(for: .claude) == true)
    #expect(service.isAvailable(for: .codex) == true)
  }

  @Test("Returns false when the executable is missing")
  func unavailableWhenExecutableMissing() {
    let service = CLIAvailabilityService(
      findExecutable: { _, _, _ in nil }
    )
    #expect(service.isAvailable(for: .claude) == false)
    #expect(service.isAvailable(for: .codex) == false)
  }

  @Test("Caches the result after first check")
  func cachesResult() {
    nonisolated(unsafe) var callCount = 0
    let service = CLIAvailabilityService(
      findExecutable: { _, _, _ in
        callCount += 1
        return "/usr/local/bin/claude"
      }
    )
    _ = service.isAvailable(for: .claude)
    _ = service.isAvailable(for: .claude)
    // Only one lookup per provider on the first call.
    #expect(callCount == 1)
  }

  @Test("checkAvailability forces a fresh lookup")
  func checkAvailabilityRefreshesCache() {
    nonisolated(unsafe) var found = false
    let service = CLIAvailabilityService(
      findExecutable: { _, _, _ in
        found ? "/usr/local/bin/claude" : nil
      }
    )
    #expect(service.isAvailable(for: .claude) == false)
    found = true
    // Cached — still false.
    #expect(service.isAvailable(for: .claude) == false)
    // Force refresh.
    #expect(service.checkAvailability(for: .claude) == true)
    // Cache now updated.
    #expect(service.isAvailable(for: .claude) == true)
  }

  @Test("checkAll refreshes both providers")
  func checkAllRefreshesBoth() {
    let service = CLIAvailabilityService(
      findExecutable: { _, provider, _ in
        provider == .claude ? "/usr/local/bin/claude" : nil
      }
    )
    let results = service.checkAll()
    #expect(results[.claude] == true)
    #expect(results[.codex] == false)
  }

  @Test("Per-provider lookup uses the correct provider kind")
  func perProviderLookup() {
    nonisolated(unsafe) var requestedProviders: [SessionProviderKind] = []
    let service = CLIAvailabilityService(
      findExecutable: { _, provider, _ in
        requestedProviders.append(provider)
        return nil
      }
    )
    _ = service.checkAvailability(for: .claude)
    _ = service.checkAvailability(for: .codex)
    #expect(requestedProviders == [.claude, .codex])
  }
}

// MARK: - Launch blocking

@Suite("Launch blocked when CLI missing", .serialized)
@MainActor
struct CLIAvailabilityLaunchBlockingTests {

  private func makeViewModel(
    provider: SessionProviderKind = .claude,
    availability: MockCLIAvailability
  ) -> CLISessionsViewModel {
    CLISessionsViewModel(
      monitorService: StubMonitorService(),
      fileWatcher: StubFileWatcher(),
      searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider,
      approvalNotificationService: NoOpApprovalNotificationService(),
      cliAvailabilityService: availability
    )
  }

  @Test("startNewSessionInHub is blocked when CLI is missing")
  func startBlockedWhenCLIMissing() {
    let availability = MockCLIAvailability()
    availability.results[.claude] = false
    let vm = makeViewModel(provider: .claude, availability: availability)

    let worktree = WorktreeBranch(name: "main", path: "/tmp/test-repo", isWorktree: false)
    vm.startNewSessionInHub(worktree)

    // No pending session should have been created.
    #expect(vm.pendingHubSessions.isEmpty)
    #expect(vm.isCLIAvailable == false)
  }

  @Test("startNewSessionInHub proceeds when CLI is available")
  func startAllowedWhenCLIAvailable() {
    let availability = MockCLIAvailability()
    availability.results[.claude] = true
    let vm = makeViewModel(provider: .claude, availability: availability)

    let worktree = WorktreeBranch(name: "main", path: "/tmp/test-repo", isWorktree: false)
    vm.startNewSessionInHub(worktree)

    // A pending session should have been created.
    #expect(vm.pendingHubSessions.count == 1)
    #expect(vm.isCLIAvailable == true)
  }

  @Test("refreshCLIAvailability updates isCLIAvailable")
  func refreshUpdatesProperty() {
    let availability = MockCLIAvailability()
    availability.results[.claude] = true
    let vm = makeViewModel(provider: .claude, availability: availability)

    #expect(vm.isCLIAvailable == true)

    availability.results[.claude] = false
    vm.refreshCLIAvailability()

    #expect(vm.isCLIAvailable == false)
  }

  @Test("markPendingSessionFailed sets the isFailed flag")
  func markFailed() {
    let availability = MockCLIAvailability()
    let vm = makeViewModel(provider: .claude, availability: availability)

    let worktree = WorktreeBranch(name: "main", path: "/tmp/test-repo", isWorktree: false)
    vm.startNewSessionInHub(worktree)
    guard let pending = vm.pendingHubSessions.first else {
      Issue.record("Expected a pending session")
      return
    }

    #expect(pending.isFailed == false)
    vm.markPendingSessionFailed(pending.id)
    #expect(vm.pendingHubSessions.first?.isFailed == true)
  }

  @Test("removePendingSession clears the row")
  func removeClears() {
    let availability = MockCLIAvailability()
    let vm = makeViewModel(provider: .claude, availability: availability)

    let worktree = WorktreeBranch(name: "main", path: "/tmp/test-repo", isWorktree: false)
    vm.startNewSessionInHub(worktree)
    guard let pending = vm.pendingHubSessions.first else {
      Issue.record("Expected a pending session")
      return
    }

    vm.removePendingSession(pending)
    #expect(vm.pendingHubSessions.isEmpty)
  }
}
