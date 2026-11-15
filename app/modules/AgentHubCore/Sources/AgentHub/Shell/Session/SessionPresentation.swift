//
//  SessionPresentation.swift
//  AgentHub
//
//  What the session header shows for one session: title, repository, branch
//  and status. Built from the session item and the tracked repositories, so
//  the header never does I/O.
//

import SwiftUI

struct SessionPresentation: Equatable, Identifiable {
  let id: String
  let title: String
  let providerKind: SessionProviderKind
  let repositoryName: String
  let repositoryPath: String
  let branchName: String?
  let status: SessionStatus?
  let isPending: Bool

  @MainActor
  static func make(
    item: ProjectableSessionItem,
    title: String,
    repositories: [SelectedRepository]
  ) -> SessionPresentation {
    let match = WorktreeModuleResolver.bestMatch(
      for: item.session.projectPath,
      repositories: repositories
    )
    return SessionPresentation(
      id: item.id,
      title: title,
      providerKind: item.providerKind,
      repositoryName: match?.repository.name ?? item.session.projectName,
      repositoryPath: match?.repository.path ?? item.session.projectPath,
      branchName: item.session.branchName ?? (match?.worktree.isWorktree == true ? match?.worktree.name : nil),
      status: item.status,
      isPending: item.isPending
    )
  }
}
