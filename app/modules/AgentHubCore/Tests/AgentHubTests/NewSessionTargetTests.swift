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
  @Test("Only creation of a new pending terminal routes this request")
  func successfulCreationWitness() {
    let vm = makeLaunchViewModel()
    let gate = NewSessionNavigationGate()
    let shell = WorkbenchShellModel()
    shell.select(.reviews)
    let request = UUID()
    gate.begin(request)
    var callbacks = 0
    vm.onSessionCreated = { _, _ in
      callbacks += 1
      if gate.complete(request) { shell.select(.sessions) }
    }
    let old = UUID()
    vm.recordCreatedSession(previous: old, current: nil, provider: .claude)
    vm.recordCreatedSession(previous: old, current: old, provider: .claude)
    #expect(callbacks == 0)
    #expect(shell.destination == .reviews)
    vm.recordCreatedSession(previous: old, current: UUID(), provider: .claude)
    #expect(callbacks == 1)
    #expect(shell.destination == .sessions)
  }

  @Test("Cancel during More options prevents a late successful launch from routing")
  func cancelledPresentationCannotNavigate() {
    let vm = makeLaunchViewModel()
    let gate = NewSessionNavigationGate()
    let shell = WorkbenchShellModel()
    shell.select(.linear)
    let first = UUID()
    gate.begin(first)
    vm.onLaunchPresentationCancelled = { gate.cancel(first) }
    vm.onSessionCreated = { _, _ in
      if gate.complete(first) { shell.select(.sessions) }
    }
    vm.cancelLaunch()
    vm.recordCreatedSession(previous: nil, current: UUID(), provider: .codex)
    #expect(shell.destination == .linear)
    let second = UUID()
    gate.begin(second)
    vm.recordCreatedSession(previous: nil, current: UUID(), provider: .claude)
    #expect(gate.requestID == second)
    #expect(shell.destination == .linear)
  }

  @Test("Missing provider selection preserves all session choices")
  func missingProviderRecoveryPreservesForm() {
    let model = NewSessionSheetModel(launchViewModel: makeLaunchViewModel(
      claudeAvailable: true, codexAvailable: false), repositories: [repository], preselectedWorktree: feature)
    model.prompt = "Check this result"
    model.agent = .codex
    #expect(!model.isAgentAvailable(.codex))
    #expect(!model.canStart)
    #expect(model.worktreeChoice == .existing(feature))
    #expect(model.project?.path == repository.path)
    #expect(model.prompt == "Check this result")
    #expect(SessionProviderKind.codex.installationGuideURL.host == "github.com")
  }

  @Test("Checking an installed agent enables Start without losing session choices", arguments: SessionProviderKind.allCases)
  func installedProviderRecoveryPreservesForm(provider: SessionProviderKind) {
    let availability = NewSessionCLIAvailability(claudeAvailable: false, codexAvailable: false)
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(availability: availability),
      repositories: [other, repository],
      preselectedWorktree: feature
    )
    model.agent = provider
    model.prompt = "Check this result"
    #expect(!model.isAgentAvailable(provider))
    #expect(!model.canStart)

    availability.results[provider] = true
    // The sheet must perform the same fresh lookup as its Check again action.
    #expect(!model.isAgentAvailable(provider))
    model.launchViewModel.refreshCLIAvailability()

    #expect(model.isAgentAvailable(provider))
    #expect(model.canStart)
    #expect(model.agent == provider)
    #expect(model.project?.path == repository.path)
    #expect(model.worktreeChoice == .existing(feature))
    #expect(model.prompt == "Check this result")
  }

  @Test("Checking an agent that is still missing keeps Start blocked and preserves choices", arguments: SessionProviderKind.allCases)
  func missingProviderRecheckPreservesForm(provider: SessionProviderKind) {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(claudeAvailable: false, codexAvailable: false),
      repositories: [other, repository],
      preselectedWorktree: feature
    )
    model.agent = provider
    model.prompt = "Check this result"

    model.launchViewModel.refreshCLIAvailability()

    #expect(!model.isAgentAvailable(provider))
    #expect(!model.canStart)
    #expect(model.agent == provider)
    #expect(model.project?.path == repository.path)
    #expect(model.worktreeChoice == .existing(feature))
    #expect(model.prompt == "Check this result")
  }

  @Test("A missing unselected agent does not block the available agent", arguments: SessionProviderKind.allCases)
  func availableProviderDoesNotNeedRecovery(provider: SessionProviderKind) {
    let model = NewSessionSheetModel(
      launchViewModel: makeLaunchViewModel(
        claudeAvailable: provider == .claude,
        codexAvailable: provider == .codex
      ),
      repositories: [repository],
      preselectedWorktree: feature
    )
    let missingProvider: SessionProviderKind = provider == .claude ? .codex : .claude
    model.agent = provider
    model.launchViewModel.refreshCLIAvailability()

    #expect(model.isAgentAvailable(model.agent))
    #expect(model.canStart)
    #expect(!model.isAgentAvailable(missingProvider))

    model.agent = missingProvider
    #expect(!model.isAgentAvailable(model.agent))
    #expect(!model.canStart)
  }

  @Test("Cancel during suspended registration creates no terminal", arguments: ["compact", "moreOptions"])
  func cancellationDuringRegistration(context: String) async {
    let vm = makeLaunchViewModel()
    vm.waitsForCreatedSession = true
    let gate = NewSessionNavigationGate()
    let shell = WorkbenchShellModel()
    let origin: ShellDestination = context == "compact" ? .reviews : .linear
    shell.select(origin)
    let request = UUID()
    gate.begin(request)
    var creations = 0
    vm.onSessionCreated = { _, _ in
      creations += 1
      if gate.complete(request) { shell.select(.sessions) }
    }
    vm.onLaunchPresentationCancelled = { gate.cancel(request) }
    let registrar = SuspendedLaunchRegistrar()
    let launch = Task { @MainActor in
      do {
        _ = try await SessionLaunchRegistration.register(using: registrar,
          name: "feature", path: "/tmp/feature", parentRepositoryPath: "/tmp/repo")
        try Task.checkCancellation()
        vm.recordCreatedSession(previous: nil, current: UUID(), provider: .codex)
        return false
      } catch is CancellationError { return true }
      catch { return false }
    }
    await registrar.waitUntilSuspended()
    launch.cancel()
    vm.cancelLaunch()
    registrar.resume()
    #expect(await launch.value)
    #expect(creations == 0)
    #expect(vm.createdSessionCount == 0)
    #expect(shell.destination == origin)
    #expect(gate.requestID == nil)
  }

}

