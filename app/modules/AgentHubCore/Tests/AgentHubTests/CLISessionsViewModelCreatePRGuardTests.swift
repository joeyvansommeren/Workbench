import Combine
import Foundation
import Testing

@testable import AgentHubCore

// Minimal stubs — only the protocol conformance needed to create the view model.

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
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    Empty().eraseToAnyPublisher()
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

@MainActor
@Suite("CLISessionsViewModel create-PR double-click guard")
struct CLISessionsViewModelCreatePRGuardTests {
  @Test("Second create-PR for the same session is rejected while the first is in flight")
  func doubleCreatePRGuard() async {
    let viewModel = makeViewModel()

    #expect(viewModel.beginCreatingPullRequest(for: "session-1") == true)
    #expect(viewModel.creatingPullRequestSessionIDs.contains("session-1"))

    // A second attempt for the same session must be rejected.
    #expect(viewModel.beginCreatingPullRequest(for: "session-1") == false)

    // A different session must still be allowed.
    #expect(viewModel.beginCreatingPullRequest(for: "session-2") == true)

    // Clearing the session allows creating again.
    viewModel.endCreatingPullRequest(for: "session-1")
    #expect(!viewModel.creatingPullRequestSessionIDs.contains("session-1"))
    #expect(viewModel.beginCreatingPullRequest(for: "session-1") == true)
  }
}
