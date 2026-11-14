//
//  TicketDetailView.swift
//  AgentHub
//
//  The shell's ticket detail: the 380 pt trailing panel of the Jira and
//  Linear destinations (`SprintDestinationLayout`). One view for both
//  trackers; `TicketDetailPresentation` maps a Jira ticket or a Linear issue
//  to `SprintTicketDetail`. Same structure as the Reviews detail: a header bar
//  (key, close), title and tags, "Start session" and "Open in …", a property
//  card, linked sessions and pull requests, then the description.
//  The legacy `JiraTicketDetailView` / `LinearIssueDetailView` stay for the
//  flag-off path.
//

import AppKit
import MarkdownUI
import SwiftUI

/// What the detail can do. The host owns every side effect.
struct TicketDetailActions {
  /// Nil: the preferred agent (Claude Code when installed, else Codex).
  var onStart: (SessionProviderKind?) -> Void
  /// A session row's id (`SprintDetailSessionRow.id`).
  var onOpenSession: (String) -> Void
  /// A column id from `SprintDetailStatus.moveTargets`.
  var onMove: (String) -> Void
  var onRefreshPullRequests: () -> Void
  var onClose: () -> Void
}

struct TicketDetailView: View {
  let detail: SprintTicketDetail
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]
  let isStarting: Bool
  let isClaudeAvailable: Bool
  let isCodexAvailable: Bool
  let actions: TicketDetailActions

  var body: some View {
    VStack(spacing: 0) {
      panelHeader
      Color.wbBorderHairline.frame(height: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
          header
          startActions
          properties
          if !detail.sessions.isEmpty {
            TicketDetailSessionsSection(rows: detail.sessions, onOpen: actions.onOpenSession)
          }
          if let pullRequests = detail.pullRequests {
            TicketDetailPullRequestsSection(
              section: pullRequests, onRefresh: actions.onRefreshPullRequests)
          }
          TicketDetailDescription(
            markdown: detail.descriptionMarkdown, isLoading: detail.isLoadingDetail)
            // "Show all" is per ticket.
            .id(detail.id)
        }
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(Color.wbSurfaceContent)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(detail.key) details")
    .accessibilityIdentifier("sprint.detail")
  }

  // MARK: - Panel header

  private var panelHeader: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Text(detail.key)
        .wbText(.code)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .textSelection(.enabled)
      Spacer(minLength: DesignTokens.Spacing.sm)
      IconButton(
        systemImage: "xmark", isSmall: true,
        accessibilityLabel: "Close \(detail.key) details",
        accessibilityIdentifier: "sprint.detail.close", action: actions.onClose)
      .help("Close (Esc)")
      .keyboardShortcut(.cancelAction)
    }
    .padding(.leading, DesignTokens.Spacing.xl)
    .padding(.trailing, DesignTokens.Spacing.md)
    // The list head's height, so the key sits level with the sprint name.
    .frame(height: 56)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.smPlus) {
      Text(detail.title)
        .wbText(.title2)
        .foregroundStyle(Color.wbTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      TicketTagFlow(spacing: DesignTokens.Spacing.xsPlus) {
        if let status = detail.status {
          TicketStatusChip(status: status, key: detail.key, onMove: actions.onMove)
        }
        ForEach(detail.tags) { TicketTagChip(tag: $0) }
      }
    }
  }

  // MARK: - Start and open

  private var start: SprintDetailStart {
    SprintDetailStart.make(
      hasProject: repositoryPath != nil, isStarting: isStarting,
      isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable)
  }

  private var startActions: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        startButton
        if let url = detail.browseURL {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            HStack(spacing: DesignTokens.Spacing.xsPlus) {
              Text("Open in \(detail.trackerName)")
              Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.wbPlain)
          .fixedSize()
          .accessibilityIdentifier("sprint.detail.openInTracker")
        }
      }
      if let hint = start.hint {
        Text(hint)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
    }
  }

  private var startButton: some View {
    let start = start
    return SplitButton(
      accessibilityIdentifier: "sprint.detail.start",
      isPrimaryEnabled: start.isPrimaryEnabled,
      menuAccessibilityLabel: "Choose agent",
      primaryAccessibilityLabel: start.isStarting ? "Starting session" : "Start session",
      action: { actions.onStart(nil) },
      label: {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          if start.isStarting {
            ProgressView()
              .controlSize(.mini)
              .frame(width: 12, height: 12)
          }
          Text(start.title)
        }
      },
      menu: {
        agentItem(.claude, title: "Start with Claude Code")
        agentItem(.codex, title: "Start with Codex")
      }
    )
    .disabled(start.isStarting)
    .fixedSize()
  }

  private func agentItem(_ provider: SessionProviderKind, title: String) -> some View {
    let isAvailable = provider == .claude ? isClaudeAvailable : isCodexAvailable
    return Button(isAvailable ? title : "\(title) (not installed)") { actions.onStart(provider) }
      .disabled(
        !SprintDetailStart.canStart(
          provider, hasProject: repositoryPath != nil, isStarting: isStarting,
          isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable))
  }

  // MARK: - Properties

  private var properties: some View {
    PropertyCard {
      PropertyRow("Assignee", systemImage: "person") { assigneeValue }
      if let iteration = detail.iterationName {
        PropertyRow(detail.iterationLabel, systemImage: "calendar") {
          Text(iteration)
            .foregroundStyle(Color.wbTextPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      PropertyRow("Project", systemImage: "folder", showsDivider: false) {
        TicketProjectMenu(repositoryPath: $repositoryPath, repositories: repositories)
      }
    }
  }

  @ViewBuilder
  private var assigneeValue: some View {
    if let name = detail.assigneeName {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        if let initials = detail.assigneeInitials {
          WBAvatar(initials: initials)
        }
        Text(name)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    } else {
      Text("Unassigned").foregroundStyle(Color.wbTextSecondary)
    }
  }
}

// MARK: - Status chip

/// The status as a chip. Where the tracker can move tickets it is a menu with
/// the other columns ("Move To", as on the card's context menu).
private struct TicketStatusChip: View {
  let status: SprintDetailStatus
  let key: String
  let onMove: (String) -> Void

  var body: some View {
    if status.moveTargets.isEmpty {
      chip(showsChevron: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(status.name)")
    } else {
      Menu {
        Section("Move To") {
          ForEach(status.moveTargets) { target in
            Button(target.title) {
              onMove(target.id)
              MainThreadStallMonitor.breadcrumb("sprint ticket: move \(key)")
            }
          }
        }
      } label: {
        chip(showsChevron: true)
          .contentShape(Capsule())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Move \(key) to another status")
      .accessibilityLabel("Status: \(status.name). Move to another status")
      .accessibilityIdentifier("sprint.detail.status")
    }
  }

  private func chip(showsChevron: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Text(status.name)
        .lineLimit(1)
      if showsChevron {
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
      }
    }
    .wbText(.subheadline)
    .fontWeight(.medium)
    .foregroundStyle(status.tone.textColor)
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: 20)
    .background(status.tone.tintColor, in: Capsule())
  }
}

/// A priority, type or label tag (`ReviewsTagChip` look). Linear labels keep
/// their colour as a dot; the text says the rest.
private struct TicketTagChip: View {
  let tag: SprintDetailTag

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      if let color = labelColor {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)
      }
      Text(tag.text)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .wbText(.subheadline)
    .fontWeight(.medium)
    .foregroundStyle(tag.tone.textColor)
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: 20)
    .background(tag.tone.tintColor, in: Capsule())
    .help(tag.accessibilityLabel)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tag.accessibilityLabel)
  }

  /// The failable `Color(hex:)` from LinearVisuals: nil for a malformed colour.
  private var labelColor: Color? {
    guard let hex = tag.colorHex else { return nil }
    let color: Color? = Color(hex: hex)
    return color
  }
}

