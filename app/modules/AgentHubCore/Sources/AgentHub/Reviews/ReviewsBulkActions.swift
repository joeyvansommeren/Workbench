//
//  ReviewsBulkActions.swift
//  AgentHub
//
//  The legacy Reviews header's bulk actions, for the new shell: "Start for N
//  without session", "Re-review N" and "Resolve comments N". The counts come
//  from the same view-model calls as the legacy header; the menu sits next
//  to Filters and shows only when one of them has work to do.
//

import AgentHubGitHub
import SwiftUI

/// What the bulk actions would act on, for the rows in view.
struct ReviewsBulkActions {
  /// Pull requests by someone else with no linked session yet. Empty while
  /// your login is unknown.
  let launchCandidates: [GitHubProjectPullRequest]
  /// Others' pull requests whose existing session can review again.
  let reReviewTargets: [GitHubReviewBulkFollowUp.Target]
  /// Your own pull requests whose existing session can resolve comments.
  let resolveTargets: [GitHubReviewBulkFollowUp.Target]
  /// Your own pull requests in view that have no session to send to.
  let resolveSkipped: Int

  @MainActor
  init(rows: [GitHubReviewTableRow], viewModel: GitHubReviewsViewModel) {
    launchCandidates = viewModel.bulkReviewCandidates(
      GitHubReviewTableRow.withoutSessions(rows).map(\.pullRequest))
    reReviewTargets = viewModel.followUpTargets(rows, kind: .reReview)
    resolveTargets = viewModel.followUpTargets(rows, kind: .resolveComments)
    let own = rows.filter { viewModel.isOwnPullRequest($0.pullRequest) == true }.count
    resolveSkipped = max(0, own - resolveTargets.count)
  }

  var isEmpty: Bool {
    launchCandidates.isEmpty && reReviewTargets.isEmpty && resolveTargets.isEmpty
  }

  func followUp(_ kind: GitHubReviewBulkFollowUp.Kind) -> GitHubReviewBulkFollowUp {
    switch kind {
    case .reReview:
      return GitHubReviewBulkFollowUp(kind: kind, targets: reReviewTargets, skippedWithoutSession: 0)
    case .resolveComments:
      return GitHubReviewBulkFollowUp(
        kind: kind, targets: resolveTargets, skippedWithoutSession: resolveSkipped)
    }
  }
}

/// How far a bulk "Start for N" launch has got. The launches run one after
/// another; the bar shows this with a Stop button until the last one starts.
struct ReviewsBulkLaunchProgress: Equatable {
  let total: Int
  /// Pull requests handled so far: launched or skipped.
  private(set) var processed = 0
  /// Launches that began, including one still in flight. Skipped pull
  /// requests (a review already starting) do not count.
  private(set) var started = 0

  init(total: Int) {
    self.total = total
  }

  /// The one that is starting now, counted from 1.
  var current: Int { min(processed + 1, total) }
  var isFinished: Bool { processed >= total }

  /// A launch began for the next pull request.
  mutating func begin() {
    started = min(started + 1, total)
  }

  /// The next pull request is done: launched or skipped.
  mutating func advance() {
    processed = min(processed + 1, total)
  }

  var text: String { "Starting \(current) of \(total)" }
}

/// Runs a bulk launch one pull request at a time, and Stop. Owned by the
/// Reviews screen; a new run supersedes the old one, whose loop then ends
/// without touching the new progress.
@MainActor
@Observable
final class ReviewsBulkLaunchRunner {
  private(set) var progress: ReviewsBulkLaunchProgress?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var runID: UUID?
  /// The latest loop, kept after Stop so tests can wait for its launch in flight.
  @ObservationIgnored private var lastTask: Task<Void, Never>?

  var isRunning: Bool { progress != nil }

