//
//  WorkspaceLaunchActions.swift
//  AgentHub
//
//  Launch and open actions shared by the legacy root (`AgentHubOperationsView`)
//  and the new shell root (`WorkbenchShellView`): start a session from a pull
//  request, a Jira ticket or a Linear issue; open a linked session; resume by
//  id; and name sessions once their pending launch resolves.
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation

@MainActor
struct WorkspaceLaunchActions {
  let agentHub: AgentHubProvider
  /// Called when an action should bring the Sessions view forward.
  let showSessions: () -> Void

  private func sessionsViewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
  }

  private var mergedRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      agentHub.claudeSessionsViewModel.selectedRepositories
        + agentHub.codexSessionsViewModel.selectedRepositories
    )
  }

  // MARK: - Pending session resolution

  /// Runs when a provider's `resolvedPendingSessionHistory` changes: links
  /// review launches to their real session and applies review and Jira titles.
  func handleResolvedPendingSessions(
    _ resolutions: [UUID: String],
    provider: SessionProviderKind
  ) {
    Task {
      await agentHub.gitHubReviewsViewModel.resolveReviewLaunches(
        resolutions,
        provider: provider
      )
      applyReviewSessionTitles(provider: provider)
    }
    for (sessionID, name) in agentHub.jiraSprintViewModel.takeSessionNames(resolved: resolutions) {
      sessionsViewModel(for: provider).setCustomName(name, forSessionId: sessionID)
    }
  }

  func applyReviewSessionTitles(provider: SessionProviderKind) {
    let sessionsViewModel = sessionsViewModel(for: provider)
    for (sessionID, title) in agentHub.gitHubReviewsViewModel.linkedSessionTitles(
      provider: provider
    ) {
      sessionsViewModel.setCustomName(title, forSessionId: sessionID)
    }
  }

  // MARK: - Reviews

  func startReview(
    _ pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    template: GitHubPromptTemplate
  ) async {
    guard let project = agentHub.gitHubReviewsViewModel.selectedProject,
      let view = agentHub.gitHubReviewsViewModel.selectedView
    else { return }

    guard
      let repositoryPath = Self.localRepositoryPath(
        named: pullRequest.repositoryName,
        repositories: mergedRepositories
      )
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "No local checkout found for \(pullRequest.repositoryNameWithOwner). Add that repository in Sessions first."
      )
      return
    }

    let sessionsViewModel = sessionsViewModel(for: provider)
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let target = WorktreeBranch(
      name: pullRequest.title,
      path: normalizedPath,
      isWorktree: false,
      isExpanded: true
    )
    let prompt = GitHubPromptLibrary.shared.renderedPrompt(
      template: template,
      context: GitHubPromptContext(
        pullRequest: pullRequest,
        project: project,
        view: view,
        provider: provider
      )
    )

    sessionsViewModel.addRepository(at: normalizedPath)
    guard
      let pendingID = sessionsViewModel.startAutomatedSessionInHub(
        target,
        initialPrompt: prompt
      )
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "Could not start the \(provider.rawValue) pull request session."
      )
      return
    }
    await agentHub.gitHubReviewsViewModel.registerReviewLaunch(
      for: pullRequest,
      provider: provider,
      pendingID: pendingID,
      projectPath: normalizedPath
    )
    await agentHub.gitHubReviewsViewModel.resolveReviewLaunches(
      sessionsViewModel.resolvedPendingSessionHistory,
      provider: provider
    )
    applyReviewSessionTitles(provider: provider)
  }

  func openReviewSession(_ link: GitHubReviewSessionLink) {
    let sessionsViewModel = sessionsViewModel(for: link.provider)
    if !link.isPending, !sessionsViewModel.isMonitoring(sessionId: link.session.id) {
      sessionsViewModel.startMonitoring(session: link.session)
    }
    agentHub.globalSessionSelectionRouter.select(
      providerKind: link.provider,
      sessionId: link.session.id,
      projectPath: link.session.projectPath,
      itemId: link.itemID,
      session: link.isPending ? nil : link.session
    )
    showSessions()
  }

  // MARK: - Resume by id

  /// Looks the id up in Claude and Codex at once and opens whichever has it.
  func resumeSession(id: String) async -> Bool {
    async let claude = agentHub.claudeSessionsViewModel.resumeSession(id: id)
    async let codex = agentHub.codexSessionsViewModel.resumeSession(id: id)
    let (claudeSession, codexSession) = await (claude, codex)
    guard let session = claudeSession ?? codexSession else { return false }
    let provider: SessionProviderKind = claudeSession != nil ? .claude : .codex
    agentHub.globalSessionSelectionRouter.select(
      providerKind: provider,
      sessionId: session.id,
      projectPath: session.projectPath,
      session: session
    )
    showSessions()
    return true
  }

  // MARK: - Sprint

  func startJiraTicket(
    _ ticket: JiraTicketSnapshot,
    provider: SessionProviderKind,
    repositoryPath: String
  ) async {
    let sessionsViewModel = sessionsViewModel(for: provider)
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let prompt = await agentHub.jiraSprintViewModel.launchPrompt(for: ticket)

    sessionsViewModel.addRepository(at: normalizedPath)
    sessionsViewModel.startNewSessionInHub(
      WorktreeBranch(
        name: ticket.key,
        path: normalizedPath,
        isWorktree: false,
        isExpanded: true
      ),
      initialPrompt: prompt
    )
    if let pendingID = sessionsViewModel.lastCreatedPendingId {
      agentHub.jiraSprintViewModel.registerPendingSession(pendingID, for: ticket)
    }
    showSessions()
    // An agent picking up a To do ticket means work started.
    await agentHub.jiraSprintViewModel.markInProgressIfNeeded(ticket.key)
  }

  func startLinearIssue(
    _ issue: LinearIssue,
    provider: SessionProviderKind,
    repositoryPath: String
  ) async {
    let sessionsViewModel = sessionsViewModel(for: provider)
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let prompt = await agentHub.linearViewModel.launchPrompt(for: issue)

    sessionsViewModel.addRepository(at: normalizedPath)
    sessionsViewModel.startNewSessionInHub(
      WorktreeBranch(
        name: issue.identifier,
        path: normalizedPath,
        isWorktree: false,
        isExpanded: true
      ),
      initialPrompt: prompt
    )
    if let pendingID = sessionsViewModel.lastCreatedPendingId {
      agentHub.linearViewModel.registerPendingSession(pendingID, for: issue)
    }
    showSessions()
    await agentHub.linearViewModel.markStartedIfNeeded(issue.id)
  }

  // MARK: - Helpers

  static func localRepositoryPath(
    named repositoryName: String,
    repositories: [SelectedRepository]
  ) -> String? {
    if let repository = repositories.first(where: {
      $0.name.localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
        || URL(fileURLWithPath: $0.path).lastPathComponent
          .localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
    }) {
      return repository.path
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/LocalDocuments/Github/\(repositoryName)",
      "\(home)/Documents/GitHub/\(repositoryName)",
      "\(home)/Developer/\(repositoryName)",
      "\(home)/Projects/\(repositoryName)",
    ]
    return candidates.first { candidate in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
        && isDirectory.boolValue
        && FileManager.default.fileExists(atPath: "\(candidate)/.git")
    }
  }
}
