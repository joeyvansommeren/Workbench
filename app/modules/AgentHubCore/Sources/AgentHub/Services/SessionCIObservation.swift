//
//  SessionCIObservation.swift
//  AgentHub
//
//  How one session's pull request is observed for "CI failed" notifications.
//  Shared by the legacy `CollapsibleSessionRow` and the new interface's
//  `SidebarCIFailureObserver`, so both subscribe with the same stagger and
//  the same observation settings.
//

import AgentHubGitHub
import Foundation

enum SessionCIObservation {
  /// Per-session stagger: 250 ms plus 0–1.5 s from the session id, so launch
  /// does not subscribe every session at once.
  static func startupDelay(sessionID: String) -> Duration {
    let bucket = sessionID.unicodeScalars.reduce(0) { partialResult, scalar in
      (partialResult + Int(scalar.value)) % 1_500
    }
    return .milliseconds(250 + bucket)
  }

  /// Waits the stagger (only without linked PRs: a linked PR is refreshed at
  /// once), hooks the notifier, and subscribes `viewModel`.
  ///
  /// - Returns: false when the task was cancelled during the stagger, so
  ///   nothing was subscribed. True once `load` ran; the caller then records
  ///   activity (and checks cancellation itself if it needs to).
  @MainActor
  static func load(
    _ viewModel: SessionGitHubQuickAccessViewModel,
    context: GitHubCIFailureSessionContext,
    linkedPullRequests: [GitHubPullRequestURLReference],
    observationService: any GitHubPRObservationServiceProtocol,
    notifier: (any GitHubCIFailureNotifierProtocol)?,
    startupDelay: Duration
  ) async -> Bool {
    if linkedPullRequests.isEmpty {
      try? await Task.sleep(for: startupDelay)
      guard !Task.isCancelled else { return false }
    }

    if let notifier {
      viewModel.onSnapshotApplied = { snapshot in
        notifier.evaluate(snapshot: snapshot, context: context)
      }
    }

    await viewModel.load(
      projectPath: context.projectPath,
      branchName: context.branchName,
      linkedPullRequests: linkedPullRequests,
      observationService: observationService,
      refreshOnSubscribe: false,
      recordInitialActivity: false,
      forceRefreshLinkedPullRequest: !linkedPullRequests.isEmpty
    )
    return true
  }
}
