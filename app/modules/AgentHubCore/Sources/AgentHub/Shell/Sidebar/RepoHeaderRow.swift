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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
          .fontWeight(colorScheme == .dark ? .medium : .semibold)
          .foregroundStyle(
            colorScheme == .dark && colorSchemeContrast != .increased
              ? Color.wbTextSecondary : Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        SidebarIcon(glyph: .chevronDown, size: DesignTokens.Size.iconSmall)
          .foregroundStyle(Color.wbTextSecondary)
          .rotationEffect(.degrees(model.isCollapsed ? -90 : 0))
          // Fast, so the indicator does not lag the rows, which snap.
          .animation(.wbAnimation(DesignTokens.Motion.fast), value: model.isCollapsed)
          .padding(.leading, -DesignTokens.Spacing.xsPlus)
        Spacer(minLength: 0)
        if model.isCollapsed, model.attentionCount > 0 {
          CountBadge(model.attentionCount, style: .attention)
            .accessibilityLabel("\(model.attentionCount) need attention")
        }
      }
      .padding(.leading, SidebarTreeInset.repository)
      .padding(.trailing, DesignTokens.Spacing.smPlus)
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

  private var menu: some View {
    SidebarMenuCommands(
      entries: repositoryMenuEntries(model: model, sessions: sessions, actions: actions))
  }
}