  /// - Parameters:
  ///   - begin: Claims the item for a launch; false skips it (for example a
  ///     review of that pull request is already starting).
  ///   - launch: Starts the claimed item. Runs to the end even after Stop,
  ///     so it can release its claim.
  func run<Item>(
    _ items: [Item],
    begin: @escaping (Item) -> Bool,
    launch: @escaping (Item) async -> Void
  ) {
    task?.cancel()
    let id = UUID()
    runID = id
    progress = ReviewsBulkLaunchProgress(total: items.count)
    task = Task { [weak self] in
      for item in items {
        guard let self, self.runID == id, !Task.isCancelled else { return }
        if begin(item) {
          self.progress?.begin()
          await launch(item)
        }
        guard self.runID == id else { return }
        self.progress?.advance()
      }
      guard let self, self.runID == id else { return }
      self.finish()
    }
    lastTask = task
  }

  /// Stops after the launch in flight. Returns how many launches began,
  /// including that one; nil when nothing ran.
  @discardableResult
  func stop() -> Int? {
    let started = progress?.started
    task?.cancel()
    finish()
    return started
  }

  /// Waits for the latest loop, including a launch in flight at Stop; for tests.
  func waitUntilDone() async {
    await lastTask?.value
  }

  private func finish() {
    task = nil
    runID = nil
    progress = nil
  }
}

/// "Starting 3 of 40" and Stop, in the bar while a bulk launch runs. Takes
/// the place of the Actions menu, so a second launch cannot start meanwhile.
struct ReviewsBulkLaunchProgressView: View {
  let progress: ReviewsBulkLaunchProgress
  let onStop: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      Text(progress.text)
        .wbText(.callout)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
      Button("Stop", action: onStop)
        .buttonStyle(.wbSecondary)
        .accessibilityLabel("Stop starting review sessions")
        .accessibilityIdentifier("reviews.bulkStop")
    }
    .fixedSize()
  }
}

/// The "Actions ⌄" menu in the Reviews bar. Every item asks for confirmation
/// through its host before anything starts.
struct ReviewsBulkActionsMenu: View {
  let actions: ReviewsBulkActions
  let templates: [GitHubPromptTemplate]
  let isAgentAvailable: (SessionProviderKind) -> Bool
  /// A review is starting somewhere: new bulk launches wait for it.
  let isStarting: Bool
  let onLaunch: (GitHubReviewBulkLaunch) -> Void
  let onFollowUp: (GitHubReviewBulkFollowUp) -> Void

  var body: some View {
    Menu {
      if !actions.launchCandidates.isEmpty {
        let count = actions.launchCandidates.count
        ForEach([SessionProviderKind.codex, .claude], id: \.self) { provider in
          Section("Start for \(count) without session · \(PullRequestReviewControl.displayName(provider))") {
            ForEach(templates) { template in
              Button(template.name) {
                onLaunch(
                  GitHubReviewBulkLaunch(
                    pullRequests: actions.launchCandidates, provider: provider, template: template))
              }
              .disabled(!isAgentAvailable(provider) || isStarting)
            }
          }
        }
      }
      if !actions.reReviewTargets.isEmpty || !actions.resolveTargets.isEmpty {
        Section("Existing sessions") {
          if !actions.reReviewTargets.isEmpty {
            Button("Re-review \(actions.reReviewTargets.count)", systemImage: "arrow.clockwise.circle") {
              onFollowUp(actions.followUp(.reReview))
            }
          }
          if !actions.resolveTargets.isEmpty {
            Button(
              "Resolve comments \(actions.resolveTargets.count)",
              systemImage: "bubble.left.and.exclamationmark.bubble.right"
            ) {
              onFollowUp(actions.followUp(.resolveComments))
            }
          }
        }
      }
    } label: {
      WBMenuButtonLabel("Actions")
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Start reviews or send follow-ups for the pull requests in view")
    .accessibilityLabel("Bulk review actions")
    .accessibilityIdentifier("reviews.bulkActions")
  }
}
