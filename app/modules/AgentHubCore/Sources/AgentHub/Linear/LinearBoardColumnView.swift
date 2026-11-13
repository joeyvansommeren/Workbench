//
//  LinearBoardColumnView.swift
//  AgentHub
//
//  One workflow state column of the Linear board and its issue cards.
//

import AgentWorkflowLinear
import AppKit
import SwiftUI

struct LinearBoardColumnView: View {
  let column: LinearViewModel.BoardColumn
  let selectedIssueID: String?
  let canStart: Bool
  var isClaudeAvailable: Bool = true
  var isCodexAvailable: Bool = true
  let linkedSessions: [String: [LinearLinkedSession]]
  let onOpen: (LinearIssue) -> Void
  let onOpenSession: (LinearLinkedSession) -> Void
  let onStart: (LinearIssue, SessionProviderKind) -> Void

  @Environment(\.runtimeTheme) private var runtimeTheme

  static let width: CGFloat = 280

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      header
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          LazyVStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(column.issues) { issue in
              LinearIssueCard(
                issue: issue,
                isSelected: issue.id == selectedIssueID,
                isDone: column.state.type == "completed",
                sessions: linkedSessions[issue.identifier] ?? [],
                onOpenSession: onOpenSession
              )
              .onTapGesture { onOpen(issue) }
              .accessibilityAddTraits(.isButton)
              .accessibilityAction { onOpen(issue) }
              .id(issue.id)
              .contextMenu { contextMenu(for: issue) }
            }
            if column.issues.isEmpty {
              emptyPlaceholder
            }
          }
          .padding(.horizontal, DesignTokens.Spacing.sm)
          .padding(.bottom, DesignTokens.Spacing.sm)
        }
        .scrollIndicators(.never)
        .onChange(of: selectedIssueID) { _, id in
          guard let id, column.issues.contains(where: { $0.id == id }) else { return }
          withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
        }
      }
    }
    .frame(width: Self.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
        .fill(Color.primary.opacity(0.025))
    )
  }

  private var header: some View {
    HStack(spacing: 6) {
      LinearStateIcon(stateType: column.state.type, size: 10)
      Text(column.state.name.uppercased())
        .font(.secondaryCaption)
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text("\(column.issues.count)")
        .font(.secondaryCaption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 16)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
      Spacer()
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.top, DesignTokens.Spacing.md)
  }

  private var emptyPlaceholder: some View {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
      .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
      .frame(height: 64)
      .overlay(
        Text("No issues")
          .font(.secondarySmall)
          .foregroundStyle(.tertiary)
      )
  }

  @ViewBuilder
  private func contextMenu(for issue: LinearIssue) -> some View {
    Button("Open Details") { onOpen(issue) }
    Divider()
    Button("Pick Up with Claude") { onStart(issue, .claude) }
      .disabled(!canStart || !isClaudeAvailable)
      .help(isClaudeAvailable ? "" : "Claude Code is not installed")
    Button("Pick Up with Codex") { onStart(issue, .codex) }
      .disabled(!canStart || !isCodexAvailable)
      .help(isCodexAvailable ? "" : "Codex is not installed")
    Divider()
    if let url = URL(string: issue.url) {
      Button("Open in Linear") { NSWorkspace.shared.open(url) }
    }
    Button("Copy Identifier") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(issue.identifier, forType: .string)
    }
  }
}

// MARK: - LinearIssueCard

struct LinearIssueCard: View {
  let issue: LinearIssue
  let isSelected: Bool
  let isDone: Bool
  var sessions: [LinearLinkedSession] = []
  var onOpenSession: (LinearLinkedSession) -> Void = { _ in }

  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text(issue.title)
        .font(.secondaryDefault)
        .foregroundStyle(isDone ? .secondary : .primary)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 6) {
        LinearStateIcon(stateType: issue.state.type, size: 10)
        Text(issue.identifier)
          .font(.primarySmall)
          .foregroundStyle(.secondary)
          .strikethrough(isDone, color: .secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if !sessions.isEmpty {
          LinearSessionBadge(sessions: sessions, onOpen: onOpenSession)
        }
        LinearPriorityIcon(priority: issue.priority)
        LinearAvatar(
          name: issue.assignee?.name,
          url: issue.assignee?.avatarUrl.flatMap(URL.init(string:))
        )
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .strokeBorder(borderColor, lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(issue.identifier): \(issue.title)")
  }

  private var backgroundColor: Color {
    if isSelected { return Color.brandPrimary(from: runtimeTheme).opacity(0.12) }
    return isHovered ? Color.primary.opacity(0.075) : Color.primary.opacity(0.045)
  }

  private var borderColor: Color {
    if isSelected { return Color.brandPrimary(from: runtimeTheme).opacity(0.75) }
    return Color.primary.opacity(isHovered ? 0.16 : 0.07)
  }
}

// MARK: - LinearSessionBadge

struct LinearSessionBadge: View {
  let sessions: [LinearLinkedSession]
  let onOpen: (LinearLinkedSession) -> Void

  @State private var isHovered = false

  var body: some View {
    Group {
      if sessions.count == 1, let session = sessions.first {
        Button { onOpen(session) } label: { label }
          .buttonStyle(.plain)
          .disabled(session.isPending)
          .help(session.isPending ? "Session is starting" : "Open session: \(session.title)")
      } else {
        Menu {
          ForEach(sessions) { session in
            Button("\(session.provider.rawValue) \u{00B7} \(session.title)") { onOpen(session) }
              .disabled(session.isPending)
          }
        } label: {
          label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(sessions.count) agent sessions work on this issue")
      }
    }
    .onHover { isHovered = $0 }
    .accessibilityLabel(
      sessions.count == 1 ? "Open linked session" : "Open one of \(sessions.count) linked sessions")
  }

  private var label: some View {
    let providers = Array(Set(sessions.map(\.provider))).sorted { $0.rawValue < $1.rawValue }
    return HStack(spacing: 4) {
      HStack(spacing: -3) {
        ForEach(providers, id: \.self) { provider in
          Circle()
            .fill(Color.brandPrimary(for: provider))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.surfaceCard, lineWidth: 1.5))
        }
      }
      Image(systemName: "terminal")
        .font(.system(size: 9, weight: .semibold))
      Text(verbatim: "\(sessions.count)")
        .font(.secondaryCaption)
    }
    .foregroundStyle(isHovered ? .primary : .secondary)
    .padding(.horizontal, 6)
    .frame(height: 18)
    .background(Capsule().fill(Color.primary.opacity(isHovered ? 0.12 : 0.07)))
    .contentShape(Capsule())
  }
}
