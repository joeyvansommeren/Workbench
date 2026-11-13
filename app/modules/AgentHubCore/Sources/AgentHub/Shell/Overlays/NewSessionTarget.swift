//
//  NewSessionTarget.swift
//  AgentHub
//
//  Pure mapping from the new-session sheet's worktree menu (New / existing /
//  None) to what `MultiSessionLaunchViewModel` needs: the repository to launch
//  from, the work mode, and the worktree the session starts in.
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
  /// Where the session starts; nil when launch creates a new worktree.
  let worktree: WorktreeBranch?

  init(choice: NewSessionWorktreeChoice, repository: SelectedRepository) {
    switch choice {
    case .newWorktree:
      launchRepository = repository
      workMode = .worktree
      worktree = nil
    case .existing(let branch):
      launchRepository = SelectedRepository(
        path: branch.path,
        name: URL(fileURLWithPath: branch.path).lastPathComponent,
        worktrees: [branch],
        isExpanded: true
      )
      workMode = .local
      worktree = branch
    case .none:
      launchRepository = repository
      workMode = .local
      worktree = Self.mainCheckout(of: repository)
    }
  }

  /// The linked worktrees a session can start in, by name. The main checkout
  /// is the "No worktree" row, so it is not listed.
  static func existingWorktrees(in repository: SelectedRepository) -> [WorktreeBranch] {
    repository.worktrees
      .filter(\.isWorktree)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  static func mainCheckout(of repository: SelectedRepository) -> WorktreeBranch {
    let rootPath = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
    return repository.worktrees.first {
      !$0.isWorktree && WorktreeModuleResolver.normalizedDirectoryPath($0.path) == rootPath
    } ?? WorktreeBranch(name: repository.name, path: repository.path, isWorktree: false)
  }

  /// Where the sheet starts when a caller (the branch row "+") hands it a
  /// worktree: its repository, and that worktree (or "None" for the main
  /// checkout). Nil when the worktree belongs to no tracked repository.
  static func preselection(
    for worktree: WorktreeBranch,
    in repositories: [SelectedRepository]
  ) -> (repository: SelectedRepository, choice: NewSessionWorktreeChoice)? {
    guard let match = WorktreeModuleResolver.bestMatch(for: worktree.path, repositories: repositories)
    else { return nil }
    let choice: NewSessionWorktreeChoice = match.worktree.isWorktree ? .existing(match.worktree) : .none
    return (match.repository, choice)
  }
}
