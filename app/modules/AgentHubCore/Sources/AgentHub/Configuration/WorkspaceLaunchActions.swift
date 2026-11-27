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
    let reviews = agentHub.gitHubReviewsViewModel
    guard let account = await reviews.validateReviewLaunch(pullRequest) else { return }
    let revision = reviews.sourceRevision
    let project = reviews.selectedProject
    let view = reviews.selectedView

    guard
      let repositoryPath = await Self.reviewRepositoryPath(
        pullRequest: pullRequest, repositories: mergedRepositories,
        resolver: agentHub.gitHubRepositoryIdentityResolver)
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "Could not find a unique local checkout for \(pullRequest.repositoryNameWithOwner). Check your repositories in Sessions."
      )
      return
    }

    guard !Task.isCancelled, reviews.sourceAccount == account, reviews.sourceRevision == revision
    else { return }
    let sessionsViewModel = sessionsViewModel(for: provider)
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let branchName = try? await agentHub.gitService.getCurrentBranch(at: normalizedPath)
    guard !Task.isCancelled, reviews.sourceAccount == account, reviews.sourceRevision == revision
    else { return }
    let target = WorktreeBranch(
      name: branchName ?? "HEAD",
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
          accountID: account.persistenceKey,
          sourceID: pullRequest.reviewIdentity, key: "#\(pullRequest.number)",
          title: pullRequest.title)
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
      projectPath: normalizedPath, branchName: branchName
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

  private var ticketSessionAdapters: [SessionProviderKind: CLISessionsViewModel] {
    [.claude: agentHub.claudeSessionsViewModel, .codex: agentHub.codexSessionsViewModel]
  }

  func ticketSessionOptions() -> [TicketSessionProviderOption] {
    let adapters = ticketSessionAdapters
    return TicketSessionProviderOption.resolve(TicketSessionProviderDescriptor.catalog) { id in
      guard let provider = SessionProviderKind(rawValue: id), let viewModel = adapters[provider] else {
        return nil
      }
      viewModel.refreshCLIAvailability()
      return (provider, viewModel.isCLIAvailable)
    }
  }

  func startJiraTicket(
    _ ticket: JiraTicketSnapshot,
    provider: SessionProviderKind,
    repositoryPath: String
  ) async -> String? {
    guard let account = agentHub.jiraSprintViewModel.account,
      let issueID = ticket.issueID, !issueID.isEmpty
    else { return "Refresh Jira to load the account and ticket identity, then try again." }
    let publicationRepository = await agentHub.gitHubRepositoryIdentityResolver.resolveIdentity(
      at: repositoryPath, expectedHost: "github.com")
    let origin = SessionLaunchOrigin(
      source: .jira, accountID: "\(account.site)/\(account.email)",
      sourceID: issueID, key: ticket.key, title: ticket.summary,
      publicationRepository: publicationRepository)
    let prompt = await agentHub.jiraSprintViewModel.launchPrompt(for: ticket)
    guard account == agentHub.jiraSprintViewModel.account else {
      return "The Jira account changed. Close this chooser and reopen the ticket."
    }
    if let error = launchTicket(origin: origin, prompt: prompt, provider: provider, path: repositoryPath) {
      return error
    }
    showSessions()
    await agentHub.jiraSprintViewModel.markInProgressIfNeeded(ticket.key)
    return nil
  }

  func startLinearIssue(
    _ issue: LinearIssue,
    provider: SessionProviderKind,
    repositoryPath: String
  ) async -> String? {
    guard let accountID = agentHub.linearViewModel.viewer?.id else {
      return "Refresh Linear to load the account, then try again."
    }
    let publicationRepository = await agentHub.gitHubRepositoryIdentityResolver.resolveIdentity(
      at: repositoryPath, expectedHost: "github.com")
    let origin = SessionLaunchOrigin(
      source: .linear, accountID: accountID, sourceID: issue.id,
      key: issue.identifier, title: issue.title, publicationRepository: publicationRepository)
    let prompt = await agentHub.linearViewModel.launchPrompt(for: issue)
    guard accountID == agentHub.linearViewModel.viewer?.id else {
      return "The Linear account changed. Close this chooser and reopen the ticket."
    }
    if let error = launchTicket(origin: origin, prompt: prompt, provider: provider, path: repositoryPath) {
      return error
    }
    showSessions()
    await agentHub.linearViewModel.markStartedIfNeeded(issue.id)
    return nil
  }

  private func launchTicket(
    origin: SessionLaunchOrigin, prompt: String, provider: SessionProviderKind, path: String
  ) -> String? {
    guard let viewModel = ticketSessionAdapters[provider] else {
      return "This agent cannot start ticket sessions."
    }
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(path)
    guard mergedRepositories.contains(where: {
      WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalizedPath
    }), TicketSessionChooserModel.directoryExists(normalizedPath)
    else { return "This repository is no longer available. Choose another repository." }
    guard Self.startTicketSession(
      origin: origin, prompt: prompt, repositoryPath: normalizedPath, viewModel: viewModel
    ) != nil else { return viewModel.launchError ?? "Could not start the session. Try again." }
    return nil
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
}

// MARK: - Helpers

extension WorkspaceLaunchActions {
  static func reviewRepositoryPath(
    pullRequest: GitHubProjectPullRequest, repositories: [SelectedRepository],
    resolver: any GitHubRepositoryIdentityResolverProtocol
  ) async -> String? {
    guard let host = URL(string: pullRequest.url)?.host else { return nil }
    var matches: [String] = []
    for repository in repositories {
      guard !Task.isCancelled else { return nil }
      let identities = await resolver.resolveIdentities(at: repository.path, expectedHost: host)
      guard
        identities.contains(where: { identity in
          identity.host.caseInsensitiveCompare(host) == .orderedSame
            && "\(identity.owner)/\(identity.repository)".caseInsensitiveCompare(
              pullRequest.repositoryNameWithOwner) == .orderedSame
        })
      else { continue }
      matches.append(repository.path)
    }
    return matches.count == 1 ? matches[0] : nil
  }

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
