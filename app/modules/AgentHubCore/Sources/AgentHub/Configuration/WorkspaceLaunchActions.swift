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
  }

  func applyReviewSessionTitles(provider: SessionProviderKind) {
    // Titles now come from the durable launch origin. Linking a PR is never a rename.
    sessionsViewModel(for: provider).loadCustomNames()
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
        initialPrompt: prompt,
        origin: SessionLaunchOrigin(
          source: .pullRequest,
          accountID:
            "\(URL(string: pullRequest.url)?.host ?? "github.com")/\(pullRequest.repositoryNameWithOwner)",
          sourceID: pullRequest.id, key: "#\(pullRequest.number)", title: pullRequest.title)
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
    guard let account = agentHub.jiraSprintViewModel.account,
      let issueID = ticket.issueID, !issueID.isEmpty
    else {
      agentHub.jiraSprintViewModel.presentLaunchError(
        "Refresh Jira to load the account and ticket identity, then try again.",
        ticketKey: ticket.key)
      return
    }
    let origin = SessionLaunchOrigin(
      source: .jira, accountID: "\(account.site)/\(account.email)",
      sourceID: issueID, key: ticket.key, title: ticket.summary)
    let prompt = await agentHub.jiraSprintViewModel.launchPrompt(for: ticket)
    guard account == agentHub.jiraSprintViewModel.account else { return }
    let viewModel = sessionsViewModel(for: provider)
    guard
      Self.startTicketSession(
        origin: origin, prompt: prompt, repositoryPath: repositoryPath, viewModel: viewModel) != nil
    else {
      agentHub.jiraSprintViewModel.presentLaunchError(
        viewModel.launchError ?? "Could not start the session. Try again.", ticketKey: ticket.key)
      return
    }
    showSessions()
    await agentHub.jiraSprintViewModel.markInProgressIfNeeded(ticket.key)
  }

  func startLinearIssue(
    _ issue: LinearIssue,
    provider: SessionProviderKind,
    repositoryPath: String
  ) async {
    guard let accountID = agentHub.linearViewModel.viewer?.id else {
      agentHub.linearViewModel.presentLaunchError(
        "Refresh Linear to load the account, then try again.")
      return
    }
    let origin = SessionLaunchOrigin(
      source: .linear, accountID: accountID, sourceID: issue.id,
      key: issue.identifier, title: issue.title)
    let prompt = await agentHub.linearViewModel.launchPrompt(for: issue)
    guard accountID == agentHub.linearViewModel.viewer?.id else { return }
    let viewModel = sessionsViewModel(for: provider)
    guard
      Self.startTicketSession(
        origin: origin, prompt: prompt, repositoryPath: repositoryPath, viewModel: viewModel) != nil
    else {
      agentHub.linearViewModel.presentLaunchError(
        viewModel.launchError ?? "Could not start the session. Try again.")
      return
    }
    showSessions()
    await agentHub.linearViewModel.markStartedIfNeeded(issue.id)
  }

  /// The shared ticket launch boundary: publication only follows a durable origin transaction.
  @discardableResult
  static func startTicketSession(
    origin: SessionLaunchOrigin, prompt: String, repositoryPath: String,
    viewModel: CLISessionsViewModel
  ) -> UUID? {
    let path = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    guard
      let pendingID = viewModel.startNewSessionInHub(
        WorktreeBranch(name: origin.key, path: path, isWorktree: false, isExpanded: true),
        initialPrompt: prompt, origin: origin)
    else { return nil }
    viewModel.addRepository(at: path)
    return pendingID
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