@MainActor
extension SprintDetailTone {
  var textColor: Color {
    switch self {
    case .neutral: return .wbTextSecondary
    case .working: return .wbStatusWorkingText
    case .ready: return .wbStatusReadyText
    case .attention: return .wbStatusAttentionText
    case .error: return .wbStatusErrorText
    }
  }

  var tintColor: Color {
    switch self {
    case .neutral: return .wbSurfaceField
    case .working: return .wbStatusWorkingTint
    case .ready: return .wbStatusReadyTint
    case .attention: return .wbStatusAttentionTint
    case .error: return .wbStatusErrorTint
    }
  }
}

/// Tags wrap onto more lines instead of truncating in the narrow panel.
/// A plain `Layout`: it reads only the proposed width, never writes state.
private struct TicketTagFlow: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        let width = min(size.width, bounds.width)
        subviews[index].place(
          at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
        x += width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let itemWidth = min(size.width, width)
      let needed = row.indices.isEmpty ? itemWidth : row.width + spacing + itemWidth
      if needed > width, !row.indices.isEmpty {
        rows.append(row)
        row = Row()
      }
      row.width = row.indices.isEmpty ? itemWidth : row.width + spacing + itemWidth
      row.height = max(row.height, size.height)
      row.indices.append(index)
    }
    if !row.indices.isEmpty { rows.append(row) }
    return rows
  }
}

