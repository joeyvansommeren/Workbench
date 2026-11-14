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
  private(set) var started = 0

  init(total: Int) {
    self.total = total
  }

  /// The one that is starting now, counted from 1.
  var current: Int { min(started + 1, total) }
  var isFinished: Bool { started >= total }

  mutating func advance() {
    started = min(started + 1, total)
  }

  var text: String { "Starting \(current) of \(total)" }
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

  @State private var isHovered = false

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
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        Text("Actions")
          .wbText(.bodyEmphasis)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .foregroundStyle(Color.wbTextPrimary)
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(height: DesignTokens.Size.control)
      .background(
        isHovered ? Color.wbSurfaceControlHover : Color.wbSurfaceControl,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
      )
      .wbElevation(.control)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { isHovered = $0 }
    .help("Start reviews or send follow-ups for the pull requests in view")
    .accessibilityLabel("Bulk review actions")
    .accessibilityIdentifier("reviews.bulkActions")
  }
}
