//
//  LoadMoreRow.swift
//  AgentHub
//
//  "Load more" under a branch with older sessions (`.load-more`). Each click
//  shows `SessionTreeProjection.loadMoreIncrement` (5) more.
//

import SwiftUI

struct LoadMoreRow: View, Equatable {
  let model: LoadMoreRowModel
  let action: () -> Void

  @State private var isHovered = false

  nonisolated static func == (lhs: LoadMoreRow, rhs: LoadMoreRow) -> Bool {
    lhs.model == rhs.model
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        Color.clear.frame(width: DesignTokens.Size.tile, height: 1)
        Text("Load more")
          .wbText(.body)
          .foregroundStyle(isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
        Spacer(minLength: 0)
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
    .padding(.top, DesignTokens.Spacing.xs)
    .accessibilityLabel("Load more sessions")
  }
}
