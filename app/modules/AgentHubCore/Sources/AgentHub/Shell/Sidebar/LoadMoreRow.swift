//
//  LoadMoreRow.swift
//  AgentHub
//
//  "Show older sessions" (`.load-more`) under a branch with older sessions.
//  Each click shows `SessionTreeProjection.loadMoreIncrement` (5) more.
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
        SidebarIcon(glyph: .ellipsis)
          .foregroundStyle(Color.wbTextTertiary)
          .frame(width: DesignTokens.Size.tile)
        Text("Show older sessions")
          .wbText(.body)
          .foregroundStyle(isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
        Spacer(minLength: 0)
      }
      .padding(.leading, SidebarTreeInset.session)
      .padding(.trailing, DesignTokens.Spacing.smPlus)
      .frame(height: DesignTokens.Size.row)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
        .fill(isHovered ? Color.wbSurfaceHover : Color.clear)
    )
    .overlay(alignment: .topLeading) {
      LoadMoreGuideLine()
    }
    .onHover { isHovered = $0 }
    .padding(.top, DesignTokens.Spacing.xs)
    .accessibilityLabel("Show older sessions")
  }
}

// MARK: - Guide line continuation

/// Short guide segment that connects the last visible session to the
/// "Show older sessions" row, signalling that the branch continues.
/// The line splits around the ellipsis glyph, matching the ±9 pt gap
/// that `SessionGuideLine` reserves around the status circle.
private struct LoadMoreGuideLine: View {
  /// Gap above and below the glyph centre (same as `SessionGuideLine.gap`).
  fileprivate static let gap: CGFloat = 9
  /// The line stops this far above the row's bottom.
  fileprivate static let bottomInset: CGFloat = 6

  var body: some View {
    LoadMoreGuideShape()
      .stroke(Color.wbBorderControl, lineWidth: 1)
      .frame(width: SidebarTreeInset.guideX + 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct LoadMoreGuideShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      let guideX = SidebarTreeInset.guideX
      // The ellipsis icon is vertically centred in the row frame.
      let mid = rect.height / 2
      let bottom = rect.height - LoadMoreGuideLine.bottomInset

      // Upper segment: top edge down to the gap above the glyph.
      let gapTop = mid - LoadMoreGuideLine.gap
      if gapTop > 0 {
        path.move(to: CGPoint(x: guideX, y: 0))
        path.addLine(to: CGPoint(x: guideX, y: gapTop))
      }
      // Lower segment: below the glyph gap down to the bottom inset.
      let gapBottom = mid + LoadMoreGuideLine.gap
      if bottom > gapBottom {
        path.move(to: CGPoint(x: guideX, y: gapBottom))
        path.addLine(to: CGPoint(x: guideX, y: bottom))
      }
    }
  }
}
