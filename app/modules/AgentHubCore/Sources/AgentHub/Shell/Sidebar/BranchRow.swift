//
//  BranchRow.swift
//  AgentHub
//
//  Branch row in the sidebar tree (`.branch-row`): branch icon, mono name
//  that truncates, and the pull request number with its CI state. On hover
//  the number gives way to a "+" that starts a session on this branch. The
//  context menu folds in the workflow actions from the old Workflows view.
//

import AgentHubGitHub
import SwiftUI

struct BranchRow: View, Equatable {
  let model: BranchRowModel
  let sessions: [SessionNode]
  let actions: SidebarTreeActions

  @State private var isHovered = false

  nonisolated static func == (lhs: BranchRow, rhs: BranchRow) -> Bool {
    lhs.model == rhs.model && lhs.sessions == rhs.sessions
  }

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      SidebarIcon(glyph: .branch)
        .foregroundStyle(Color.wbTextTertiary)
        .frame(width: DesignTokens.Size.tile)
      Text(model.name)
        .wbText(.code)
        .foregroundStyle(isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      trailing
    }
    .padding(.leading, DesignTokens.Spacing.smPlus)
    .padding(.trailing, DesignTokens.Spacing.xs)
    .frame(height: DesignTokens.Size.row)
    .contentShape(Rectangle())
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        .fill(isHovered ? Color.wbSurfaceHover : Color.clear)
    )
    .onHover { isHovered = $0 }
    .contextMenu {
      BranchRowMenu(model: model, sessions: sessions, actions: actions)
    }
    .help(model.name)
    .padding(.top, model.isFirstInRepo ? 0 : DesignTokens.Spacing.xs)
  }

  /// The PR badge and the "+" share one slot so the name never reflows.
  @ViewBuilder
  private var trailing: some View {
    if isHovered {
      SidebarRowIconButton(
        glyph: .plus,
        accessibilityLabel: "New session on \(model.name)"
      ) {
        actions.startSession(onBranch: model)
      }
    } else if let pullRequest = model.decoration?.pullRequest {
      BranchPullRequestBadge(pullRequest: pullRequest)
        .padding(.trailing, DesignTokens.Spacing.xsPlus)
    }
  }
}

/// "⎇ 212": the pull request icon tinted by CI state, then the number.
struct BranchPullRequestBadge: View {
  let pullRequest: BranchWorkflowDecoration.PullRequestBadge

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      SidebarIcon(glyph: .pullRequest, size: DesignTokens.Size.iconSmall)
        .foregroundStyle(ciColor)
      Text(verbatim: "\(pullRequest.number)")
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextSecondary)
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Pull request \(pullRequest.number), \(ciWord)")
  }

  private var ciColor: Color {
    switch pullRequest.ciStatus ?? CIStatus.none {
    case .success: return .wbStatusReadyFill
    case .failure: return .wbStatusErrorFill
    case .pending: return .wbStatusWorkingFill
    case .none: return .wbTextSecondary
    }
  }

  private var ciWord: String {
    switch pullRequest.ciStatus ?? CIStatus.none {
    case .success: return "checks passed"
    case .failure: return "checks failed"
    case .pending: return "checks running"
    case .none: return "no checks"
    }
  }
}

/// A 24 pt icon-only button for tree rows (`.icon-button-small`).
struct SidebarRowIconButton: View {
  let glyph: SidebarGlyph
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      SidebarIcon(glyph: glyph)
        .frame(width: DesignTokens.Size.controlSmall, height: DesignTokens.Size.controlSmall)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.wbTextPrimary)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.segment, style: .continuous)
        .fill(isHovered ? Color.wbSurfaceHover : Color.clear)
    )
    .onHover { isHovered = $0 }
    .help(accessibilityLabel)
    .accessibilityLabel(accessibilityLabel)
  }
}

// MARK: - Context menu

private struct BranchRowMenu: View {
  let model: BranchRowModel
  let sessions: [SessionNode]
  let actions: SidebarTreeActions

  var body: some View {
    Button("New Session on This Branch", systemImage: "plus") {
      actions.startSession(onBranch: model)
    }
    if let decoration = model.decoration {
      workflowItems(decoration)
    }
    Divider()
    if let worktreePath = model.worktreePath {
      Button("Open in Finder", systemImage: "folder") { actions.openInFinder(path: worktreePath) }
    }
    if !sessions.isEmpty {
      Button("Archive Sessions", systemImage: "archivebox") {
        actions.archiveSessions(sessions, groupName: model.name)
      }
    }
    if model.isWorktree {
      Button("Remove from Workbench…", systemImage: "xmark") {
        actions.requestRemoveWorktree(model, sessions: sessions)
      }
      Button("Delete Worktree…", systemImage: "trash", role: .destructive) {
        actions.requestDeleteWorktree(model, sessions: sessions)
      }
    }
  }

  @ViewBuilder
  private func workflowItems(_ decoration: BranchWorkflowDecoration) -> some View {
    Divider()
    if let provider = decoration.reviewProvider {
      Button("Start Review with \(provider.rawValue)", systemImage: "checkmark.bubble") {
        actions.startReview(decoration)
      }
    }
    if decoration.canCompare {
      Button("Compare Implementation and Review", systemImage: "rectangle.split.2x1") {
        actions.compare(decoration)
      }
    }
    if decoration.pullRequest != nil {
      Button("Open Pull Request", systemImage: "arrow.up.right.square") {
        actions.openPullRequest(decoration)
      }
    }
    if decoration.ticketKey != nil {
      Button("Open Ticket", systemImage: "ticket") { actions.openTicket(decoration) }
    }
    if decoration.archivableWorkflowID != nil {
      Button("Archive Workflow", systemImage: "archivebox") { actions.archiveWorkflow(decoration) }
    }
  }
}
