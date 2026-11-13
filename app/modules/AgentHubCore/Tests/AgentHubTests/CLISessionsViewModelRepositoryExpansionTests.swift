import Combine
import Foundation
import Testing

@testable import AgentHubCore

/// `setRepositoryExpanded` backs the new sidebar's repo collapse; the value
/// must land in `SessionWorkspaceState.expansionState` (SQLite).
@Suite("CLISessionsViewModel repository expansion")
struct CLISessionsViewModelRepositoryExpansionTests {
  @Test("A trailing-slash path collapses the repository and persists it")
  @MainActor
  func collapsePersists() async throws {
    let path = "/tmp/expansion-\(UUID().uuidString)"
    let store = try await makeExpansionStore(repositoryPath: path)
    let viewModel = makeExpansionViewModel(store: store)
    try await waitForRestore(viewModel, path: path)

    viewModel.setRepositoryExpanded(path: path + "/", isExpanded: false)

    #expect(viewModel.selectedRepositories.first { $0.path == path }?.isExpanded == false)
    try await expansionWaitUntil {
      (try? store.readWorkspaceState(for: .claude))?.expansionState["repo:" + path] == false
    }
  }

  @Test("The same value or an unknown path saves nothing")
  @MainActor
  func noChangeDoesNotPersist() async throws {
    let path = "/tmp/expansion-\(UUID().uuidString)"
    let store = try await makeExpansionStore(repositoryPath: path)
    let viewModel = makeExpansionViewModel(store: store)
    try await waitForRestore(viewModel, path: path)
    #expect(viewModel.selectedRepositories.first { $0.path == path }?.isExpanded == true)

    // Let restore's own saves land first, then write a marker row that only
    // a save from the view model would overwrite.
    try await Task.sleep(for: .milliseconds(300))
    let marker = SessionWorkspaceState(
      selectedRepositoryPaths: [path], expansionState: ["marker": true])
    try await store.saveWorkspaceState(marker, for: .claude)

    viewModel.setRepositoryExpanded(path: path, isExpanded: true)
    viewModel.setRepositoryExpanded(path: "/tmp/not-tracked", isExpanded: false)
    try await Task.sleep(for: .milliseconds(300))

    #expect(try store.readWorkspaceState(for: .claude) == marker)
  }
}

// MARK: - Fixture

private func makeExpansionStore(repositoryPath: String) async throws -> SessionMetadataStore {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("RepositoryExpansionTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let store = try SessionMetadataStore(path: dir.appendingPathComponent("db.sqlite").path)
  try await store.saveWorkspaceState(
    SessionWorkspaceState(selectedRepositoryPaths: [repositoryPath]), for: .claude)
  return store
}

@MainActor
private func makeExpansionViewModel(store: SessionMetadataStore) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: ExpansionMonitorService(),
    fileWatcher: ExpansionFileWatcher(),
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude,
    metadataStore: store,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

/// Restore reads the store (enabling saves) and adds the repository.
@MainActor
private func waitForRestore(_ viewModel: CLISessionsViewModel, path: String) async throws {
  try await expansionWaitUntil {
    viewModel.selectedRepositories.contains { $0.path == path } && viewModel.loadingState == .idle
  }
}

@MainActor
private func expansionWaitUntil(
  _ condition: @escaping () -> Bool,
  timeoutAttempts: Int = 250
) async throws {
  for _ in 0..<timeoutAttempts {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private final class ExpansionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  private var repositories: [SelectedRepository] = []

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    guard !repositories.contains(where: { $0.path == path }) else { return nil }
    let repository = SelectedRepository(path: path)
    repositories.append(repository)
    subject.send(repositories)
    return repository
  }

  func removeRepository(_ path: String) async {
    repositories.removeAll { $0.path == path }
    subject.send(repositories)
  }

  func getSelectedRepositories() async -> [SelectedRepository] { repositories }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class ExpansionFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
