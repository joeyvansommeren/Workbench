//
//  PullRequestDetailView.swift
//  AgentHub
//
//  The detail column of the new shell's Reviews view (`.pr-detail` in the
//  prototype): title, byline, "Review with <agent>" and "Open on GitHub",
//  the property card (Checks, Changes, Reviewers, Ticket, Session) and the
//  Markdown description. The whole column scrolls, so long bodies scroll.
//

import AgentHubGitHub
import AppKit
import MarkdownUI
import SwiftUI

/// What the "Review with <agent>" split button needs from its host.
struct PullRequestReviewControl {
  var agent: SessionProviderKind
  let templates: [GitHubPromptTemplate]
  let isStarting: Bool
  let isAgentAvailable: (SessionProviderKind) -> Bool
  let onSelectAgent: (SessionProviderKind) -> Void
  let onReview: (SessionProviderKind, GitHubPromptTemplate) -> Void
  let onWriteOwnMessage: (SessionProviderKind) -> Void

  /// The prompt the primary button runs: the built-in independent review.
  var primaryTemplate: GitHubPromptTemplate? {
    templates.first { $0.builtInKind == .independentReview } ?? templates.first
  }

  static func displayName(_ agent: SessionProviderKind) -> String {
    switch agent {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    }
  }
}

struct PullRequestDetailView: View {
  let pullRequest: GitHubProjectPullRequest
  let detail: GitHubReviewDetail?
  let isLoadingDetail: Bool
  let detailError: String?
  let tileColor: RepositoryTileColor
  let viewerLogin: String?
  let sessionLink: GitHubReviewSessionLink?
  let review: PullRequestReviewControl
  let onOpenSession: (GitHubReviewSessionLink) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
        header
        actions
        if let detailError {
          ErrorBanner(detailError)
        }
        properties
        description
      }
      .padding(.top, DesignTokens.Spacing.xxl)
      .padding(.horizontal, DesignTokens.Spacing.xxxl)
      .padding(.bottom, DesignTokens.Spacing.xxxl)
      // 680 includes the padding, as `.pr-detail-inner` (border-box) does.
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("reviews.detail")
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(pullRequest.title)
        .wbText(.title2)
        .foregroundStyle(Color.wbTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      byline
    }
  }

  private var byline: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      LetterTile(letter: pullRequest.repositoryName.first ?? "?", color: tileColor)
      // Verbatim: a localized key would group the number ("#1.843").
      Text(verbatim: "\(pullRequest.repositoryName) #\(pullRequest.number)")
        .wbText(.codeSmall)
        .fixedSize()
      separator
      Text(pullRequest.authorLogin ?? "unknown")
        .wbText(.callout)
        .lineLimit(1)
      if let detail {
        separator
        Text(verbatim: "\(detail.pullRequest.headRefName) → \(detail.pullRequest.baseRefName)")
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .foregroundStyle(Color.wbTextSecondary)
  }

  private var separator: some View {
    Text("·").wbText(.callout)
  }

  // MARK: - Actions

  private var actions: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      reviewButton
      Button {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
      } label: {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          Text("Open on GitHub")
          Image(systemName: "arrow.up.right")
            .font(.system(size: 10, weight: .semibold))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.wbPlain)
      .fixedSize()
      .accessibilityIdentifier("reviews.openOnGitHub")
    }
  }

  private var reviewButton: some View {
    let agent = review.agent
    let isAvailable = review.isAgentAvailable(agent)
    let title =
      review.isStarting ? "Starting…" : "Review with \(PullRequestReviewControl.displayName(agent))"
    return SplitButton(title, accessibilityIdentifier: "reviews.startReview") {
      guard isAvailable, !review.isStarting, let template = review.primaryTemplate else { return }
      review.onReview(agent, template)
    } menu: {
      reviewMenu
    }
    .fixedSize()
    .disabled(review.isStarting)
    .opacity(isAvailable && !review.isStarting ? 1 : 0.55)
    .help(isAvailable ? "Start an independent review session" : agent.notInstalledHelp)
  }

  @ViewBuilder
  private var reviewMenu: some View {
    Section("Agent") {
      ForEach(SessionProviderKind.allCases, id: \.self) { agent in
        Toggle(
          PullRequestReviewControl.displayName(agent),
          isOn: Binding(
            get: { review.agent == agent },
            set: { if $0 { review.onSelectAgent(agent) } }
          )
        )
        .disabled(!review.isAgentAvailable(agent))
      }
    }
    Section("Prompt") {
      ForEach(review.templates) { template in
        Button(template.name) { review.onReview(review.agent, template) }
      }
      .disabled(!review.isAgentAvailable(review.agent))
      Button("Write Your Own Message…") { review.onWriteOwnMessage(review.agent) }
        .disabled(!review.isAgentAvailable(review.agent))
    }
  }

  // MARK: - Properties

  private var properties: some View {
    PropertyCard {
      PropertyRow("Checks", systemImage: "checkmark.circle") { checksValue }
      PropertyRow("Changes", systemImage: "plusminus") { changesValue }
      PropertyRow("Reviewers", systemImage: "person") { reviewersValue }
      if let ticketKey {
        PropertyRow("Ticket", systemImage: "ticket") {
          Text(ticketKey)
            .wbText(.code)
            .foregroundStyle(Color.wbTextPrimary)
            .textSelection(.enabled)
        }
      }
      PropertyRow("Session", systemImage: "apple.terminal", showsDivider: false) { sessionValue }
    }
  }

  @ViewBuilder
  private var checksValue: some View {
    if let detail {
      let summary = PullRequestChecksSummary(checks: detail.pullRequest.statusCheckRollup)
      Text(summary.text)
        .fontWeight(summary.state == nil ? .regular : .medium)
        .foregroundStyle(checksColor(summary.state))
    } else {
      placeholderValue
    }
  }

  private func checksColor(_ state: PullRequestChecksState?) -> Color {
    switch state {
    case .pass: return .wbStatusReadyText
    case .fail: return .wbStatusErrorText
    case .pending, nil: return .wbTextSecondary
    }
  }

  @ViewBuilder
  private var changesValue: some View {
    if let detail {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        Text(verbatim: "+\(detail.pullRequest.additions)").foregroundStyle(Color.wbDiffAddedText)
        Text(verbatim: "−\(detail.pullRequest.deletions)").foregroundStyle(Color.wbDiffRemovedText)
        let files = detail.pullRequest.changedFiles
        Text("· \(files) \(files == 1 ? "file" : "files")")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      }
      .wbText(.codeSmall)
      .monospacedDigit()
    } else {
      placeholderValue
    }
  }

  @ViewBuilder
  private var reviewersValue: some View {
    if detail != nil {
      let logins = reviewerLogins
      if logins.isEmpty {
        Text("None").foregroundStyle(Color.wbTextSecondary)
      } else {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          ForEach(logins.prefix(3), id: \.self) { login in
            PersonChip(initials: login, name: isViewer(login) ? "You" : login)
          }
          if logins.count > 3 {
            Text("+\(logins.count - 3)").foregroundStyle(Color.wbTextSecondary)
          }
        }
      }
    } else {
      placeholderValue
    }
  }

  @ViewBuilder
  private var sessionValue: some View {
    if let sessionLink {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Button {
          onOpenSession(sessionLink)
        } label: {
          Text(sessionLink.displayName)
            .foregroundStyle(Color.wbAccentText)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the session")
        StatusChip(status: sessionLink.status, isPending: sessionLink.isPending)
          .fixedSize()
      }
    } else {
      Text("None").foregroundStyle(Color.wbTextSecondary)
    }
  }

  private var placeholderValue: some View {
    Text(isLoadingDetail ? "Loading…" : "—").foregroundStyle(Color.wbTextTertiary)
  }

  // MARK: - Description

  private var description: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Description")
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if let body = detail?.pullRequest.body?.trimmingCharacters(in: .whitespacesAndNewlines),
        !body.isEmpty
      {
        Markdown(body)
          .markdownTheme(.pullRequestDescription)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Text(detail == nil && isLoadingDetail ? "Loading…" : "No description.")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      }
    }
  }

  // MARK: - Derived values

  /// Requested reviewers first, then people who already reviewed; never the author.
  private var reviewerLogins: [String] {
    guard let detail else { return [] }
    let requested = (detail.pullRequest.reviewRequests ?? []).compactMap { $0.login ?? $0.slug }
    let reviewed = detail.reviews.compactMap { $0.author?.login }
    var seen = Set<String>()
    return (requested + reviewed).filter { login in
      guard login.caseInsensitiveCompare(pullRequest.authorLogin ?? "") != .orderedSame else {
        return false
      }
      return seen.insert(login.lowercased()).inserted
    }
  }

  private func isViewer(_ login: String) -> Bool {
    guard let viewerLogin else { return false }
    return login.caseInsensitiveCompare(viewerLogin) == .orderedSame
  }

  private var ticketKey: String? {
    GitHubReviewSessionLinker.ticketKeys(inTitle: pullRequest.title).sorted().first
      ?? detail.flatMap {
        GitHubReviewSessionLinker.ticketKeys(inTitle: $0.pullRequest.headRefName).sorted().first
      }
  }
}

extension MarkdownUI.Theme {
  /// Pull request bodies in the new shell: Inter Display 13 on the text
  /// tokens, Geist Mono for code. Computed, not stored, so a live palette
  /// switch picks up the new colours.
  @MainActor static var pullRequestDescription: Theme {
    Theme.basic
      .text {
        FontFamily(.custom(WorkbenchTypography.InterDisplay.regular))
        FontSize(13)
        ForegroundColor(Color.wbTextPrimary)
      }
      .code {
        FontFamily(.custom(DesignTokens.Typography.geistMonoRegular))
        FontSize(12)
      }
      .link {
        ForegroundColor(Color.wbAccentText)
      }
  }
}
