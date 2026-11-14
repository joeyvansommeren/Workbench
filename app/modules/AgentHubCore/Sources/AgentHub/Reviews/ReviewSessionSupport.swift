//
//  ReviewSessionSupport.swift
//  AgentHub
//
//  Session linking for the new shell's Reviews view: the per-render session
//  inventories, and the restore pass that runs when Reviews opens.
//
//  Copied from the private helpers in the legacy `GitHubReviewsView`, which
//  stays unchanged for the flag-off path. P11b deletes the legacy copy.
//

import AgentHubGitHub
import Foundation

@MainActor
struct ReviewSessionSupport {
  let agentHub: AgentHubProvider

  private var viewModel: GitHubReviewsViewModel { agentHub.gitHubReviewsViewModel }
  private var claude: CLISessionsViewModel { agentHub.claudeSessionsViewModel }
  private var codex: CLISessionsViewModel { agentHub.codexSessionsViewModel }

  /// Build once per render and pass to every row: building it per row
  /// relinked every session for every pull request.
  var inventories: [GitHubReviewSessionInventory] {
    [inventory(for: claude), inventory(for: codex)]
  }

  func links(
    for pullRequest: GitHubProjectPullRequest,
    inventories: [GitHubReviewSessionInventory]
  ) -> [GitHubReviewSessionLink] {
    GitHubReviewSessionLinker.links(
      for: pullRequest,
      launches: viewModel.reviewSessionLaunches(for: pullRequest),
      inventories: inventories
    )
  }

  /// Everything the links for `pullRequests` depend on, as one hash: the pull
  /// requests, their launches, each provider's session inventory and the
  /// known Jira projects. Not statuses: those change on every agent update,
  /// and `ReviewsSessionLinkCache` applies them separately. Activity times
  /// count by the minute (`sessionKey`). Reading these also keeps the caller
  /// observing them.
  func linkKey(for pullRequests: [GitHubProjectPullRequest]) -> Int {
    var hasher = Hasher()
    for pullRequest in pullRequests {
      hasher.combine(pullRequest.id)
      hasher.combine(pullRequest.title)
      hasher.combine(pullRequest.url)
      hasher.combine(pullRequest.repositoryName)
      for launch in viewModel.reviewSessionLaunches(for: pullRequest) {
        hasher.combine(launch.provider)
        hasher.combine(launch.pendingID)
        hasher.combine(launch.sessionID)
      }
    }
    for sessions in [claude, codex] {
      hasher.combine(sessions.providerKind)
      for session in sessions.allSessions {
        Self.combineSessionKey(session, into: &hasher)
      }
      for pending in sessions.pendingHubSessions {
        hasher.combine(pending.id)
        hasher.combine(pending.worktree.name)
      }
      hasher.combine(sessions.resolvedPendingSessionHistory)
      hasher.combine(sessions.sessionCustomNames)
    }
    hasher.combine(agentHub.jiraSprintViewModel.knownProjectKeys)
    return hasher.finalize()
  }

  /// The parts of a session the links depend on.
  static func combineSessionKey(_ session: CLISession, into hasher: inout Hasher) {
    hasher.combine(session.id)
    hasher.combine(session.projectPath)
    hasher.combine(session.branchName)
    hasher.combine(session.slug)
    hasher.combine(session.isActive)
    // Lengths, not text: the prompts can be long, and they only change
    // when the user sends a message.
    hasher.combine(session.firstMessage?.utf8.count)
    hasher.combine(session.lastMessage?.utf8.count)
    // The linker keeps the most recent session per provider and puts the
    // most recent first, so activity must relink. By the minute, so a busy
    // agent relinks at most once a minute, not on every update.
    hasher.combine(activityMinute(session.lastActivityAt))
  }

  static func activityMinute(_ date: Date) -> Int {
    Int((date.timeIntervalSince1970 / 60).rounded(.down))
  }

  /// Every session's current status, per provider.
  var statuses: [SessionProviderKind: [String: SessionStatus]] {
    [.claude: claude.sessionStatuses, .codex: codex.sessionStatuses]
  }

  /// Links pending launches to their real sessions, recovers links from before
  /// they were stored (once), names the sessions, and restores them for monitoring.
  func recoverAndRestoreSessions() async {
    let launchActions = WorkspaceLaunchActions(agentHub: agentHub, showSessions: {})
    await viewModel.resolveReviewLaunches(claude.resolvedPendingSessionHistory, provider: .claude)
    await viewModel.resolveReviewLaunches(codex.resolvedPendingSessionHistory, provider: .codex)
    launchActions.applyReviewSessionTitles(provider: .claude)
    launchActions.applyReviewSessionTitles(provider: .codex)

    if viewModel.shouldRecoverLegacySessionLinks {
      async let claudeResults = claude.githubReviewSessionSearchResults()
      async let codexResults = codex.githubReviewSessionSearchResults()
      let (resolvedClaude, resolvedCodex) = await (claudeResults, codexResults)
      await viewModel.recoverReviewSessions(provider: .claude, searchResults: resolvedClaude)
      await viewModel.recoverReviewSessions(provider: .codex, searchResults: resolvedCodex)
      viewModel.finishLegacySessionRecovery()
    }

    let references = viewModel.linkedSessionReferences
    async let restoreClaude: Void = claude.restoreWorkspaceSessions(references)
    async let restoreCodex: Void = codex.restoreWorkspaceSessions(references)
    _ = await (restoreClaude, restoreCodex)
  }

  private func inventory(for sessions: CLISessionsViewModel) -> GitHubReviewSessionInventory {
    GitHubReviewSessionInventory(
      provider: sessions.providerKind,
      sessions: sessions.allSessions,
      pendingSessions: sessions.pendingHubSessions,
      resolvedPendingSessionIDs: sessions.resolvedPendingSessionHistory,
      customNames: sessions.sessionCustomNames,
      statuses: sessions.sessionStatuses,
      ticketKeysBySessionID: ticketKeys(for: sessions)
    )
  }

  /// Ticket keys per session, via the Sprint board's cached detector. Project
  /// keys seen in the queue's PR titles count as known, so this works before
  /// Jira loads.
  private func ticketKeys(for sessions: CLISessionsViewModel) -> [String: [String]] {
    let jira = agentHub.jiraSprintViewModel
    var knownProjects = jira.knownProjectKeys
    for pullRequest in viewModel.pullRequests {
      for key in GitHubReviewSessionLinker.ticketKeys(inTitle: pullRequest.title) {
        if let project = key.split(separator: "-").first { knownProjects.insert(String(project)) }
      }
    }
    var result: [String: [String]] = [:]
    for session in sessions.allSessions {
      let keys = jira.sessionLinker.cachedKeys(
        id: SidebarSessionItemID.monitored(provider: sessions.providerKind, sessionId: session.id),
        branchName: session.branchName,
        customName: sessions.sessionCustomNames[session.id],
        prompt: session.firstMessage,
        knownProjectKeys: knownProjects
      )
      if !keys.isEmpty { result[session.id] = keys }
    }
    return result
  }
}