// MARK: - Project

/// The project a new session starts in (the legacy "Choose repository").
private struct TicketProjectMenu: View {
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]

  var body: some View {
    Menu {
      ForEach(repositories) { repository in
        Button(repository.name) {
          repositoryPath = repository.path
          MainThreadStallMonitor.breadcrumb("sprint ticket: project")
        }
      }
      if repositories.isEmpty {
        Text("Add a repository in Sessions first")
      }
    } label: {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Text(selectedName ?? "Choose…")
          .foregroundStyle(selectedName == nil ? Color.wbAccentText : Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.wbTextSecondary)
      }
      .frame(minHeight: DesignTokens.Size.controlSmall)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(repositoryPath ?? "Choose the project a session starts in")
    .accessibilityLabel("Project: \(selectedName ?? "none")")
    .accessibilityIdentifier("sprint.detail.project")
  }

  private var selectedName: String? {
    guard let repositoryPath else { return nil }
    return repositories.first { $0.path == repositoryPath }?.name
      ?? URL(fileURLWithPath: repositoryPath).lastPathComponent
  }
}

// MARK: - Sections

/// A section title with its count (`Checks 3` in Reviews).
private struct TicketDetailSectionTitle<Trailing: View>: View {
  let title: String
  let count: Int?
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if let count {
        Text(verbatim: "\(count)")
          .wbText(.body)
          .monospacedDigit()
          .foregroundStyle(Color.wbTextSecondary)
      }
      Spacer(minLength: 0)
      trailing
    }
    .frame(minHeight: DesignTokens.Size.controlSmall)
  }
}

private struct TicketDetailSessionsSection: View {
  let rows: [SprintDetailSessionRow]
  let onOpen: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      TicketDetailSectionTitle(title: "Sessions", count: rows.count) { EmptyView() }
      VStack(spacing: 0) {
        ForEach(rows) { row in
          TicketDetailSessionRowView(row: row) { onOpen(row.id) }
          if row.id != rows.last?.id {
            Color.wbBorderHairline.frame(height: 1)
          }
        }
      }
    }
  }
}

