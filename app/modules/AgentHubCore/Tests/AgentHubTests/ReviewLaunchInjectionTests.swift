import AgentHubGitHub
import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class LaunchMonitor: SessionMonitorServiceProtocol, @unchecked Sendable {
  let subject: CurrentValueSubject<[SelectedRepository], Never>
  init(_ repositories: [SelectedRepository]) { subject = .init(repositories) }
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { subject.value }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    subject.send(repositories)
  }
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}
private actor LaunchWatcher: SessionFileWatcherProtocol {
  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    Empty().eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}
private actor LaunchResolverSpy: GitHubRepositoryIdentityResolverProtocol {
  private(set) var calls: [(String, String)] = []
  func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity? { nil }
  func resolveIdentities(at projectPath: String, expectedHost: String) async -> Set<
    GitHubRepositoryIdentity
  > {
    calls.append((projectPath, expectedHost))
    return [GitHubRepositoryIdentity(owner: "wrong", repository: "shared", host: expectedHost)]
  }
}
private struct LaunchReviewService: GitHubProjectReviewServiceProtocol {
  let request: GitHubProjectPullRequest
  let account = GitHubReviewAccount(host: "github.com", nodeID: "U1", login: "acme")
  func reviewSourceContext() async throws -> GitHubReviewSourceContext {
    let owner = GitHubReviewOwner(
      account: account, nodeID: account.nodeID, login: "acme", isPersonal: true)
    return GitHubReviewSourceContext(account: account, owners: [owner])
  }
  func listProjects() async throws -> [GitHubReviewProject] { [] }
  func listPullRequests(project: GitHubReviewProject, view: GitHubProjectView, limit: Int)
    async throws -> [GitHubProjectPullRequest]
  { [] }
  func listPullRequests(query: GitHubReviewQuery, limit: Int) async throws -> GitHubReviewQueue {
    GitHubReviewQueue(pullRequests: [request])
  }
}
@MainActor private final class FailIfTerminalCreated: EmbeddedTerminalSurfaceFactory {
  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    fatalError("A rejected review must not create a terminal")
  }
}

@MainActor
@Suite("Review launch resolver injection", .serialized)
struct ReviewLaunchInjectionTests {
  @Test("Actual review launch uses the injected resolver and rejects an unrelated checkout")
  func injectedResolver() async throws {
    let path = "/private/tmp/tes322-inert-checkout"
    let store = try SessionMetadataStore(path: ":memory:")
    let terminalFactory = FailIfTerminalCreated()
    func sessions(_ provider: SessionProviderKind, repositories: [SelectedRepository])
      -> CLISessionsViewModel
    {
      CLISessionsViewModel(
        monitorService: LaunchMonitor(repositories), fileWatcher: LaunchWatcher(),
        searchService: nil,
        cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
        providerKind: provider, metadataStore: store,
        approvalNotificationService: NoOpApprovalNotificationService(),
        cliAvailabilityService: CLIAvailabilityService(findExecutable: { _, _, _ in nil }),
        codexDataPath: "/private/tmp/tes322-inert-codex",
        claudeDataPath: "/private/tmp/tes322-inert-claude",
        terminalSurfaceFactory: terminalFactory, terminalBackend: .regular)
    }
    let claude = sessions(.claude, repositories: [SelectedRepository(path: path)])
    let codex = sessions(.codex, repositories: [])
    let resolver = LaunchResolverSpy()
    let defaultsName = "tes322.launch-injection.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let request = GitHubProjectPullRequest(
      id: "1", number: 1, title: "Test", url: "https://github.com/acme/shared/pull/1",
      repositoryName: "shared", repositoryNameWithOwner: "acme/shared", authorLogin: "acme",
      updatedAt: nil, isDraft: false, state: "OPEN", projectStatus: nil)
    let hub = AgentHubProvider(
      gitHubRepositoryIdentityResolver: resolver,
      gitHubProjectReviewService: LaunchReviewService(request: request),
      claudeSessionsViewModel: claude, codexSessionsViewModel: codex, userDefaults: defaults,
      terminalSurfaceFactory: terminalFactory, metadataStore: store)
    await hub.gitHubReviewsViewModel.load()
    for _ in 0..<1000 where claude.selectedRepositories.isEmpty { await Task.yield() }
    #expect(claude.selectedRepositories.map(\.path) == [path])
    await WorkspaceLaunchActions(agentHub: hub, showSessions: {}).startReview(
      request, provider: .claude,
      template: GitHubPromptTemplate(
        id: "fixture", name: "Fixture", prompt: "test", builtInKind: nil))
    let calls = await resolver.calls
    #expect(calls.count == 1)
    #expect(calls.first?.0 == path)
    #expect(calls.first?.1 == "github.com")
    #expect(hub.gitHubReviewsViewModel.errorMessage?.contains("unique local checkout") == true)
    #expect(claude.pendingHubSessions.isEmpty)
    #expect(codex.pendingHubSessions.isEmpty)
  }
}
