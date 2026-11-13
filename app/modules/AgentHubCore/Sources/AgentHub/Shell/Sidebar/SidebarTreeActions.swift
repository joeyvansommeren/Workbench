//
//  SidebarTreeActions.swift
//  AgentHub
//
//  Everything a sidebar tree row can do, in one place, wired to the window's
//  `SessionNavigationModel` / `SessionsActionCoordinator` and the existing
//  view models. Rows hold a reference and call it; they never reach into
//  view models themselves, so they stay cheap `Equatable` values.
//

import AppKit
import SwiftUI

@MainActor
final class SidebarTreeActions {
  let agentHub: AgentHubProvider
  let shellModel: WorkbenchShellModel
  let navigationModel: SessionNavigationModel
  let coordinator: SessionsActionCoordinator

  /// What the Approve pill does: allow once through the shared responder
  /// (`SidebarApproval.respond`). One closure, so rows stay unaware of it.
  var approve: (SessionNode) -> Void = { _ in }

  /// Called when `open(_:)` focuses a workspace pane, which clears
  /// `primarySessionId`; the tree keeps the row highlighted with it.
  var onWorkspaceOpen: (SidebarWorkspaceOpen) -> Void = { _ in }

  init(
    agentHub: AgentHubProvider,
    shellModel: WorkbenchShellModel,
    navigationModel: SessionNavigationModel,
    coordinator: SessionsActionCoordinator
  ) {
    self.agentHub = agentHub
    self.shellModel = shellModel
    self.navigationModel = navigationModel
    self.coordinator = coordinator
    self.approve = SidebarApproval.respond(
      answer: { node in
        let viewModel =
          node.providerKind == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
        return viewModel.respondToApproval(sessionId: node.session.id, decision: .approveOnce)
      },
      openSession: { [weak self] node in self?.open(node) }
    )
  }

  /// Progress of the last approval click on `node`'s current request.
  func approvalPhase(for node: SessionNode) -> ApprovalResponsePhase? {
    let viewModel = viewModel(for: node.providerKind)
    return viewModel.approvalTracker.phase(
      for: node.session.id,
      request: ApprovalRequestKey(state: viewModel.monitorStates[node.session.id]))
  }

  private var claude: CLISessionsViewModel { agentHub.claudeSessionsViewModel }
  private var codex: CLISessionsViewModel { agentHub.codexSessionsViewModel }
  private var workspaces: AgentWorkspacesViewModel { agentHub.agentWorkspacesViewModel }