private struct TicketDetailSessionRowView: View {
  let row: SprintDetailSessionRow
  let onOpen: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
        StatusGlyph(presentation: row.presentation)
          .fixedSize()
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
          HStack(spacing: DesignTokens.Spacing.sm) {
            Text(row.title)
              .wbText(.body)
              .foregroundStyle(Color.wbTextPrimary)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(row.presentation.word)
              .wbText(.callout)
              .foregroundStyle(Color.wbTextSecondary)
              .lineLimit(1)
              .fixedSize()
          }
          Text(row.subtitle)
            .wbText(.callout)
            .foregroundStyle(Color.wbTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .background(
        isHovered && !row.isPending ? Color.wbSurfaceHover : .clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(row.isPending)
    .onHover { isHovered = $0 }
    .help(row.isPending ? "The session is starting" : "Open this session")
    .accessibilityLabel("\(row.title), \(row.presentation.accessibilityLabel)")
    .accessibilityHint(row.isPending ? "" : "Opens the session")
  }
}

private struct TicketDetailPullRequestsSection: View {
  let section: SprintDetailPullRequests
  let onRefresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      TicketDetailSectionTitle(
        title: "Pull requests", count: section.rows.isEmpty ? nil : section.rows.count
      ) {
        if section.isLoading {
          ProgressView()
            .controlSize(.small)
            .frame(width: DesignTokens.Size.controlSmall, height: DesignTokens.Size.controlSmall)
            .accessibilityLabel("Searching GitHub")
        } else {
          IconButton(
            systemImage: "arrow.clockwise", isSmall: true,
            accessibilityLabel: "Search GitHub again",
            accessibilityIdentifier: "sprint.detail.refreshPullRequests", action: onRefresh)
          .help("Search GitHub again")
        }
      }
      if let emptyText = section.emptyText {
        Text(emptyText)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
      VStack(spacing: 0) {
        ForEach(section.rows) { row in
          TicketDetailPullRequestRowView(row: row)
          if row.id != section.rows.last?.id {
            Color.wbBorderHairline.frame(height: 1)
          }
        }
      }
    }
  }
}

private struct TicketDetailPullRequestRowView: View {
  let row: SprintDetailPullRequestRow

  @State private var isHovered = false

  var body: some View {
    Button {
      if let url = row.url { NSWorkspace.shared.open(url) }
    } label: {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
        PullRequestGlyph(size: DesignTokens.Size.iconSmall)
          .foregroundStyle(Color.wbTextSecondary)
          .padding(.top, 3)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
          Text(row.title)
            .wbText(.body)
            .foregroundStyle(Color.wbTextPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          // Verbatim: a PR number never gets a grouping separator.
          Text(verbatim: row.reference)
            .wbText(.codeSmall)
            .foregroundStyle(Color.wbTextSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 0)
        Text(row.stateWord)
          .wbText(.subheadline)
          .fontWeight(.medium)
          .foregroundStyle(row.tone.textColor)
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .frame(height: 20)
          .background(row.tone.tintColor, in: Capsule())
          .fixedSize()
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .background(
        isHovered ? Color.wbSurfaceHover : .clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Open \(row.reference) on GitHub")
    .accessibilityLabel("\(row.title), \(row.reference), \(row.stateWord)")
  }
}

// MARK: - Description

private struct TicketDetailDescription: View {
  let markdown: String?
  let isLoading: Bool

  @State private var showsAll = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Description")
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if let markdown {
        let capped = TicketDetailPresentation.cappedDescription(markdown)
        Markdown(showsAll ? markdown : capped.text)
          .markdownTheme(.pullRequestDescription)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if capped.isCapped {
          Button {
            showsAll.toggle()
          } label: {
            Text(showsAll ? "Show less" : "Show all")
              .wbText(.callout)
              .foregroundStyle(Color.wbAccentText)
              .frame(minHeight: DesignTokens.Size.controlSmall)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sprint.detail.showAllDescription")
        }
      } else if isLoading {
        Text("Loading…")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      } else {
        Text("No description.")
          .wbText(.body)
          .foregroundStyle(Color.wbTextSecondary)
      }
    }
  }
}
