//
//  BranchWorkflowDecoration.swift
//  AgentHub
//
//  Folds the workflow dashboard into the sidebar tree. Each detected or manual
//  workflow branch (`DetectedBranchWorkflow` from
//  `AgentWorkflowDashboardViewModel`) becomes a decoration on the matching
//  branch row: its pull request with CI state, the implementer and reviewer
//  roles of its sessions, and what its context menu can offer. Pure, so the
//  rules are unit tested without the 1,800-line view model.
//

import AgentHubGitHub
import Foundation

struct BranchWorkflowDecoration: Equatable {
  struct PullRequestBadge: Equatable {
    let number: Int
    let url: String
    let state: GitHubPullRequestState
    let ciStatus: CIStatus?
  }

  /// `DetectedBranchWorkflow.id`, the key for review and compare actions.
  let branchWorkflowID: String
  /// The ticket workflow the branch belongs to. Set only when the dashboard
  /// would let the user archive it (a manual workflow or a confident ticket).
  let archivableWorkflowID: String?
  let repositoryPath: String
  let branchName: String?
  /// Display name for a branch row that has no git branch (manual workflow).
  let title: String
  let ticketKey: String?
  let isManual: Bool
  let pullRequest: PullRequestBadge?
  /// Role per sidebar item id (`SidebarSessionItemID.monitored`).
  let roles: [String: DetectedAgentRole]
  /// The provider "Start review with …" launches: the other model than the
  /// implementer. `nil` when a review cannot start (no implementer, already
  /// reviewed, or the workflow is done).
  let reviewProvider: SessionProviderKind?
  /// True when the branch has both an implementer and a reviewer to compare.
  let canCompare: Bool

  var hasSessions: Bool { !roles.isEmpty }

  /// Role labels add noise when every session implements, so rows only show
  /// them once a reviewer is part of the workflow.
  var showsRoleLabels: Bool { roles.values.contains(.reviewer) }

  init(
    branchWorkflowID: String,
    archivableWorkflowID: String?,
    repositoryPath: String,
    branchName: String?,
    title: String,
    ticketKey: String?,
    isManual: Bool,
    pullRequest: PullRequestBadge?,
    roles: [String: DetectedAgentRole],
    reviewProvider: SessionProviderKind?,
    canCompare: Bool
  ) {
    self.branchWorkflowID = branchWorkflowID
    self.archivableWorkflowID = archivableWorkflowID
    self.repositoryPath = repositoryPath
    self.branchName = branchName
    self.title = title
    self.ticketKey = ticketKey
    self.isManual = isManual
    self.pullRequest = pullRequest
    self.roles = roles
    self.reviewProvider = reviewProvider
    self.canCompare = canCompare
  }

  init(branch: DetectedBranchWorkflow, archivableWorkflowID: String?) {
    var roles: [String: DetectedAgentRole] = [:]
    for assignment in branch.implementerSessions + branch.reviewerSessions {
      let itemID = SidebarSessionItemID.monitored(
        provider: assignment.provider, sessionId: assignment.session.id)
      roles[itemID] = assignment.role
    }

    let reviewProvider: SessionProviderKind?
    if !branch.isCompleted, branch.reviewerSessions.isEmpty,
      let implementer = branch.primaryImplementer
    {
      // Mirrors `AgentWorkflowDashboardViewModel.beginReview`: cross-model.
      reviewProvider = implementer.provider == .codex ? .claude : .codex
    } else {
      reviewProvider = nil
    }

    let canCompare: Bool
    if let implementer = branch.primaryImplementer, let reviewer = branch.primaryReviewer {
      canCompare = implementer.id != reviewer.id
    } else {
      canCompare = false
    }

    self.init(
      branchWorkflowID: branch.id,
      archivableWorkflowID: archivableWorkflowID,
      repositoryPath: WorktreeModuleResolver.normalizedDirectoryPath(branch.repositoryPath),
      branchName: branch.branchName,
      title: branch.branchName ?? branch.ticketKey ?? "Workflow",
      ticketKey: branch.manualWorkflowID == nil ? branch.ticketKey : nil,
      isManual: branch.manualWorkflowID != nil,
      pullRequest: branch.pullRequest.map {
        PullRequestBadge(number: $0.number, url: $0.url, state: $0.state, ciStatus: $0.ciStatus)
      },
      roles: roles,
      reviewProvider: reviewProvider,
      canCompare: canCompare
    )
  }
}

// MARK: - Index

/// All decorations for one projection pass, looked up by repository (or
/// worktree) path and branch name.
struct BranchWorkflowDecorationIndex: Equatable {
  private(set) var decorations: [BranchWorkflowDecoration] = []
  private var byKey: [String: Int] = [:]

  static let empty = BranchWorkflowDecorationIndex()

  /// Builds the index from the dashboard's branches. Archived workflows are
  /// hidden, so they get no decoration and no empty row.
  ///
  /// - Parameter branches: `AgentWorkflowDashboardViewModel.detectedBranches`.
  init(branches: [DetectedBranchWorkflow]) {
    let archivableIDs = Self.archivableWorkflowIDs(for: branches)
    for branch in branches where !branch.isArchived {
      let decoration = BranchWorkflowDecoration(
        branch: branch,
        archivableWorkflowID: archivableIDs[branch.id]
      )
      let key = Self.key(path: decoration.repositoryPath, branchName: branch.branchName)
      // Keep the first one; the classifier already merges a branch's sessions.
      guard byKey[key] == nil else { continue }
      byKey[key] = decorations.count
      decorations.append(decoration)
    }
  }

