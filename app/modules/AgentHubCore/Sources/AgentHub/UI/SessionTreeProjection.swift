//
//  SessionTreeProjection.swift
//  AgentHub
//
//  Pure (no SwiftUI) projection of session items, repositories and workflows
//  into the repo > branch > session tree used by the sidebar. The legacy view
//  groups by module (flat list within each repo); this projection groups by
//  branch within each repo so the new shell can show the tree.
//

import Foundation

// MARK: - Tree Nodes

/// One session row in the tree.
struct SessionNode: Identifiable, Equatable {
  let id: String
  let session: CLISession
  let providerKind: SessionProviderKind
  let isPending: Bool
  let status: SessionStatus?
  let pendingID: UUID?
  /// Name of the tool waiting for approval (`pendingToolUse.toolName`), if any.
  let pendingToolName: String?

  init(
    id: String,
    session: CLISession,
    providerKind: SessionProviderKind,
    isPending: Bool,
    status: SessionStatus?,
    pendingID: UUID? = nil,
    pendingToolName: String? = nil
  ) {
    self.id = id
    self.session = session
    self.providerKind = providerKind
    self.isPending = isPending
    self.status = status
    self.pendingID = pendingID
    self.pendingToolName = pendingToolName
  }

  /// Whether the row shows the Approve pill: a Claude session with a pending
  /// tool use that is a real approval, not a question for the user. Codex has
  /// no approval hook, and input-needed sessions get their own action (P7).
  var showsApprovePill: Bool {
    guard providerKind == .claude, !isPending, let pendingToolName else { return false }
    return !SessionInteractiveInputTool.matches(pendingToolName)
  }
}

/// One branch row in the tree.
struct BranchNode: Identifiable, Equatable {
  /// Composite id: `"\(repoPath)|\(worktreePath ?? "")|\(name)"` so identical
  /// branch names in different worktrees cannot collide.
  let id: String
  let name: String
  let worktreePath: String?
  let isWorktree: Bool
  let sessions: [SessionNode]
  /// True when there are older sessions not yet loaded.
  let hasMore: Bool
  /// The number of visible sessions that show a loaded page (increments of
  /// `SessionTreeProjection.loadMoreIncrement`).
  let visibleCount: Int

  init(
    id: String,
    name: String,
    worktreePath: String?,
    isWorktree: Bool,
    sessions: [SessionNode],
    hasMore: Bool,
    visibleCount: Int
  ) {
    self.id = id
    self.name = name
    self.worktreePath = worktreePath
    self.isWorktree = isWorktree
    self.sessions = sessions
    self.hasMore = hasMore
    self.visibleCount = visibleCount
  }
}

/// One repository row in the tree.
struct RepoNode: Identifiable, Equatable {
  let id: String
  let path: String
  let name: String
  /// First letter of the name, uppercased.
  let tile: String
  /// Count of sessions across all branches that need attention.
  let attentionCount: Int
  let branches: [BranchNode]

  init(
    id: String,
    path: String,
    name: String,
    tile: String,
    attentionCount: Int,
    branches: [BranchNode]
  ) {
    self.id = id
    self.path = path
    self.name = name
    self.tile = tile
    self.attentionCount = attentionCount
    self.branches = branches
  }
}

// MARK: - Input types

/// A session item fed into the projection. Mirrors the view-private
/// `SelectedSessionItem` without depending on it.
struct ProjectableSessionItem {
  let id: String
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let status: SessionStatus?
  let pendingID: UUID?
  let pendingToolName: String?

  init(
    id: String,
    session: CLISession,
    providerKind: SessionProviderKind,
    timestamp: Date,
    isPending: Bool,
    status: SessionStatus?,
    pendingID: UUID? = nil,
    pendingToolName: String? = nil
  ) {
    self.id = id
    self.session = session
    self.providerKind = providerKind
    self.timestamp = timestamp
    self.isPending = isPending
    self.status = status
    self.pendingID = pendingID
    self.pendingToolName = pendingToolName
  }
}

// MARK: - SessionTreeProjection

/// Pure function namespace. Turns items and repos into `[RepoNode]`.
enum SessionTreeProjection {
  /// Number of history sessions to show per "Load more" page.
  static let loadMoreIncrement = 5

  /// Sentinel branch name for sessions with no branch.
  static let noBranchName = "No branch"

