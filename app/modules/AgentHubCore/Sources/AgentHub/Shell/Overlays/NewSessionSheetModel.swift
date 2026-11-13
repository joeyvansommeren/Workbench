//
//  NewSessionSheetModel.swift
//  AgentHub
//
//  State of the new shell's New session sheet. A thin layer over
//  `MultiSessionLaunchViewModel`, which still does the launch: the sheet only
//  picks one agent, a project, a worktree and a prompt. Parallel and smart
//  launches stay in the legacy launcher ("More options…").
//

import Foundation

/// Asks the window to show the New session sheet. Set on the window's
/// `SessionsActionCoordinator` (see `ShellSessionActions.startNewSession`).
struct NewSessionSheetRequest: Identifiable {
  let id = UUID()
  let model: NewSessionSheetModel
}

@MainActor
@Observable
final class NewSessionSheetModel {
  let launchViewModel: MultiSessionLaunchViewModel
  /// Tracked repositories, for the project popup.
  let repositories: [SelectedRepository]

  var agent: SessionProviderKind
  var worktreeSearch = ""

  /// The picked row, and the project it was picked in. An existing worktree
  /// only counts while its project is still selected, so a project change
  /// (popup or "Other…") falls back to New worktree, and a cancelled open
  /// panel keeps the pick.
  private var storedChoice: NewSessionWorktreeChoice
  private var storedChoiceProjectPath: String?

  init(
    launchViewModel: MultiSessionLaunchViewModel,
    repositories: [SelectedRepository],
    preferredRepositoryPath: String? = nil,
    preselectedWorktree: WorktreeBranch? = nil
  ) {
    self.launchViewModel = launchViewModel
    self.repositories = repositories
    agent =
      launchViewModel.isClaudeAvailable || !launchViewModel.isCodexAvailable ? .claude : .codex

    let selection = NewSessionTarget.initialSelection(
      preselectedWorktree: preselectedWorktree,
      preferredPath: preferredRepositoryPath,
      repositories: repositories
    )
    storedChoice = selection?.choice ?? .newWorktree
    storedChoiceProjectPath = selection?.repository.path

    if let project = selection?.repository {
      launchViewModel.selectedRepository = project
      launchViewModel.beginBranchLoad()
    }
  }

  /// The repository the session runs in (the root, not a worktree).
  var project: SelectedRepository? { launchViewModel.selectedRepository }

  var worktreeChoice: NewSessionWorktreeChoice {
    if case .existing = storedChoice, storedChoiceProjectPath != project?.path { return .newWorktree }
    return storedChoice
  }

  var prompt: String {
    get { launchViewModel.sharedPrompt }
    set { launchViewModel.sharedPrompt = newValue }
  }

  var existingWorktrees: [WorktreeBranch] {
    guard let project else { return [] }
    let all = NewSessionTarget.existingWorktrees(in: project)
    let query = worktreeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return all }
    return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  func isAgentAvailable(_ provider: SessionProviderKind) -> Bool {
    provider == .claude ? launchViewModel.isClaudeAvailable : launchViewModel.isCodexAvailable
  }

  /// Start waits for the branch load only when the launch needs its result:
  /// the base branch for a new worktree, and the main checkout's branch for
  /// "No worktree" when the repository does not list it.
  var canStart: Bool {
    guard let project, isAgentAvailable(agent), !launchViewModel.isLaunching else { return false }
    switch worktreeChoice {
    case .newWorktree:
      return !launchViewModel.isLoadingBranches
    case .none:
      return !launchViewModel.isLoadingCurrentBranch || NewSessionTarget.mainCheckout(of: project) != nil
    case .existing:
      return true
    }
  }

  func selectProject(_ repository: SelectedRepository) {
    guard repository.path != project?.path else { return }
    launchViewModel.selectedRepository = repository
    launchViewModel.beginBranchLoad()
    // A worktree belongs to the old project.
    if case .existing = storedChoice { storedChoice = .newWorktree }
  }

  /// "Other…": the open panel sets the repository and loads its branches.
  /// Cancelling it changes nothing.
  func chooseOtherProject() {
    launchViewModel.selectRepository()
  }

  func selectWorktree(_ choice: NewSessionWorktreeChoice) {
    storedChoice = choice
    storedChoiceProjectPath = project?.path
    worktreeSearch = ""
  }

  /// Copies the sheet's choices onto the launch view model. Also used before
  /// handing the view model to the legacy launcher, so its form starts filled.
  @discardableResult
  func applyToLaunchViewModel() -> NewSessionTarget? {
    guard let project else { return nil }
    let choice = worktreeChoice
    let target = NewSessionTarget(choice: choice, repository: project)
    let vm = launchViewModel
    vm.launchMode = .manual
    vm.claudeMode = agent == .claude ? .enabled : .disabled
    vm.isCodexSelected = agent == .codex
    vm.claudeUseWorktree = false
    vm.workMode = target.workMode
    vm.worktreeNamingMode = .automatic
    // A local launch names the session after `currentBranchName`; seed it so a
    // start before the branch load lands is not named "main".
    switch choice {
    case .existing(let worktree):
      vm.selectedRepository = target.launchRepository
      // Reload without defaults: this drops the project's in-flight load so it
      // cannot overwrite the worktree's branch.
      vm.currentBranchName = worktree.name
      vm.beginBranchLoad(applyDefaultBaseBranch: false)
    case .none:
      // The project's in-flight load later sets the same branch.
      if vm.currentBranchName.isEmpty, let main = NewSessionTarget.mainCheckout(of: project) {
        vm.currentBranchName = main.name
      }
    case .newWorktree:
      break
    }
    return target
  }

  func start() {
    guard canStart else { return }
    applyToLaunchViewModel()
    launchViewModel.beginLaunch()
  }
}