  private init() {}

  /// The decoration for a tree branch row.
  func decoration(for branch: BranchNode, repositoryPath: String) -> BranchWorkflowDecoration? {
    if let workflowID = SessionTreeWorkflowMerge.workflowID(fromEmptyRowID: branch.id) {
      return decorations.first { $0.branchWorkflowID == workflowID }
    }
    return decoration(
      repositoryPath: repositoryPath, worktreePath: branch.worktreePath, branchName: branch.name)
  }

  /// Workflow repository paths are the repo root or, when the repo has no
  /// `.git` there, the worktree root; try both.
  func decoration(
    repositoryPath: String,
    worktreePath: String?,
    branchName: String
  ) -> BranchWorkflowDecoration? {
    let name = branchName == SessionTreeProjection.noBranchName ? nil : branchName
    for path in [repositoryPath, worktreePath].compactMap({ $0 }) {
      let key = Self.key(path: WorktreeModuleResolver.normalizedDirectoryPath(path), branchName: name)
      if let index = byKey[key] { return decorations[index] }
    }
    return nil
  }

  /// Manual workflows that have no sessions yet. They still get a branch row
  /// so the user can start one from it.
  var manualWorkflowsWithoutSessions: [BranchWorkflowDecoration] {
    decorations.filter { $0.isManual && !$0.hasSessions }
  }

  private static func key(path: String, branchName: String?) -> String {
    "\(path)|\(branchName ?? "")"
  }

  /// Workflow ids the dashboard would archive, keyed by branch id. Uses the
  /// classifier's own grouping so the id matches `archiveWorkflow(_:)`;
  /// unconfident groups (such as "unassigned") are left out on purpose.
  private static func archivableWorkflowIDs(
    for branches: [DetectedBranchWorkflow]
  ) -> [String: String] {
    var result: [String: String] = [:]
    for workflow in AgentSessionWorkflowClassifier.workflows(from: branches, scope: .active) {
      for branch in workflow.branches {
        result[branch.id] = workflow.id
      }
    }
    return result
  }
}

// MARK: - Merge into the tree

enum SessionTreeWorkflowMerge {
  private static let emptyRowMarker = "|workflow|"

  /// Id of the empty branch row for a manual workflow.
  static func emptyRowID(repositoryPath: String, branchWorkflowID: String) -> String {
    repositoryPath + emptyRowMarker + branchWorkflowID
  }

  static func workflowID(fromEmptyRowID id: String) -> String? {
    guard let range = id.range(of: emptyRowMarker) else { return nil }
    return String(id[range.upperBound...])
  }

  /// Adds what the session projection cannot know about:
  /// - tracked repositories without sessions (so a project opened from the
  ///   footer shows up straight away), and
  /// - empty branch rows for manual workflows with no sessions yet.
  ///
  /// Keeps the tracked repository order.
  static func merge(
    repos: [RepoNode],
    repositories: [SelectedRepository],
    decorations: BranchWorkflowDecorationIndex
  ) -> [RepoNode] {
    let reposByPath = Dictionary(repos.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [RepoNode] = []
    var handled: Set<String> = []

    for repository in WorktreeModuleResolver.mergedRepositories(repositories) {
      let path = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
      guard handled.insert(path).inserted else { continue }
      let base = reposByPath[path] ?? emptyRepo(path: path)
      result.append(adding(manualRows(for: repository, decorations: decorations), to: base))
    }
    // Repos the projection produced but that are no longer tracked keep their place at the end.
    for repo in repos where !handled.contains(repo.path) {
      result.append(repo)
    }
    return result
  }

  private static func emptyRepo(path: String) -> RepoNode {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return RepoNode(
      id: path, path: path, name: name, tile: String(name.prefix(1)).uppercased(),
      attentionCount: 0, branches: [])
  }

  private static func manualRows(
    for repository: SelectedRepository,
    decorations: BranchWorkflowDecorationIndex
  ) -> [BranchNode] {
    let repoPath = WorktreeModuleResolver.normalizedDirectoryPath(repository.path)
    let worktreePaths = Set(
      repository.worktrees.map { WorktreeModuleResolver.normalizedDirectoryPath($0.path) })
    return decorations.manualWorkflowsWithoutSessions.compactMap { decoration in
      guard decoration.repositoryPath == repoPath || worktreePaths.contains(decoration.repositoryPath)
      else { return nil }
      let worktree = repository.worktrees.first { $0.name == decoration.branchName }
      return BranchNode(
        id: emptyRowID(repositoryPath: repoPath, branchWorkflowID: decoration.branchWorkflowID),
        name: decoration.branchName ?? decoration.title,
        worktreePath: worktree?.path,
        isWorktree: worktree?.isWorktree == true,
        sessions: [],
        hasMore: false,
        visibleCount: 0
      )
    }
  }

  private static func adding(_ branches: [BranchNode], to repo: RepoNode) -> RepoNode {
    let existingNames = Set(repo.branches.map(\.name))
    let extra = branches.filter { !existingNames.contains($0.name) }
    guard !extra.isEmpty else { return repo }
    return RepoNode(
      id: repo.id, path: repo.path, name: repo.name, tile: repo.tile,
      attentionCount: repo.attentionCount, branches: repo.branches + extra)
  }
}
