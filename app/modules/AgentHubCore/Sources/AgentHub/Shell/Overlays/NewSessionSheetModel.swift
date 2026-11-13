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
  private(set) var worktreeChoice: NewSessionWorktreeChoice
  var worktreeSearch = ""

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

    var project: SelectedRepository?
    var choice = NewSessionWorktreeChoice.newWorktree
    if let preselectedWorktree,
      let preselection = NewSessionTarget.preselection(for: preselectedWorktree, in: repositories)
    {
      project = preselection.repository
      choice = preselection.choice
    } else if let preferredRepositoryPath {
      project =
        WorktreeModuleResolver.bestMatch(for: preferredRepositoryPath, repositories: repositories)?
        .repository
    }
    worktreeChoice = choice

    if let project = project ?? repositories.first {
      launchViewModel.selectedRepository = project
      launchViewModel.beginBranchLoad()
    }
  }

  /// The repository the session runs in (the root, not a worktree).
  var project: SelectedRepository? { launchViewModel.selectedRepository }

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

  /// Start waits for the base branch only when it creates a worktree.
  var canStart: Bool {
    project != nil
      && isAgentAvailable(agent)
      && !launchViewModel.isLaunching
      && !(worktreeChoice == .newWorktree && launchViewModel.isLoadingBranches)
  }

  func selectProject(_ repository: SelectedRepository) {
    guard repository.path != project?.path else { return }
    launchViewModel.selectedRepository = repository
    launchViewModel.beginBranchLoad()
    // A worktree belongs to the old project.
    if case .existing = worktreeChoice { worktreeChoice = .newWorktree }
  }

  /// "Other…": the open panel sets the repository and loads its branches.
  func chooseOtherProject() {
    if case .existing = worktreeChoice { worktreeChoice = .newWorktree }
    launchViewModel.selectRepository()
  }

  func selectWorktree(_ choice: NewSessionWorktreeChoice) {
    worktreeChoice = choice
    worktreeSearch = ""
  }

  /// Copies the sheet's choices onto the launch view model. Also used before
  /// handing the view model to the legacy launcher, so its form starts filled.
  @discardableResult
  func applyToLaunchViewModel() -> NewSessionTarget? {
    guard let project else { return nil }
    let target = NewSessionTarget(choice: worktreeChoice, repository: project)
    let vm = launchViewModel
    vm.launchMode = .manual
    vm.claudeMode = agent == .claude ? .enabled : .disabled
    vm.isCodexSelected = agent == .codex
    vm.claudeUseWorktree = false
    vm.workMode = target.workMode
    vm.worktreeNamingMode = .automatic
    if case .existing(let worktree) = worktreeChoice {
      vm.selectedRepository = target.launchRepository
      // A local launch names the session after `currentBranchName`. Seed it,
      // then reload without defaults: this drops the project's in-flight load
      // so it cannot overwrite the worktree's branch.
      vm.currentBranchName = worktree.name
      vm.beginBranchLoad(applyDefaultBaseBranch: false)
    }
    return target
  }

  func start() {
    guard canStart else { return }
    applyToLaunchViewModel()
    launchViewModel.beginLaunch()
  }
}