// MARK: - Fixture

@MainActor
private func makeLaunchViewModel(
  claudeAvailable: Bool = true,
  codexAvailable: Bool = true,
  availability: NewSessionCLIAvailability? = nil
) -> MultiSessionLaunchViewModel {
  let availability = availability ?? NewSessionCLIAvailability(
    claudeAvailable: claudeAvailable, codexAvailable: codexAvailable
  )
  func sessions(_ provider: SessionProviderKind) -> CLISessionsViewModel {
    let viewModel = CLISessionsViewModel(
      monitorService: NewSessionMonitorService(),
      fileWatcher: NewSessionFileWatcher(),
      searchService: nil,
      cliConfiguration: provider == .claude ? .claudeDefault : .codexDefault,
      providerKind: provider,
      approvalNotificationService: NoOpApprovalNotificationService(),
      cliAvailabilityService: availability
    )
    viewModel.refreshCLIAvailability()
    return viewModel
  }
  return MultiSessionLaunchViewModel(
    claudeViewModel: sessions(.claude),
    codexViewModel: sessions(.codex)
  )
}
/// Read and changed only by this suite's MainActor tests and synchronous refreshes.
private final class NewSessionCLIAvailability: CLIAvailabilityChecking, @unchecked Sendable {
  var results: [SessionProviderKind: Bool]

  init(claudeAvailable: Bool, codexAvailable: Bool) {
    results = [.claude: claudeAvailable, .codex: codexAvailable]
  }

  func isAvailable(for provider: SessionProviderKind) -> Bool {
    results[provider] ?? false
  }

  func checkAvailability(for provider: SessionProviderKind) -> Bool {
    results[provider] ?? false
  }

  func checkAll() -> [SessionProviderKind: Bool] { results }
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


@MainActor
private final class SuspendedLaunchRegistrar: SessionLaunchWorktreeRegistering {
  private var didStart = false
  private var started: CheckedContinuation<Void, Never>?
  private var registration: CheckedContinuation<WorktreeBranch, Never>?

  func registerCreatedWorktree(name: String, path: String, parentRepositoryPath: String) async -> WorktreeBranch {
    didStart = true
    started?.resume()
    started = nil
    return await withCheckedContinuation { registration = $0 }
  }
  func waitUntilSuspended() async {
    if didStart { return }
    await withCheckedContinuation { started = $0 }
  }
  func resume() {
    registration?.resume(returning: WorktreeBranch(name: "feature", path: "/tmp/feature", isWorktree: true))
    registration = nil
  }
}
