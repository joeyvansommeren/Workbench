//
//  SessionTab.swift
//  AgentHub
//
//  One tab of the session strip (`.tab` in the prototype): repository tile,
//  title with a fade-out edge, and the status glyph. On hover the glyph gives
//  way to a close button in the same fixed frame, so the tab never resizes.
//

import SwiftUI

/// What a tab shows for one open session. Built from the session item and
/// the tracked repositories, so the strip never does I/O.
struct SessionTabPresentation: Equatable, Identifiable {
  let id: String
  let title: String
  let providerKind: SessionProviderKind
  let repositoryName: String
  let repositoryPath: String
  let branchName: String?
  let status: SessionStatus?
  let isPending: Bool

  @MainActor
  static func make(
    item: ProjectableSessionItem,
    title: String,
    repositories: [SelectedRepository]
  ) -> SessionTabPresentation {
    let match = WorktreeModuleResolver.bestMatch(
      for: item.session.projectPath,
      repositories: repositories
    )
    return SessionTabPresentation(
      id: item.id,
      title: title,
      providerKind: item.providerKind,
      repositoryName: match?.repository.name ?? item.session.projectName,
      repositoryPath: match?.repository.path ?? item.session.projectPath,
      branchName: item.session.branchName ?? (match?.worktree.isWorktree == true ? match?.worktree.name : nil),
      status: item.status,
      isPending: item.isPending
    )
  }
}

enum SessionTabMetrics {
  static let minWidth: CGFloat = 120
  static let maxWidth: CGFloat = 204
  static let spacing: CGFloat = DesignTokens.Spacing.xs
  /// Width of the trailing overflow chevron and the "+" button.
  static let trailingButtonWidth: CGFloat = DesignTokens.Size.control
}

struct SessionTab: View {
  let presentation: SessionTabPresentation
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      LetterTile(name: presentation.repositoryName, path: presentation.repositoryPath)
      Text(presentation.title)
        .wbText(.bodyEmphasis)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .mask(TitleFadeMask())
        .clipped()
      trailingGlyph
    }
    .padding(.leading, DesignTokens.Spacing.sm)
    .padding(.trailing, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.tab)
    .frame(minWidth: SessionTabMetrics.minWidth, maxWidth: SessionTabMetrics.maxWidth)
    .foregroundStyle(isSelected || isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background { background }
    .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
    .onTapGesture(perform: onSelect)
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Close Tab", action: onClose)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(.default, onSelect)
    .accessibilityAction(named: "Close tab", onClose)
    .help(presentation.title)
  }

  /// Glyph and close button share one fixed frame, so hovering never changes
  /// the tab's intrinsic size (layout-loop rule for chrome).
  private var trailingGlyph: some View {
    ZStack {
      StatusGlyph(status: presentation.status, isPending: presentation.isPending)
        .opacity(isHovered ? 0 : 1)
      if isHovered {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.wbTextSecondary)
        .accessibilityLabel("Close \(presentation.title)")
      }
    }
    .frame(width: 16, height: 16)
    .fixedSize()
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    if isSelected {
      shape.fill(Color.wbSurfaceRaised)
        .wbElevation(.raised, cornerRadius: DesignTokens.Radius.row)
    } else if isHovered {
      shape.fill(Color.wbSurfaceHover)
    }
  }

  private var accessibilityLabel: String {
    let word = SessionStatusPresentation(status: presentation.status, isPending: presentation.isPending).word
    return "\(presentation.title), \(presentation.repositoryName), \(word)"
  }
}

/// The prototype's title mask: solid, then fading out over the last 22 pt.
private struct TitleFadeMask: View {
  var body: some View {
    HStack(spacing: 0) {
      Rectangle()
      LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
        .frame(width: 22)
    }
  }
}