  private func viewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    provider == .claude ? claude : codex
  }

  private var sessionActions: ShellSessionActions {
    ShellSessionActions(agentHub: agentHub, coordinator: coordinator, navigationModel: navigationModel)
  }

  private var isDarkAppearance: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }

  // MARK: - Selection

  /// Opens a session from the tree. The single entry point for row clicks and
  /// arrow keys: workspace-owned sessions focus their workspace pane (like the
  /// legacy sidebar), everything else goes through `selectSession`.
  func open(_ node: SessionNode) {
    MainThreadStallMonitor.breadcrumb("tree: select \(node.id.prefix(20))")
    if !node.isPending,
      let workspaceID = workspaces.focusWorkspaceSession(
        provider: node.providerKind,
        sessionId: node.session.id,
        isDark: isDarkAppearance
      )
    {
      navigationModel.workflowComparisonState.showStandaloneContent()
      navigationModel.selectedModuleLandingPath = nil
      navigationModel.primarySessionId = nil
      navigationModel.selectedWorkspaceID = workspaceID
      onWorkspaceOpen(SidebarWorkspaceOpen(sessionRowID: node.id, workspaceID: workspaceID))
    } else {
      navigationModel.selectSession(node.id)
    }
    shellModel.select(.sessions)
  }

  // MARK: - Repository

  /// Collapse state lives in `SelectedRepository.isExpanded`, which the view
  /// models persist in `SessionWorkspaceState.expansionState` (SQLite).
  func setRepository(_ model: RepoHeaderRowModel, collapsed: Bool) {
    MainThreadStallMonitor.breadcrumb("tree: repo \(model.name) \(collapsed ? "collapsed" : "expanded")")
    claude.setRepositoryExpanded(path: model.path, isExpanded: !collapsed)
    codex.setRepositoryExpanded(path: model.path, isExpanded: !collapsed)
  }

  func startSession(at path: String) {
    shellModel.select(.sessions)
    sessionActions.startSession(preferredRepositoryPath: path)
  }

  /// Branch row "+": the sheet opens on this branch's worktree, or on
  /// "No worktree" for the main checkout.
  func startSession(onBranch model: BranchRowModel) {
    shellModel.select(.sessions)
    sessionActions.startNewSession(preselectedWorktree: model.preselectedWorktree)
  }

  func createWorktree(repositoryPath: String) {
    let provider: SessionProviderKind = trackedRepository(repositoryPath, in: claude) != nil ? .claude : .codex
    guard let repository = trackedRepository(repositoryPath, in: viewModel(for: provider)) else { return }
    coordinator.createWorktreeContext = WorktreeCreateContext(providerKind: provider, repository: repository)
  }

  func createWorkspace(projectPath: String) {
    Task {
      guard let workspaceID = await workspaces.createWorkspace(projectPath: projectPath) else { return }
      navigationModel.workflowComparisonState.showStandaloneContent()
      navigationModel.selectedModuleLandingPath = nil
      navigationModel.primarySessionId = nil
      navigationModel.selectedWorkspaceID = workspaceID
      shellModel.select(.sessions)
    }
  }

  func showProjectDetails(path: String, name: String) {
    coordinator.projectDetailsSheetItem = ProjectDetailsSheetItem(projectPath: path, displayName: name)
  }

  func showGitHub(path: String) {
    coordinator.gitHubSheetItem = GitHubSheetItem(projectPath: path)
  }

  func openInFinder(path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
  }

  func archiveSessions(_ nodes: [SessionNode], groupName: String) {
    coordinator.archiveSessions(
      nodes.map(archivable),
      groupName: groupName,
      viewModelForProvider: viewModel(for:),
      customNameForItem: { self.viewModel(for: $0.providerKind).sessionCustomNames[$0.session.id] }
    )
  }

  /// Same confirmation text and effects as the legacy project header.
  func requestRemoveRepository(path: String, name: String, sessionCount: Int) {
    let projectWorkspaces = workspaces.workspaces(for: path)
    coordinator.removeConfirmation = RemoveConfirmation(
      title: "Remove \(name)?",
      message: SessionRemovalMessages.repository(
        name: name, sessionCount: sessionCount, workspaceCount: projectWorkspaces.count)
    ) { [self] in
      Task {
        for workspace in projectWorkspaces {
          await workspaces.closeWorkspace(id: workspace.id)
        }
        if projectWorkspaces.contains(where: { $0.id == navigationModel.selectedWorkspaceID }) {
          navigationModel.selectedWorkspaceID = nil
        }
        if navigationModel.selectedModuleLandingPath == path {
          navigationModel.selectedModuleLandingPath = nil
        }
        if let repository = trackedRepository(path, in: claude) { claude.removeRepository(repository) }
        if let repository = trackedRepository(path, in: codex) { codex.removeRepository(repository) }
      }
    }
  }

  /// - Parameter sessions: All of the branch's sessions, not only the loaded page.
  func requestRemoveWorktree(_ branch: BranchRowModel, sessions: [SessionNode]) {
    guard let worktree = trackedWorktree(branch) else { return }
    coordinator.removeConfirmation = RemoveConfirmation(
      title: "Remove \(branch.name) from Workbench?",
      message: SessionRemovalMessages.worktree(name: branch.name, sessionCount: sessions.count)
    ) { [self] in
      coordinator.removeWorktreeModuleFocus(
        worktree,
        claudeViewModel: claude,
        codexViewModel: codex,
        workspaceViewModel: workspaces,
        navigationModel: navigationModel
      )
    }
  }

  func requestDeleteWorktree(_ branch: BranchRowModel, sessions: [SessionNode]) {
    guard let worktree = trackedWorktree(branch) else { return }
    let provider =
      sessions.first(where: { !$0.isPending })?.providerKind
      ?? sessions.first?.providerKind
      ?? (worktreeIsTracked(worktree.path, in: codex) && !worktreeIsTracked(worktree.path, in: claude)
        ? .codex : .claude)
    coordinator.worktreeModuleDeleteConfirmation = WorktreeModuleDeleteConfirmation(
      worktree: worktree,
      displayName: branch.name,
      sessionCount: sessions.count,
      providerKind: provider
    )
  }

  // MARK: - Workflow

  private var workflows: AgentWorkflowDashboardViewModel { agentHub.workflowDashboardViewModel }

  func startReview(_ decoration: BranchWorkflowDecoration) {
    workflows.createReviewAgent(for: decoration.branchWorkflowID)
  }

  func compare(_ decoration: BranchWorkflowDecoration) {
    guard let request = workflows.comparisonRequest(for: decoration.branchWorkflowID) else { return }
    agentHub.openWorkflowSessionComparison(request)
    shellModel.select(.sessions)
  }

  func openPullRequest(_ decoration: BranchWorkflowDecoration) {
    guard let url = decoration.pullRequest.flatMap({ URL(string: $0.url) }) else { return }
    NSWorkspace.shared.open(url)
  }

  func openTicket(_ decoration: BranchWorkflowDecoration) {
    guard let key = decoration.ticketKey else { return }
    agentHub.showJiraTicket(key)
  }

  func archiveWorkflow(_ decoration: BranchWorkflowDecoration) {
    guard let workflowID = decoration.archivableWorkflowID else { return }
    workflows.archiveWorkflow(workflowID)
  }

  // MARK: - Session

  func copySessionID(_ node: SessionNode) {
    viewModel(for: node.providerKind).copySessionId(node.session)
  }

  func openInTerminal(_ node: SessionNode) {
    _ = viewModel(for: node.providerKind).connectToSession(node.session)
  }

  func fork(_ node: SessionNode) {
    shellModel.select(.sessions)
    sessionActions.forkSession(node.session, targetProvider: node.providerKind)
  }

  /// Archives a session; a session still starting is cancelled instead, since
  /// it has no transcript to archive yet (same as the legacy row).
  func archive(_ node: SessionNode) {
    if node.isPending {
      let viewModel = viewModel(for: node.providerKind)
      if let pending = viewModel.pendingHubSessions.first(where: { $0.id == node.pendingID }) {
        viewModel.cancelPendingSession(pending)
      }
      return
    }
    archiveSessions([node], groupName: node.session.displayName)
  }

  // MARK: - Lookup

  private func archivable(_ node: SessionNode) -> ArchivableSessionItem {
    ArchivableSessionItem(
      id: node.id,
      session: node.session,
      providerKind: node.providerKind,
      isPending: node.isPending,
      wasPinned: viewModel(for: node.providerKind).pinnedSessionIds.contains(node.session.id)
    )
  }

  private func trackedRepository(_ path: String, in viewModel: CLISessionsViewModel) -> SelectedRepository? {
    let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
    return viewModel.selectedRepositories.first {
      WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalized
    }
  }

  private func trackedWorktree(_ branch: BranchRowModel) -> WorktreeBranch? {
    guard branch.isWorktree, let path = branch.worktreePath else { return nil }
    let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
    return (claude.selectedRepositories + codex.selectedRepositories)
      .flatMap(\.worktrees)
      .first { $0.isWorktree && WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalized }
  }

  private func worktreeIsTracked(_ path: String, in viewModel: CLISessionsViewModel) -> Bool {
    let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
    return viewModel.selectedRepositories.contains { repository in
      repository.worktrees.contains {
        $0.isWorktree && WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalized
      }
    }
  }
}

// MARK: - Approve

@MainActor
enum SidebarApproval {
  /// Allows the pending call once (`answer`, in the app
  /// `CLISessionsViewModel.respondToApproval`). When the app can't answer, it
  /// opens the session so the user answers in its terminal (the banner says so).
  static func respond(
    answer: @escaping (SessionNode) -> ApprovalResponseOutcome,
    openSession: @escaping (SessionNode) -> Void
  ) -> (SessionNode) -> Void {
    { node in
      if answer(node) != .sent {
        openSession(node)
      }
    }
  }
}
