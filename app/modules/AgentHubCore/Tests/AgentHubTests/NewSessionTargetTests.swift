import Combine
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("New session target")
struct NewSessionTargetTests {
  private let main = WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false)
  private let feature = WorktreeBranch(name: "feat/tabs", path: "/tmp/Repo-feat-tabs", isWorktree: true)
  private let fix = WorktreeBranch(name: "fix/acli", path: "/tmp/Repo-fix-acli", isWorktree: true)

  private var repository: SelectedRepository {
    SelectedRepository(path: "/tmp/Repo", name: "Repo", worktrees: [main, fix, feature])
  }

  // MARK: Choice → target

  @Test("New worktree launches from the repository in worktree mode")
  func newWorktree() {
    let target = NewSessionTarget(choice: .newWorktree, repository: repository)
    #expect(target.workMode == .worktree)
    #expect(target.launchRepository.path == "/tmp/Repo")
    #expect(target.worktree == nil)
  }

  @Test("An existing worktree launches locally inside that worktree")
  func existingWorktree() {
    let target = NewSessionTarget(choice: .existing(feature), repository: repository)
    #expect(target.workMode == .local)
    #expect(target.worktree == feature)
    #expect(target.launchRepository.path == feature.path)
    #expect(target.launchRepository.name == "Repo-feat-tabs")
    #expect(target.launchRepository.worktrees == [feature])
  }

  @Test("No worktree launches locally in the main checkout")
  func noWorktree() {
    let target = NewSessionTarget(choice: .none, repository: repository)
    #expect(target.workMode == .local)
    #expect(target.launchRepository.path == "/tmp/Repo")
    #expect(target.worktree == main)
  }

  @Test("No worktree falls back to the repository root when no main branch is listed")
  func noWorktreeWithoutListedMain() {
    let bare = SelectedRepository(path: "/tmp/Bare", name: "Bare", worktrees: [])
    let target = NewSessionTarget(choice: .none, repository: bare)
    #expect(target.worktree == WorktreeBranch(name: "Bare", path: "/tmp/Bare", isWorktree: false))
  }

  @Test("Existing worktrees list only linked worktrees, by name")
  func existingWorktreeList() {
    #expect(NewSessionTarget.existingWorktrees(in: repository).map(\.name) == ["feat/tabs", "fix/acli"])
  }

  @Test("A branch-row preselection opens its repository with that worktree chosen")
  func preselection() throws {
    let other = SelectedRepository(path: "/tmp/Other", name: "Other")
    let linked = try #require(NewSessionTarget.preselection(for: fix, in: [other, repository]))
    #expect(linked.repository.path == "/tmp/Repo")
    #expect(linked.choice == .existing(fix))

    let root = try #require(NewSessionTarget.preselection(for: main, in: [other, repository]))
    #expect(root.choice == .none)

    let unknown = WorktreeBranch(name: "x", path: "/elsewhere", isWorktree: true)
    #expect(NewSessionTarget.preselection(for: unknown, in: [repository]) == nil)
  }

  // MARK: Sheet model → launch view model

  @Test("The sheet opens on the preselected worktree and applies it to the launcher")
  func modelAppliesExistingWorktree() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [repository],
      preselectedWorktree: feature
    )
    #expect(model.project?.path == "/tmp/Repo")
    #expect(model.worktreeChoice == .existing(feature))

    model.agent = .codex
    let target = model.applyToLaunchViewModel()
    let launcher = model.launchViewModel
    #expect(target?.worktree == feature)
    #expect(launcher.workMode == .local)
    #expect(launcher.selectedRepository?.path == feature.path)
    #expect(launcher.currentBranchName == "feat/tabs")
    #expect(launcher.isCodexSelected)
    #expect(!launcher.isClaudeSelected)
    #expect(launcher.launchMode == .manual)
  }

  @Test("Default is a new worktree in the preferred project; Claude is the agent")
  func modelDefaultsToNewWorktree() {
    let other = SelectedRepository(path: "/tmp/Other", name: "Other")
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [other, repository],
      preferredRepositoryPath: fix.path
    )
    #expect(model.project?.path == "/tmp/Repo")
    #expect(model.worktreeChoice == .newWorktree)

    model.applyToLaunchViewModel()
    #expect(model.launchViewModel.workMode == .worktree)
    #expect(model.launchViewModel.worktreeNamingMode == .automatic)
    #expect(model.launchViewModel.isClaudeSelected)
    #expect(!model.launchViewModel.isCodexSelected)
  }

  @Test("Changing project drops a worktree from the old project")
  func projectChangeResetsWorktree() {
    let other = SelectedRepository(path: "/tmp/Other", name: "Other")
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [repository, other],
      preselectedWorktree: fix
    )
    model.selectProject(other)
    #expect(model.project?.path == "/tmp/Other")
    #expect(model.worktreeChoice == .newWorktree)

    model.selectWorktree(.none)
    model.selectProject(repository)
    #expect(model.worktreeChoice == .none)
  }

  @Test("Worktree search filters by name")
  func worktreeSearch() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(), repositories: [repository])
    model.worktreeSearch = "ACLI"
    #expect(model.existingWorktrees == [fix])
    model.selectWorktree(.existing(fix))
    #expect(model.worktreeSearch.isEmpty)
  }

  @Test("Without a project the sheet cannot start")
  func noProjectCannotStart() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(), repositories: [])
    #expect(model.project == nil)
    #expect(!model.canStart)
    #expect(model.applyToLaunchViewModel() == nil)
  }
}

// MARK: - Fixture

@MainActor
private func makeLaunchViewModel() -> MultiSessionLaunchViewModel {
  func sessions(_ provider: SessionProviderKind) -> CLISessionsViewModel {
    CLISessionsViewModel(
      monitorService: NewSessionMonitorService(),
      fileWatcher: NewSessionFileWatcher(),
      searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
  }
  return MultiSessionLaunchViewModel(claudeViewModel: sessions(.claude), codexViewModel: sessions(.codex))
}

private final class NewSessionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class NewSessionFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
