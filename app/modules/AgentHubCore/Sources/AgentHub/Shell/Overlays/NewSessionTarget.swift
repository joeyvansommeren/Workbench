//
//  NewSessionTarget.swift
//  AgentHub
//
//  Pure mapping from the new-session sheet's worktree menu (New / existing /
//  None) to what `MultiSessionLaunchViewModel` needs: the repository to launch
//  from and the work mode. Also where the sheet opens.
//

import Foundation

/// The three kinds of rows in the sheet's worktree menu.
enum NewSessionWorktreeChoice: Equatable {
  /// Create a fresh worktree at launch (AI-named, from the default base branch).
  case newWorktree
  /// Start inside a worktree that already exists.
  case existing(WorktreeBranch)
  /// Start in the repository's main checkout.
  case none
}

struct NewSessionTarget: Equatable {
  /// What the launch view model's `selectedRepository` becomes. For an
  /// existing worktree this points at the worktree, the same shape
  /// `MultiSessionLaunchViewModel.preselectRepository(path:)` produces.
  let launchRepository: SelectedRepository
  let workMode: WorkMode

  init(choice: NewSessionWorktreeChoice, repository: SelectedRepository) {
    switch choice {
    case .newWorktree:
      launchRepository = repository
      workMode = .worktree
    case .existing(let branch):
      launchRepository = SelectedRepository(
        path: branch.path,
        name: URL(fileURLWithPath: branch.path).lastPathComponent,
        worktrees: [branch],
        isExpanded: true
      )
      workMode = .local
    case .none:
      launchRepository = repository
      workMode = .local
    }
  }

  /// The linked worktrees a session can start in, by name. The main checkout
  /// is the "No worktree" row, so it is not listed.
  static func existingWorktrees(in repository: SelectedRepository) -> [WorktreeBranch] {
    repository.worktrees
      .filter(\.isWorktree)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The repository's main checkout when the repository lists it; its name is
  /// the checked-out branch.
  static func mainCheckout(of repository: SelectedRepository) -> WorktreeBranch? {
    let rootPath = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
    return repository.worktrees.first {
      !$0.isWorktree && WorktreeModuleResolver.normalizedDirectoryPath($0.path) == rootPath
    }
  }

  /// Where the sheet opens.
  /// - A preselected worktree (branch row "+") opens its repository with that
  ///   worktree chosen, or "None" for the main checkout.
  /// - A preferred path (⌘N on a focused session, a landing page) that is a
  ///   linked worktree starts in it, as the legacy launcher did; any other
  ///   path in a repository opens that repository on "New worktree".
  static func initialSelection(
    preselectedWorktree: WorktreeBranch?,
    preferredPath: String?,
    repositories: [SelectedRepository]
  ) -> (repository: SelectedRepository, choice: NewSessionWorktreeChoice)? {
    if let preselectedWorktree,
      let match = WorktreeModuleResolver.bestMatch(for: preselectedWorktree.path, repositories: repositories)
    {
      return (match.repository, match.worktree.isWorktree ? .existing(match.worktree) : .none)
    }
    if let preferredPath,
      let match = WorktreeModuleResolver.bestMatch(for: preferredPath, repositories: repositories)
    {
      let isThatWorktree =
        match.worktree.isWorktree
        && WorktreeModuleResolver.normalizedDirectoryPath(match.worktree.path)
          == WorktreeModuleResolver.normalizedDirectoryPath(preferredPath)
      return (match.repository, isThatWorktree ? .existing(match.worktree) : .newWorktree)
    }
    return repositories.first.map { ($0, .newWorktree) }
  }
}