  /// Projects session items into a repo > branch > session tree.
  ///
  /// - Parameters:
  ///   - items: All session items, both pending and monitored.
  ///   - repositories: The tracked repositories, in display order.
  ///   - loadedPages: A dictionary keyed by branch node id, holding the number
  ///     of "Load more" pages the user has opened. Missing keys default to 1.
  /// - Returns: An array of `RepoNode`, one per repository that has sessions.
  static func project(
    items: [ProjectableSessionItem],
    repositories: [SelectedRepository],
    loadedPages: [String: Int] = [:]
  ) -> [RepoNode] {
    // Group items by their module path (worktree root).
    var itemsByModule: [String: [ProjectableSessionItem]] = [:]
    for item in items {
      let modulePath = WorktreeModuleResolver.modulePath(
        for: item.session.projectPath,
        repositories: repositories,
        mode: .parent
      )
      itemsByModule[modulePath, default: []].append(item)
    }

    // Build repo nodes in repository display order.
    let mergedRepositories = WorktreeModuleResolver.mergedRepositories(repositories)
    var repoNodes: [RepoNode] = []
    var handledPaths: Set<String> = []

    for repository in mergedRepositories {
      let repoPath = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
      guard !handledPaths.contains(repoPath) else { continue }
      handledPaths.insert(repoPath)

      // Collect items for all module paths that belong to this repository.
      let modulePaths = WorktreeModuleResolver.modulePaths(
        for: [repository], mode: .parent)
      var repoItems: [ProjectableSessionItem] = []
      for modulePath in modulePaths {
        repoItems.append(contentsOf: itemsByModule[modulePath] ?? [])
      }
      guard !repoItems.isEmpty else { continue }

      // Group by branch within this repo.
      let branches = branchNodes(
        from: repoItems,
        repository: repository,
        repoPath: repoPath,
        loadedPages: loadedPages
      )

      let attentionCount = repoItems.filter {
        SidebarSessionOrdering.requiresAttention($0.status)
      }.count

      let name = URL(fileURLWithPath: repoPath).lastPathComponent
      repoNodes.append(RepoNode(
        id: repoPath,
        path: repoPath,
        name: name,
        tile: String(name.prefix(1)).uppercased(),
        attentionCount: attentionCount,
        branches: branches
      ))
    }

    return repoNodes
  }

  // MARK: - Branch grouping

  private static func branchNodes(
    from items: [ProjectableSessionItem],
    repository: SelectedRepository,
    repoPath: String,
    loadedPages: [String: Int]
  ) -> [BranchNode] {
    // Build a set of known branch -> worktree mappings from the repository.
    var branchWorktrees: [String: WorktreeBranch] = [:]
    for wt in repository.worktrees {
      branchWorktrees[wt.name] = wt
    }

    // Group items by branch key.
    struct BranchKey: Hashable {
      let name: String
      let worktreePath: String?
    }
    var grouped: [BranchKey: [ProjectableSessionItem]] = [:]

    for item in items {
      let branchName = item.session.branchName ?? noBranchName
      // Resolve the worktree root through bestMatch so nested launch paths
      // honour the worktree.path vs launchPath contract.
      let worktreePath: String?
      if let match = WorktreeModuleResolver.bestMatch(
        for: item.session.projectPath,
        repositories: [repository]
      ) {
        worktreePath = match.worktree.path
      } else {
        worktreePath = branchWorktrees[branchName]?.path
      }
      let key = BranchKey(name: branchName, worktreePath: worktreePath)
      grouped[key, default: []].append(item)
    }

    // Sort branches: the repo's own worktrees first (in their tracked order),
    // then any unmatched branches alphabetically.
    var orderedKeys: [BranchKey] = []
    var handledKeys: Set<BranchKey> = []

    for wt in repository.worktrees {
      let key = BranchKey(name: wt.name, worktreePath: wt.path)
      if grouped[key] != nil {
        orderedKeys.append(key)
        handledKeys.insert(key)
      }
    }
    for key in grouped.keys.sorted(by: { $0.name < $1.name }) {
      if !handledKeys.contains(key) {
        orderedKeys.append(key)
      }
    }

    // Build branch nodes.
    return orderedKeys.compactMap { key -> BranchNode? in
      guard let branchItems = grouped[key] else { return nil }
      // Include the worktree path so identical branch names in different
      // worktrees produce distinct ids.
      let branchId = "\(repoPath)|\(key.worktreePath ?? "")|\(key.name)"
      // Derive isWorktree from the resolved worktree, not just name lookup.
      let resolvedWorktree = key.worktreePath.flatMap { path in
        branchWorktrees.values.first { $0.path == path }
      }
      let isWorktree = resolvedWorktree?.isWorktree == true

      // Sort by activity (newest first).
      let sorted = branchItems.sorted { lhs, rhs in
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        return lhs.id < rhs.id
      }

      // Paging: show loadMoreIncrement * pages sessions.
      let pages = max(1, loadedPages[branchId] ?? 1)
      let visibleCount = min(sorted.count, pages * loadMoreIncrement)
      let visible = Array(sorted.prefix(visibleCount))
      let hasMore = visibleCount < sorted.count

      let sessionNodes = visible.map { item in
        SessionNode(
          id: item.id,
          session: item.session,
          providerKind: item.providerKind,
          isPending: item.isPending,
          status: item.status,
          pendingID: item.pendingID,
          pendingToolName: item.pendingToolName
        )
      }

      return BranchNode(
        id: branchId,
        name: key.name,
        worktreePath: key.worktreePath,
        isWorktree: isWorktree,
        sessions: sessionNodes,
        hasMore: hasMore,
        visibleCount: visibleCount
      )
    }
  }
}
