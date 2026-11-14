//
//  PullRequestDetailView.swift
//  AgentHub
//
//  The pull request detail of the new shell's Reviews view: a fixed-width
//  trailing panel next to the table (`.pr-detail` in the prototype). A header
//  bar (refresh, open on GitHub, close), then the title, byline and state
//  chips, "Review with <agent>", the property card (Checks, Changes,
//  Reviewers, Ticket, Sessions), the checks list, the description and the
//  conversation. The panel body scrolls.
//

import AgentHubGitHub
import AppKit
import MarkdownUI
import SwiftUI

/// What the "Review with <agent>" controls need from their host.
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

/// The follow-ups a linked session can get from the detail.
enum PullRequestSessionFollowUp {
  case pullAndReviewAgain
  case sendCommand
}

/// The agent and prompt menu, shared by the detail's split button and the
/// table's per-row "Review" menu.
struct PullRequestReviewMenuItems: View {
  let review: PullRequestReviewControl

  var body: some View {
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
}

struct PullRequestDetailView: View {
  let pullRequest: GitHubProjectPullRequest
  let detail: GitHubReviewDetail?
  let isLoadingDetail: Bool
  let detailError: String?
  let detailUpdatedAt: Date?
  let tileColor: RepositoryTileColor
  let viewerLogin: String?
  let sessionLinks: [GitHubReviewSessionLink]
  let sessionFeedback: String?
  let review: PullRequestReviewControl
  let onOpenSession: (GitHubReviewSessionLink) -> Void
  let onFollowUp: (GitHubReviewSessionLink, PullRequestSessionFollowUp) -> Void
  let onRefresh: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      panelHeader
      Color.wbBorderHairline.frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
          header
          actions
          if let detailError {
            ErrorBanner(detailError)
          }
          properties
          if let detail {
            PullRequestChecksSection(items: PullRequestDetailPresentation.checkItems(detail.pullRequest.statusCheckRollup))
          }
          description
          if let detail {
            PullRequestConversationSection(
              entries: PullRequestDetailPresentation.conversation(detail),
              viewerLogin: viewerLogin
            )
          }
        }
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Color.wbSurfaceContent)
    .accessibilityIdentifier("reviews.detail")
  }

  // MARK: - Panel header

  private var panelHeader: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      if let detailUpdatedAt {
        Text("Refreshed \(detailUpdatedAt.formatted(date: .omitted, time: .shortened))")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: DesignTokens.Spacing.sm)
      if isLoadingDetail {
        ProgressView().controlSize(.small).frame(width: 24, height: 24)
      } else {
        IconButton(
          systemImage: "arrow.clockwise", isSmall: true,
          accessibilityLabel: "Refresh status and comments",
          accessibilityIdentifier: "reviews.detail.refresh", action: onRefresh)
        .help("Refresh status and comments")
      }
      IconButton(
        systemImage: "arrow.up.right.square", isSmall: true,
        accessibilityLabel: "Open on GitHub", action: openOnGitHub)
      .help("Open on GitHub")
      IconButton(
        systemImage: "xmark", isSmall: true,
        accessibilityLabel: "Close pull request details",
        accessibilityIdentifier: "reviews.detail.close", action: onClose)
      .help("Close (Esc)")
    }
    .padding(.leading, DesignTokens.Spacing.xl)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 44)
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
      tags
    }
  }

  /// Two lines in the narrow panel: `repo #number · author`, then the branches.
  private var byline: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        LetterTile(letter: pullRequest.repositoryName.first ?? "?", color: tileColor)
        // Verbatim: a localized key would group the number ("#1.843").
        Text(verbatim: "\(pullRequest.repositoryName) #\(pullRequest.number)")
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("·").wbText(.callout)
        Text(pullRequest.authorLogin ?? "unknown")
          .wbText(.callout)
          .lineLimit(1)
      }
      if let detail {
        Text(verbatim: "\(detail.pullRequest.headRefName) → \(detail.pullRequest.baseRefName)")
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help("\(detail.pullRequest.headRefName) → \(detail.pullRequest.baseRefName)")
      }
    }
    .foregroundStyle(Color.wbTextSecondary)
  }

  private var tags: some View {
    let all = PullRequestDetailPresentation.headerTags(
      detail: detail?.pullRequest, pullRequest: pullRequest)
    // Not fixed-size: with many chips in the narrow panel they truncate
    // instead of widening the column.
    return HStack(spacing: DesignTokens.Spacing.xsPlus) {
      ForEach(all) { ReviewsTagChip(tag: $0) }
    }
  }

  // MARK: - Actions

  private var actions: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      reviewButton
      Button(action: openOnGitHub) {
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

  private func openOnGitHub() {
    guard let url = URL(string: pullRequest.url) else { return }
    NSWorkspace.shared.open(url)
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
      PullRequestReviewMenuItems(review: review)
    }
    .fixedSize()
    .disabled(review.isStarting)
    .opacity(isAvailable && !review.isStarting ? 1 : 0.55)
    .help(isAvailable ? "Start an independent review session" : agent.notInstalledHelp)
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
      PropertyRow(
        sessionLinks.count > 1 ? "Sessions" : "Session", systemImage: "apple.terminal",
        showsDivider: false
      ) { sessionsValue }
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
          ForEach(logins.prefix(2), id: \.self) { login in
            PersonChip(initials: login, name: isViewer(login) ? "You" : login)
              .lineLimit(1)
          }
          if logins.count > 2 {
            Text("+\(logins.count - 2)")
              .foregroundStyle(Color.wbTextSecondary)
              .help(logins.dropFirst(2).joined(separator: ", "))
          }
        }
      }
    } else {
      placeholderValue
    }
  }

  @ViewBuilder
  private var sessionsValue: some View {
    if sessionLinks.isEmpty {
      Text("None").foregroundStyle(Color.wbTextSecondary)
    } else {
      VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xsPlus) {
        ForEach(sessionLinks) { link in
          PullRequestSessionLinkRow(
            link: link,
            onOpen: { onOpenSession(link) },
            onFollowUp: { onFollowUp(link, $0) }
          )
        }
        if let sessionFeedback {
          Text(sessionFeedback)
            .wbText(.callout)
            .foregroundStyle(Color.wbTextSecondary)
        }
      }
      .padding(.vertical, DesignTokens.Spacing.xsPlus)
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

/// One linked session in the property card: name (opens it), status chip and
/// the follow-up menu ("Pull & review again", "Send command…").
private struct PullRequestSessionLinkRow: View {
  let link: GitHubReviewSessionLink
  let onOpen: () -> Void
  let onFollowUp: (PullRequestSessionFollowUp) -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button(action: onOpen) {
        Text(link.displayName)
          .foregroundStyle(Color.wbAccentText)
          .lineLimit(1)
          .truncationMode(.tail)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(link.provider.rawValue) session \(link.displayName)")
      .accessibilityLabel("Open \(link.provider.rawValue) session \(link.displayName)")
      StatusChip(status: link.status, isPending: link.isPending)
        .fixedSize()
      if GitHubReviewSessionCommandPolicy.canSend(isPending: link.isPending) {
        Menu {
          Button("Pull & Review Again") { onFollowUp(.pullAndReviewAgain) }
          Button("Send Command…") { onFollowUp(.sendCommand) }
        } label: {
          Image(systemName: "paperplane")
            .font(.system(size: 11))
            .foregroundStyle(Color.wbTextSecondary)
            .frame(width: DesignTokens.Size.controlSmall, height: DesignTokens.Size.controlSmall)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Send a follow-up command to this session")
        .accessibilityLabel("Send command to \(link.provider.rawValue) session \(link.displayName)")
      }
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
