//
//  SidebarTreeRows.swift
//  AgentHub
//
//  Flattens the repo > branch > session tree into the rows the sidebar's
//  `LazyVStack` draws, in order. One flat list keeps the stack lazy (no nested
//  stacks per repo) and gives arrow-key navigation a simple order. Pure.
//

import Foundation
import AgentHubGitDiff

/// Leading positions for the flat sidebar's three visible hierarchy levels.
/// Each level indents by `md` (12 pt) so the repo → branch → session
/// staircase reads clearly without eating too much title width. At 12 pt the
/// leading icon of each child starts past the midpoint of its parent's icon
/// column, which is the smallest step that makes the three levels obvious.
enum SidebarTreeInset {
  /// Per-level indent step. `md` is the smallest token that makes the three
  /// levels visually distinct: `sm` (8 pt) left the icons overlapping by
  /// more than half their width; `lg` (16 pt) wastes width in a 288 pt sidebar.
  static let step = DesignTokens.Spacing.md
  static let repository = DesignTokens.Spacing.smPlus
  static let branch = repository + step
  static let session = branch + step
  /// Centre of the session status column, used by guide lines.
  static let guideX = session + DesignTokens.Size.tile / 2
}

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
  let decoration: BranchWorkflowDecoration?

  /// Where a new session on this branch starts: its worktree, else the repo.
  var launchPath: String { worktreePath ?? repositoryPath }

  /// What the New session sheet preselects for this row.
  var preselectedWorktree: WorktreeBranch {
    WorktreeBranch(name: name, path: launchPath, isWorktree: isWorktree)
  }
}

struct SessionRowModel: Equatable {
  let node: SessionNode
  let title: String
  let roleLabel: String?
  let isFirstInBranch: Bool
  let isLastInBranch: Bool
  var showProvider = false
  var diff: LocalDiffSummary? = nil
  var action: String? = nil
  var isUnread = false

  var id: String { node.id }
}

struct LoadMoreRowModel: Equatable {
  let branchID: String
  let repositoryName: String
}

enum SidebarTreeRow: Identifiable, Equatable {
  static func repoID(_ path: String) -> String { "repo|" + path }

  case repo(RepoHeaderRowModel)
  case branch(BranchRowModel)
  case session(SessionRowModel)
  case loadMore(LoadMoreRowModel)

  var id: String {
    switch self {
    case .repo(let model): return Self.repoID(model.path)
    case .branch(let model): return "branch|" + model.id
    case .session(let model): return model.id
    case .loadMore(let model): return "more|" + model.branchID
    }
  }
}

/// Accessibility relationships derived from the same visible rows as the list.
struct SidebarTreeAccessibilityRow: Equatable {
  let id: String
  let parentID: String?
  let level: Int
}

enum SidebarTreeRows {
  static func accessibilityHierarchy(_ rows: [SidebarTreeRow]) -> [SidebarTreeAccessibilityRow] {
    var repositoryID: String?
    var branchID: String?
    return rows.map { row in
      switch row {
      case .repo:
        repositoryID = row.id
        branchID = nil
        return SidebarTreeAccessibilityRow(id: row.id, parentID: nil, level: 0)
      case .branch:
        branchID = row.id
        return SidebarTreeAccessibilityRow(id: row.id, parentID: repositoryID, level: 1)
      case .session, .loadMore:
        return SidebarTreeAccessibilityRow(id: row.id, parentID: branchID, level: 2)
      }
    }
  }

  /// - Parameters:
  ///   - repos: The projected (and workflow-merged) tree.
  ///   - collapsedRepoPaths: Repositories whose body is hidden.
  ///   - decorations: Workflow decorations for branch rows.
  ///   - title: Display title for a session row.
  static func rows(
    repos: [RepoNode],
    collapsedRepoPaths: Set<String>,
    decorations: BranchWorkflowDecorationIndex,
    title: (SessionNode) -> String,
    providersByBranch: [String: Set<SessionProviderKind>] = [:]
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
                isLastInBranch: sessionIndex == branch.sessions.count - 1 && !branch.hasMore,
                showProvider: (providersByBranch[branch.id] ?? Set(branch.sessions.map(\.providerKind))).count > 1
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
  /// When the current session is hidden in a collapsed repository, it
  /// continues from that repository's header.
  ///
  /// - Parameter repoPathBySessionID: Every session's repository, including
  ///   sessions in collapsed repositories (`SessionTreeSnapshot`).
  static func adjacentSessionID(
    in rows: [SidebarTreeRow],
    from currentID: String?,
    forward: Bool,
    repoPathBySessionID: [String: String]
  ) -> String? {
    let start: Int?
    if let currentID, let index = rows.firstIndex(where: { $0.id == currentID }) {
      start = index
    } else if let currentID, let repoPath = repoPathBySessionID[currentID],
      let header = rows.firstIndex(where: { $0.id == SidebarTreeRow.repoID(repoPath) })
    {
      start = header
    } else {
      start = nil
    }

    let after = (start.map { $0 + 1 } ?? 0)..<rows.count
    let before = 0..<(start ?? rows.count)
    let candidates = forward ? Array(after) : Array(before.reversed())
    for index in candidates {
      if case .session(let model) = rows[index] { return model.id }
    }
    return nil
  }
}

// MARK: - Highlight

/// The session row the user last opened into a workspace pane. Opening a
/// workspace-owned session clears `primarySessionId`, so the tree keeps this
/// to highlight the row and to continue arrow keys from it.
struct SidebarWorkspaceOpen: Equatable {
  let sessionRowID: String
  let workspaceID: String
}

enum SidebarTreeSelection {
  /// The row to highlight: the primary session, else the workspace session
  /// the tree opened, as long as its workspace is still the one shown.
  static func highlightedSessionID(
    primarySessionId: String?,
    selectedWorkspaceID: String?,
    lastWorkspaceOpen: SidebarWorkspaceOpen?
  ) -> String? {
    if let primarySessionId { return primarySessionId }
    guard let selectedWorkspaceID, let lastWorkspaceOpen,
      lastWorkspaceOpen.workspaceID == selectedWorkspaceID
    else {
      return nil
    }
    return lastWorkspaceOpen.sessionRowID
  }
}
