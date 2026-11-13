//
//  SidebarTreeRows.swift
//  AgentHub
//
//  Flattens the repo > branch > session tree into the rows the sidebar's
//  `LazyVStack` draws, in order. One flat list keeps the stack lazy (no nested
//  stacks per repo) and gives arrow-key navigation a simple order. Pure.
//

import Foundation

struct RepoHeaderRowModel: Equatable {
  let path: String
  let name: String
  let isCollapsed: Bool
  /// Shown only while collapsed, so attention inside stays visible.
  let attentionCount: Int
  let isFirst: Bool
}

struct BranchRowModel: Equatable {
  let id: String
  let repositoryPath: String
  let repositoryName: String
  let name: String
  let worktreePath: String?
  let isWorktree: Bool
  let isFirstInRepo: Bool
  let sessionCount: Int
  let decoration: BranchWorkflowDecoration?

  /// Where a new session on this branch starts: its worktree, else the repo.
  var launchPath: String { worktreePath ?? repositoryPath }
}

struct SessionRowModel: Equatable {
  let node: SessionNode
  let title: String
  let roleLabel: String?
  let isFirstInBranch: Bool
  let isLastInBranch: Bool

  var id: String { node.id }
}

struct LoadMoreRowModel: Equatable {
  let branchID: String
  let repositoryName: String
}

enum SidebarTreeRow: Identifiable, Equatable {
  case repo(RepoHeaderRowModel)
  case branch(BranchRowModel)
  case session(SessionRowModel)
  case loadMore(LoadMoreRowModel)

  var id: String {
    switch self {
    case .repo(let model): return "repo|" + model.path
    case .branch(let model): return "branch|" + model.id
    case .session(let model): return model.id
    case .loadMore(let model): return "more|" + model.branchID
    }
  }
}

enum SidebarTreeRows {
  /// - Parameters:
  ///   - repos: The projected (and workflow-merged) tree.
  ///   - collapsedRepoPaths: Repositories whose body is hidden.
  ///   - decorations: Workflow decorations for branch rows.
  ///   - title: Display title for a session row.
  static func rows(
    repos: [RepoNode],
    collapsedRepoPaths: Set<String>,
    decorations: BranchWorkflowDecorationIndex,
    title: (SessionNode) -> String
  ) -> [SidebarTreeRow] {
    var rows: [SidebarTreeRow] = []
    for (repoIndex, repo) in repos.enumerated() {
      let isCollapsed = collapsedRepoPaths.contains(repo.path)
      rows.append(
        .repo(
          RepoHeaderRowModel(
            path: repo.path,
            name: repo.name,
            isCollapsed: isCollapsed,
            attentionCount: repo.attentionCount,
            isFirst: repoIndex == 0
          )))
      guard !isCollapsed else { continue }

      for (branchIndex, branch) in repo.branches.enumerated() {
        let decoration = decorations.decoration(for: branch, repositoryPath: repo.path)
        rows.append(
          .branch(
            BranchRowModel(
              id: branch.id,
              repositoryPath: repo.path,
              repositoryName: repo.name,
              name: branch.name,
              worktreePath: branch.worktreePath,
              isWorktree: branch.isWorktree,
              isFirstInRepo: branchIndex == 0,
              sessionCount: branch.sessions.count,
              decoration: decoration
            )))
        for (sessionIndex, node) in branch.sessions.enumerated() {
          rows.append(
            .session(
              SessionRowModel(
                node: node,
                title: title(node),
                roleLabel: roleLabel(for: node, decoration: decoration),
                isFirstInBranch: sessionIndex == 0,
                isLastInBranch: sessionIndex == branch.sessions.count - 1
              )))
        }
        if branch.hasMore {
          rows.append(.loadMore(LoadMoreRowModel(branchID: branch.id, repositoryName: repo.name)))
        }
      }
    }
    return rows
  }

  static func roleLabel(
    for node: SessionNode,
    decoration: BranchWorkflowDecoration?
  ) -> String? {
    guard let decoration, decoration.showsRoleLabels, let role = decoration.roles[node.id] else {
      return nil
    }
    switch role {
    case .implementer: return "Implementer"
    case .reviewer: return "Reviewer"
    }
  }

  /// The session row before or after `currentID`, for arrow keys. Starts at
  /// the first or last session when nothing is selected; stops at the ends.
  static func adjacentSessionID(
    in rows: [SidebarTreeRow],
    from currentID: String?,
    forward: Bool
  ) -> String? {
    let sessionIDs = rows.compactMap { row -> String? in
      if case .session(let model) = row { return model.id }
      return nil
    }
    guard !sessionIDs.isEmpty else { return nil }
    guard let currentID, let index = sessionIDs.firstIndex(of: currentID) else {
      return forward ? sessionIDs.first : sessionIDs.last
    }
    let next = forward ? index + 1 : index - 1
    return sessionIDs.indices.contains(next) ? sessionIDs[next] : nil
  }

  /// The repository that holds the session row `sessionID`.
  static func repositoryPath(containing sessionID: String, in rows: [SidebarTreeRow]) -> String? {
    var currentRepo: String?
    for row in rows {
      switch row {
      case .repo(let model): currentRepo = model.path
      case .session(let model) where model.id == sessionID: return currentRepo
      default: continue
      }
    }
    return nil
  }
}
