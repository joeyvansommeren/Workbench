//
//  LinearIssueDetailView.swift
//  AgentHub
//
//  Inspector panel for one Linear issue: details, description, and handing
//  it to an agent.
//

import AgentWorkflowLinear
import AppKit
import SwiftUI

struct LinearIssueDetailView: View {
  let issue: LinearIssue
  let cycleName: String?
  let isLoadingDetail: Bool
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]
  let linkedSessions: [LinearLinkedSession]
  var isClaudeAvailable: Bool = true
  var isCodexAvailable: Bool = true
  let onStart: (SessionProviderKind) -> Void
  let onOpenSession: (LinearLinkedSession) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
          titleBlock
          LinearIssueFields(issue: issue, cycleName: cycleName)
          if !issue.labels.isEmpty {
            labelsBlock
          }
          if !linkedSessions.isEmpty {
            LinearLinkedSessionsSection(sessions: linkedSessions, onOpen: onOpenSession)
          }
          LinearPickUpCard(
            repositoryPath: $repositoryPath,
            repositories: repositories,
            isClaudeAvailable: isClaudeAvailable,
            isCodexAvailable: isCodexAvailable,
            onStart: onStart
          )
          descriptionBlock
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      LinearStateIcon(stateType: issue.state.type, size: 13)
      Text(issue.identifier)
        .font(.primaryDefault)
        .textSelection(.enabled)
        .lineLimit(1)
      Spacer()
      if let url = URL(string: issue.url) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("Open in Linear", systemImage: "arrow.up.right.square")
            .font(.secondaryDefault)
        }
        .buttonStyle(.borderless)
      }
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.cancelAction)
      .help("Close")
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(height: 44)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text(issue.title)
        .font(.secondaryLarge)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      LinearStatePill(state: issue.state.name, stateType: issue.state.type)
    }
  }

  private var labelsBlock: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Labels")
        .font(.heading)
      HStack(spacing: 4) {
        ForEach(issue.labels) { label in
          LinearLabelChip(label: label.name, color: label.color)
        }
      }
    }
  }

  @ViewBuilder
  private var descriptionBlock: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Description")
        .font(.heading)
      if let description = issue.description, !description.isEmpty {
        MarkdownView(content: description, includeScrollView: false)
      } else if isLoadingDetail {
        ProgressView().controlSize(.small)
      } else {
        Text("No description")
          .font(.secondaryDefault)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

// MARK: - LinearIssueFields

private struct LinearIssueFields: View {
  let issue: LinearIssue
  let cycleName: String?

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: DesignTokens.Spacing.lg, verticalSpacing: 10) {
      row("Assignee") {
        HStack(spacing: 6) {
          LinearAvatar(
            name: issue.assignee?.name,
            url: issue.assignee?.avatarUrl.flatMap(URL.init(string:)),
            size: 20
          )
          Text(issue.assignee?.name ?? "Unassigned")
            .foregroundStyle(issue.assignee == nil ? .secondary : .primary)
            .lineLimit(1)
        }
      }
      row("Priority") {
        HStack(spacing: 6) {
          LinearPriorityIcon(priority: issue.priority)
          Text(issue.priorityLabel)
            .lineLimit(1)
        }
      }
      row("State") {
        HStack(spacing: 6) {
          LinearStateIcon(stateType: issue.state.type)
          Text(issue.state.name)
            .lineLimit(1)
        }
      }
      if let cycleName {
        row("Cycle") { Text(cycleName).lineLimit(1) }
      }
    }
    .font(.secondaryDefault)
  }

  private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
        .frame(width: 70, alignment: .leading)
      content()
    }
  }
}

// MARK: - LinearPickUpCard

private struct LinearPickUpCard: View {
  @Binding var repositoryPath: String?
  let repositories: [SelectedRepository]
  var isClaudeAvailable: Bool = true
  var isCodexAvailable: Bool = true
  let onStart: (SessionProviderKind) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack {
        Text("Pick up with an agent")
          .font(.heading)
        Spacer()
        repositoryMenu
      }
      HStack(spacing: DesignTokens.Spacing.sm) {
        providerButton(.claude, title: "Claude")
        providerButton(.codex, title: "Codex")
      }
      if repositoryPath == nil {
        Text("Choose the repository the agent should work in.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04))
    )
  }

  private var repositoryMenu: some View {
    Menu {
      ForEach(repositories) { repository in
        Button(repository.name) { repositoryPath = repository.path }
      }
      if repositories.isEmpty {
        Text("Add a repository in Sessions first")
      }
    } label: {
      Label(selectedRepositoryName ?? "Choose repository", systemImage: "folder")
        .font(.secondaryDefault)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var selectedRepositoryName: String? {
    guard let repositoryPath else { return nil }
    return repositories.first { $0.path == repositoryPath }?.name
      ?? URL(fileURLWithPath: repositoryPath).lastPathComponent
  }

  private func providerButton(_ provider: SessionProviderKind, title: String) -> some View {
    let available = provider == .claude ? isClaudeAvailable : isCodexAvailable
    return Button {
      onStart(provider)
    } label: {
      Label("Start \(title)", systemImage: "play.fill")
    }
    .buttonStyle(ProviderActionButtonStyle(provider: provider))
    .disabled(repositoryPath == nil || !available)
    .help(available ? "" : provider.notInstalledHelp)
  }
}

// MARK: - LinearLinkedSessionsSection

private struct LinearLinkedSessionsSection: View {
  let sessions: [LinearLinkedSession]
  let onOpen: (LinearLinkedSession) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Text("Agent sessions")
        .font(.heading)
      VStack(spacing: 0) {
        ForEach(sessions) { session in
          LinearLinkedSessionRow(session: session) { onOpen(session) }
          if session.id != sessions.last?.id {
            Divider().padding(.leading, 30)
          }
        }
      }
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(Color.primary.opacity(0.04))
      )
    }
  }
}

private struct LinearLinkedSessionRow: View {
  let session: LinearLinkedSession
  let onOpen: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Circle()
          .fill(Color.brandPrimary(for: session.provider))
          .frame(width: 8, height: 8)
          .padding(.leading, 4)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.secondaryDefault)
            .lineLimit(1)
          Text(subtitle)
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if session.isPending {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: "arrow.up.forward.square")
            .foregroundStyle(isHovered ? .primary : .tertiary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(isHovered ? Color.primary.opacity(0.05) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(session.isPending)
    .onHover { isHovered = $0 }
    .help(session.isPending ? "Session is starting" : "Open this session")
  }

  private var subtitle: String {
    var parts = [session.provider.rawValue]
    if let branch = session.branchName { parts.append(branch) }
    parts.append(session.lastActivityAt.formatted(.relative(presentation: .named)))
    if session.isMonitored && !session.isPending { parts.append("open") }
    return parts.joined(separator: " \u{00B7} ")
  }
}
