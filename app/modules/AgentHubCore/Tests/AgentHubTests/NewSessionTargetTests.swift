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
  private let other = SelectedRepository(path: "/tmp/Other", name: "Other")

  private var repository: SelectedRepository {
    SelectedRepository(path: "/tmp/Repo", name: "Repo", worktrees: [main, fix, feature])
  }

  // MARK: Choice → target

  @Test("New worktree launches from the repository in worktree mode")
  func newWorktree() {
    let target = NewSessionTarget(choice: .newWorktree, repository: repository)
    #expect(target.workMode == .worktree)
    #expect(target.launchRepository.path == "/tmp/Repo")
  }

  @Test("An existing worktree launches locally inside that worktree")
  func existingWorktree() {
    let target = NewSessionTarget(choice: .existing(feature), repository: repository)
    #expect(target.workMode == .local)
    #expect(target.launchRepository.path == feature.path)
    #expect(target.launchRepository.name == "Repo-feat-tabs")
    #expect(target.launchRepository.worktrees == [feature])
  }

  @Test("No worktree launches locally in the main checkout")
  func noWorktree() {
    let target = NewSessionTarget(choice: .none, repository: repository)
    #expect(target.workMode == .local)
    #expect(target.launchRepository.path == "/tmp/Repo")
    #expect(NewSessionTarget.mainCheckout(of: repository) == main)
    #expect(NewSessionTarget.mainCheckout(of: other) == nil)
  }

  @Test("Existing worktrees list only linked worktrees, by name")
  func existingWorktreeList() {
    #expect(NewSessionTarget.existingWorktrees(in: repository).map(\.name) == ["feat/tabs", "fix/acli"])
  }

  // MARK: Where the sheet opens

  @Test("A branch-row preselection opens its repository with that worktree chosen")
  func preselection() throws {
    let linked = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: fix, preferredPath: nil, repositories: [other, repository])
    )
    #expect(linked.repository.path == "/tmp/Repo")
    #expect(linked.choice == .existing(fix))

    let root = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: main, preferredPath: nil, repositories: [other, repository])
    )
    #expect(root.choice == .none)
  }

  @Test("A preferred worktree path starts in that worktree; a root or nested path starts a new one")
  func preferredPath() throws {
    let worktreePath = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: nil, preferredPath: fix.path + "/", repositories: [other, repository])
    )
    #expect(worktreePath.repository.path == "/tmp/Repo")
    #expect(worktreePath.choice == .existing(fix))

    let rootPath = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: nil, preferredPath: "/tmp/Repo", repositories: [other, repository])
    )
    #expect(rootPath.choice == .newWorktree)

    let nested = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: nil, preferredPath: "/tmp/Repo/ios", repositories: [repository])
    )
    #expect(nested.repository.path == "/tmp/Repo")
    #expect(nested.choice == .newWorktree)
  }

  @Test("With nothing to go on the sheet opens the first project on New worktree")
  func fallback() throws {
    let unknown = WorktreeBranch(name: "x", path: "/elsewhere", isWorktree: true)
    let first = try #require(
      NewSessionTarget.initialSelection(preselectedWorktree: unknown, preferredPath: nil, repositories: [other, repository])
    )
    #expect(first.repository.path == "/tmp/Other")
    #expect(first.choice == .newWorktree)
    #expect(NewSessionTarget.initialSelection(preselectedWorktree: nil, preferredPath: nil, repositories: []) == nil)
  }

  @Test("A branch row maps to the worktree the sheet preselects")
  func branchRowPreselection() throws {
    let mainRow = BranchRowModel(
      id: "m", repositoryPath: "/tmp/Repo", repositoryName: "Repo", name: "main",
      worktreePath: nil, isWorktree: false, isFirstInRepo: true, decoration: nil)
    let linkedRow = BranchRowModel(
      id: "f", repositoryPath: "/tmp/Repo", repositoryName: "Repo", name: "fix/acli",
      worktreePath: fix.path, isWorktree: true, isFirstInRepo: false, decoration: nil)

    let mainSelection = try #require(
      NewSessionTarget.initialSelection(
        preselectedWorktree: mainRow.preselectedWorktree, preferredPath: nil, repositories: [repository])
    )
    #expect(mainSelection.choice == .none)
    let linkedSelection = try #require(
      NewSessionTarget.initialSelection(
        preselectedWorktree: linkedRow.preselectedWorktree, preferredPath: nil, repositories: [repository])
    )
    #expect(linkedSelection.choice == .existing(fix))
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
    #expect(target?.workMode == .local)
    #expect(launcher.workMode == .local)
    #expect(launcher.selectedRepository?.path == feature.path)
    #expect(launcher.currentBranchName == "feat/tabs")
    #expect(launcher.isCodexSelected)
    #expect(!launcher.isClaudeSelected)
    #expect(launcher.launchMode == .manual)
  }

  @Test("⌘N on a session in a linked worktree opens on that worktree")
  func modelPreferredWorktreePath() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [other, repository],
      preferredRepositoryPath: fix.path
    )
    #expect(model.project?.path == "/tmp/Repo")
    #expect(model.worktreeChoice == .existing(fix))
  }

  @Test("Default is a new worktree in the preferred project; Claude is the agent")
  func modelDefaultsToNewWorktree() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [other, repository],
      preferredRepositoryPath: "/tmp/Repo"
    )
    #expect(model.project?.path == "/tmp/Repo")
    #expect(model.worktreeChoice == .newWorktree)
    #expect(model.agent == .claude)

    model.applyToLaunchViewModel()
    #expect(model.launchViewModel.workMode == .worktree)
    #expect(model.launchViewModel.worktreeNamingMode == .automatic)
    #expect(model.launchViewModel.isClaudeSelected)
    #expect(!model.launchViewModel.isCodexSelected)
  }

  @Test("Without Claude the sheet defaults to Codex")
  func codexFallback() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(claudeAvailable: false),
      repositories: [repository]
    )
    #expect(model.agent == .codex)
    #expect(!model.isAgentAvailable(.claude))
  }

  @Test("No worktree launches locally and names the session after the main checkout's branch")
  func modelAppliesNone() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(), repositories: [repository])
    model.selectWorktree(.none)
    model.launchViewModel.currentBranchName = ""
    let target = model.applyToLaunchViewModel()
    #expect(target?.workMode == .local)
    #expect(model.launchViewModel.workMode == .local)
    #expect(model.launchViewModel.selectedRepository?.path == "/tmp/Repo")
    #expect(model.launchViewModel.currentBranchName == "main")
  }

  @Test("Start waits for the base branch only for a new worktree")
  func canStartWhileLoading() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(), repositories: [repository])
    let launcher = model.launchViewModel
    launcher.isLoadingBranches = true
    launcher.isLoadingCurrentBranch = true

    #expect(model.worktreeChoice == .newWorktree)
    #expect(!model.canStart)

    model.selectWorktree(.none)
    #expect(model.canStart)

    model.selectWorktree(.existing(fix))
    #expect(model.canStart)

    launcher.isLoadingBranches = false
    model.selectWorktree(.newWorktree)
    #expect(model.canStart)
  }

  @Test("No worktree waits for the branch when the repository does not list its main checkout")
  func noneWaitsWithoutMainCheckout() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(), repositories: [other])
    model.selectWorktree(.none)
    model.launchViewModel.isLoadingCurrentBranch = true
    #expect(!model.canStart)
    model.launchViewModel.isLoadingCurrentBranch = false
    #expect(model.canStart)
  }

  @Test("Start does nothing when the sheet cannot start")
  func startIsNoOpWhenBlocked() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(claudeAvailable: false, codexAvailable: false),
      repositories: [repository]
    )
    #expect(model.agent == .claude)
    #expect(!model.canStart)
    model.start()
    #expect(model.launchViewModel.claudeMode == .disabled)
    #expect(!model.launchViewModel.isLaunching)
  }

  @Test("Changing project drops a worktree from the old project")
  func projectChangeResetsWorktree() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [repository, other],
      preselectedWorktree: fix
    )
    model.selectProject(other)
    #expect(model.project?.path == "/tmp/Other")
    #expect(model.worktreeChoice == .newWorktree)

    model.selectProject(repository)
    #expect(model.worktreeChoice == .newWorktree)

    model.selectWorktree(.none)
    model.selectProject(other)
    #expect(model.worktreeChoice == .none)
  }

  @Test("A project set by the open panel drops the worktree; an unchanged project keeps it")
  func otherProjectKeepsChoiceUntilChanged() {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(),
      repositories: [repository],
      preselectedWorktree: fix
    )
    // Cancelled panel: nothing changes.
    #expect(model.worktreeChoice == .existing(fix))
    // Picked a folder: the panel sets the launcher's repository directly.
    model.launchViewModel.selectedRepository = other
    #expect(model.worktreeChoice == .newWorktree)
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
private func makeLaunchViewModel(
  claudeAvailable: Bool = true,
  codexAvailable: Bool = true
) -> MultiSessionLaunchViewModel {
  func sessions(_ provider: SessionProviderKind, available: Bool) -> CLISessionsViewModel {
    let viewModel = CLISessionsViewModel(
      monitorService: NewSessionMonitorService(),
      fileWatcher: NewSessionFileWatcher(),
      searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
    viewModel.isCLIAvailable = available
    return viewModel
  }
  return MultiSessionLaunchViewModel(
    claudeViewModel: sessions(.claude, available: claudeAvailable),
    codexViewModel: sessions(.codex, available: codexAvailable)
  )
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
