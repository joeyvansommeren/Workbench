//
//  SidebarFooter.swift
//  AgentHub
//
//  Bottom of the sidebar (`.sidebar-footer`): a hairline, then Open project,
//  which adds a repository through the existing folder picker.
//

import SwiftUI

struct SidebarFooter: View {
  let openProject: () -> Void

  @State private var isHovered = false

  var body: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(Color.wbBorderHairline)
        .frame(height: 1)
      Button(action: openProject) {
        HStack(spacing: DesignTokens.Spacing.smPlus) {
          SidebarIcon(glyph: .folderPlus)
            .frame(width: DesignTokens.Size.tile)
          Text("Open project")
            .wbText(.body)
          Spacer(minLength: 0)
        }
        .foregroundStyle(isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
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
      .padding(.top, DesignTokens.Spacing.sm)
      .padding(.horizontal, DesignTokens.Inset.sidebar)
    }
  }
}
