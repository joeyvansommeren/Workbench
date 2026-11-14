//
//  SidebarCIFailureNotifications.swift
//  AgentHub
//
//  "CI failed" notifications for the new interface. In the legacy UI every
//  `CollapsibleSessionRow` observes its session's pull request and feeds
//  `GitHubCIFailureNotifier`. Tree rows are lazy and the sidebar leaves the
//  hierarchy when it is hidden, so here one observer per window watches every
//  monitored session, whatever is on screen. It uses the same notifier and
//  the same observation settings as the legacy row, so a failure notifies
//  once per (repo, PR, head commit) however many surfaces observe it.
//

import AgentHubGitHub
import SwiftUI

// MARK: - Targets

/// One monitored session the observer watches.
struct SidebarCIObservationTarget: Equatable {
  let itemID: String
  let providerKind: SessionProviderKind
  let sessionID: String
  let projectPath: String
  let branchName: String?
  let linkedPullRequests: [GitHubPullRequestURLReference]
  let lastActivityAt: Date

  /// Same identity as the legacy row's observation task: a new branch or a
  /// new linked PR starts a new subscription.
  var observationKey: String {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName,
      linkedPullRequests: linkedPullRequests
    )
    return "\(itemID)|\(repositoryKey)"
  }

  var context: GitHubCIFailureSessionContext {
    GitHubCIFailureSessionContext(
      sessionId: sessionID,
      providerKind: providerKind,
      projectPath: projectPath,
      branchName: branchName
    )
  }
}

enum SidebarCIObservationTargets {
  /// Monitored sessions of both providers. Pending launches are skipped, as
  /// in the legacy row. Linked PRs: detected in the transcript, then the
  /// ones Reviews associated, without duplicates (legacy order).
  @MainActor
  static func targets(
    claude: CLISessionsViewModel,
    codex: CLISessionsViewModel,
    reviews: GitHubReviewsViewModel?
  ) -> [SidebarCIObservationTarget] {
    var results: [SidebarCIObservationTarget] = []
    for (provider, viewModel) in [(SessionProviderKind.claude, claude), (.codex, codex)] {
      let associated = reviews?.linkedPullRequestReferencesByItemID(provider: provider) ?? [:]
      for session in viewModel.monitoredCLISessions {
        let itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: session.id)
        results.append(
          target(
            itemID: itemID,
            provider: provider,
            session: session,
            detected: viewModel.pullRequestReferences(for: session.id),
            associated: associated[itemID] ?? []
          ))
      }
    }
    return results
  }

  static func target(
    itemID: String,
    provider: SessionProviderKind,
    session: CLISession,
    detected: [GitHubPullRequestURLReference],
    associated: [GitHubPullRequestURLReference]
  ) -> SidebarCIObservationTarget {
    var seen: Set<GitHubPullRequestURLReference> = []
    return SidebarCIObservationTarget(
      itemID: itemID,
      providerKind: provider,
      sessionID: session.id,
      projectPath: session.projectPath,
      branchName: session.branchName,
      linkedPullRequests: (detected + associated).filter { seen.insert($0).inserted },
      lastActivityAt: session.lastActivityAt
    )
  }
}

// MARK: - Observer

/// Keeps one GitHub observation per target and forwards every snapshot to
/// the CI-failure notifier. `update(targets:)` starts new targets, stops gone
/// ones and records activity for the rest.
@MainActor
final class SidebarCIFailureObserver {
  private struct Entry {
    let target: SidebarCIObservationTarget
    let viewModel: SessionGitHubQuickAccessViewModel
    let task: Task<Void, Never>
  }

  private let observationService: (any GitHubPRObservationServiceProtocol)?
  private let notifier: (any GitHubCIFailureNotifierProtocol)?
  private let startupDelay: (SidebarCIObservationTarget) -> Duration
  private var entries: [String: Entry] = [:]

