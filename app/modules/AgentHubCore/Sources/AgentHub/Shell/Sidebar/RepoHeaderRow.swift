//
//  RepoHeaderRow.swift
//  AgentHub
//
//  Repository header in the sidebar tree (`.repo-header`): letter tile, name,
//  a chevron that turns when collapsed, and the attention count while
//  collapsed. The context menu carries the legacy project header's actions.
//

import SwiftUI

struct RepoHeaderRow: View, Equatable {
  let model: RepoHeaderRowModel
  /// Sessions under this repository, for "Archive Sessions" and the removal text.
  let sessions: [SessionNode]
  let actions: SidebarTreeActions

  @State private var isHovered = false

  nonisolated static func == (lhs: RepoHeaderRow, rhs: RepoHeaderRow) -> Bool {
    lhs.model == rhs.model && lhs.sessions == rhs.sessions
  }

  var body: some View {
    Button {
      actions.setRepository(model, collapsed: !model.isCollapsed)
    } label: {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        LetterTile(name: model.name, path: model.path)
          .frame(width: DesignTokens.Size.tile)
        Text(model.name)
          .wbText(.headline)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        SidebarIcon(glyph: .chevronDown, size: DesignTokens.Size.iconSmall)
          .foregroundStyle(Color.wbTextSecondary)
          .rotationEffect(.degrees(model.isCollapsed ? -90 : 0))
          .animation(.wbAnimation(DesignTokens.Motion.medium), value: model.isCollapsed)
          .padding(.leading, -DesignTokens.Spacing.xsPlus)
        Spacer(minLength: 0)
        if model.isCollapsed, model.attentionCount > 0 {
          SidebarAttentionCount(count: model.attentionCount)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(height: DesignTokens.Size.row)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        .fill(isHovered ? Color.wbSurfaceHover : Color.clear)
    )
    .onHover { isHovered = $0 }
    .contextMenu { menu }
    .accessibilityAddTraits(.isHeader)
    .accessibilityValue(model.isCollapsed ? "Collapsed" : "Expanded")
    .padding(.top, model.isFirst ? 0 : DesignTokens.Spacing.xl)
  }

  @ViewBuilder
  private var menu: some View {
    Button("New Session", systemImage: "plus") { actions.startSession(at: model.path) }
    Button("New Worktree…", systemImage: "arrow.triangle.branch") {
      actions.createWorktree(repositoryPath: model.path)
    }
    Button("New Workspace", systemImage: "rectangle.3.group") {
      actions.createWorkspace(projectPath: model.path)
    }
    Button("Project Details", systemImage: "info.circle") {
      actions.showProjectDetails(path: model.path, name: model.name)
    }
    Divider()
    Button("Open in Finder", systemImage: "folder") { actions.openInFinder(path: model.path) }
    Button("GitHub", systemImage: "link") { actions.showGitHub(path: model.path) }
    Divider()
    if !sessions.isEmpty {
      Button("Archive Sessions", systemImage: "archivebox") {
        actions.archiveSessions(sessions, groupName: model.name)
      }
    }
    Button("Remove…", systemImage: "xmark") {
      actions.requestRemoveRepository(path: model.path, name: model.name, sessionCount: sessions.count)
    }
  }
}

/// Count of sessions needing attention, shown on a collapsed repository.
struct SidebarAttentionCount: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(Color.wbStatusAttentionText)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .frame(minWidth: DesignTokens.Size.tile, minHeight: DesignTokens.Size.tile)
      .background(Color.wbStatusAttentionTint, in: Capsule())
      .fixedSize()
      .accessibilityLabel("\(count) need attention")
  }
}
