import AppKit
import Combine
import SwiftUI
import Testing
@testable import AgentHubCore

@MainActor
struct SessionResultNativeLayoutTests {
  @Test("The real result view supports the 260 point content pane with long content")
  func narrowResultFittingSmoke() async throws {
    let store = ResultLayoutStore()
    let library = SessionResultLibrary(store: store)
    let sessions = CLISessionsViewModel(
      monitorService: ResultLayoutMonitor(), fileWatcher: ResultLayoutWatcher(), searchService: nil,
      cliConfiguration: .claudeDefault, providerKind: .claude,
      approvalNotificationService: NoOpApprovalNotificationService(),
      cliAvailabilityService: CLIAvailabilityService(findExecutable: { _, _, _ in nil }))
    sessions.workspaceStateReadOverride = { _ in SessionWorkspaceState() }
    let model = SessionResultViewModel(recipeStore: store, sourceService: ResultLayoutSource(),
      health: ResultLayoutHealth(), server: ResultLayoutServer(), opener: ResultLayoutOpener())
    let session = CLISession(id: "narrow-result-test", projectPath: "/layout-fixture")
    var result = SessionResult(provider: .claude, sessionID: session.id, projectPath: session.projectPath)
    result.summary = String(repeating: "Review the exact interaction, including the long saved name. ", count: 8)
    result.affectedTargets = "/workspace/界面/\(String(repeating: "VeryLongComponentName", count: 8)).swift"
    result.kind = .prototype
    result.alternatives = [SessionResultAlternative(name: "Long alternative name — clearer request controls", destination: "http://localhost:3000/settings?mode=review")]
    result.expectedState = "Open settings, select the saved configuration, then open the confirmation dialog."
    try await library.save(result)
    await library.load()
    await model.load(projectPath: session.projectPath)
    for scheme in [ColorScheme.light, .dark] {
      let view = SessionResultView(session: session, provider: .claude, library: library,
        sessionViewModel: sessions, attentionModel: SessionAttentionModel(), model: model,
        onTerminal: {}, onFiles: {}, onChecks: {})
        .environment(\.colorScheme, scheme)
        .frame(width: 260, height: 650)
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      #expect(host.fittingSize.width <= 260)
      #expect(host.fittingSize.height > 0 && host.fittingSize.height.isFinite)
    }
  }
}

// In-memory fixture: any SwiftUI task that outlives the host retains only these inert values.
private actor ResultLayoutStore: SessionResultStoreProtocol, ProjectLaunchRecipeStoreProtocol {
  var records: [SessionResult] = []
  func loadSessionResults() -> [SessionResult] { records }
  func saveSessionResult(_ result: SessionResult) { records = [result] }
  func loadProjectLaunchRecipe(repositoryPath: String) -> ProjectLaunchRecipe? {
    ProjectLaunchRecipe(repositoryPath: repositoryPath)
  }
  func saveProjectLaunchRecipe(_ recipe: ProjectLaunchRecipe) {}
}

private struct ResultLayoutSource: ResultSourceInspecting {
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: projectPath, identity: nil)
  }
}
private struct ResultLayoutHealth: ResultHealthChecking {
  func isReachable(_ url: URL) async -> Bool { false }
}
@MainActor
private struct ResultLayoutServer: ResultServerStarting {
  func start(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    throw ResultLaunchError.unreachable
  }
}
@MainActor
private struct ResultLayoutOpener: ResultDestinationOpening {
  func open(_ url: URL) -> Bool { false }
}
private actor ResultLayoutMonitor: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}
private final class ResultLayoutWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    Empty<SessionFileWatcher.StateUpdate, Never>().eraseToAnyPublisher()
  }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}