  init(
    observationService: (any GitHubPRObservationServiceProtocol)?,
    notifier: (any GitHubCIFailureNotifierProtocol)?,
    startupDelay: @escaping (SidebarCIObservationTarget) -> Duration = SidebarCIFailureObserver
      .legacyStartupDelay
  ) {
    self.observationService = observationService
    self.notifier = notifier
    self.startupDelay = startupDelay
  }

  /// The observation keys being watched (test seam).
  var observedKeys: Set<String> { Set(entries.keys) }

  func update(targets: [SidebarCIObservationTarget]) {
    guard let observationService else { return }
    var wanted: [String: SidebarCIObservationTarget] = [:]
    for target in targets { wanted[target.observationKey] = target }

    for (key, entry) in entries where wanted[key] == nil {
      stop(entry)
      entries[key] = nil
    }
    for (key, target) in wanted {
      if let entry = entries[key] {
        if entry.target.lastActivityAt != target.lastActivityAt {
          entries[key] = Entry(target: target, viewModel: entry.viewModel, task: entry.task)
          let viewModel = entry.viewModel
          Task { await viewModel.notifySessionActivity(at: target.lastActivityAt) }
        }
      } else {
        entries[key] = start(target, observationService: observationService)
      }
    }
  }

  func stopAll() {
    for entry in entries.values { stop(entry) }
    entries = [:]
  }

  private func start(
    _ target: SidebarCIObservationTarget,
    observationService: any GitHubPRObservationServiceProtocol
  ) -> Entry {
    let viewModel = SessionGitHubQuickAccessViewModel()
    let delay = startupDelay(target)
    let notifier = notifier
    // Same recipe as `CollapsibleSessionRow.observeGitHubIfAvailable()`.
    let task = Task {
      guard
        await SessionCIObservation.load(
          viewModel,
          context: target.context,
          linkedPullRequests: target.linkedPullRequests,
          observationService: observationService,
          notifier: notifier,
          startupDelay: delay
        )
      else { return }
      // Stopped while subscribing: `stop` ran before there was a subscription
      // to end, so end it here.
      guard !Task.isCancelled else {
        viewModel.stopPolling()
        return
      }
      await viewModel.notifySessionActivity(at: target.lastActivityAt)
    }
    return Entry(target: target, viewModel: viewModel, task: task)
  }

  private func stop(_ entry: Entry) {
    entry.task.cancel()
    entry.viewModel.stopPolling()
  }

  /// The legacy row's per-session stagger (`SessionCIObservation.startupDelay`).
  nonisolated static func legacyStartupDelay(_ target: SidebarCIObservationTarget) -> Duration {
    SessionCIObservation.startupDelay(sessionID: target.sessionID)
  }
}

// MARK: - View

/// Applied once per window at the shell root (not on the sidebar, which
/// leaves the hierarchy when hidden). Draws nothing.
struct SidebarCIFailureNotifications: ViewModifier {
  let agentHub: AgentHubProvider

  func body(content: Content) -> some View {
    content.background(SidebarCIFailureDriver(agentHub: agentHub))
  }
}

/// A separate empty view, so the session reads below re-render only it.
private struct SidebarCIFailureDriver: View {
  let agentHub: AgentHubProvider
  @State private var observer: SidebarCIFailureObserver

  init(agentHub: AgentHubProvider) {
    self.agentHub = agentHub
    _observer = State(
      initialValue: SidebarCIFailureObserver(
        observationService: agentHub.gitHubPRObservationService,
        notifier: agentHub.gitHubCIFailureNotifier
      ))
  }

  var body: some View {
    Color.clear
      .onChange(of: targets, initial: true) { _, newTargets in
        observer.update(targets: newTargets)
      }
      // `onDisappear` stops everything, and the @State observer survives a
      // reappear with unchanged targets, which `onChange` would not report.
      // `update` is idempotent, so the extra call on first appear is free.
      .onAppear { observer.update(targets: targets) }
      .onDisappear { observer.stopAll() }
      .accessibilityHidden(true)
  }

  private var targets: [SidebarCIObservationTarget] {
    SidebarCIObservationTargets.targets(
      claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel,
      reviews: agentHub.gitHubReviewsViewModel
    )
  }
}
