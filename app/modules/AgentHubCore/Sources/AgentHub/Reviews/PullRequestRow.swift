//
//  PullRequestRow.swift
//  AgentHub
//
//  One pull request in the new shell's Reviews list (`.pr-row` in the
//  prototype): tile, title, age; then `repo #number · author`, the linked
//  session's glyph and the checks icon.
//

import SwiftUI

struct PullRequestRow: View {
  let presentation: PullRequestRowPresentation
  let tileColor: RepositoryTileColor
  /// The linked session's status. Nil when there is no session; an idle
  /// session shows no glyph either, as in the prototype.
  let sessionStatus: SessionStatusPresentation?
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
        titleLine
        metaLine
          .padding(.leading, DesignTokens.Size.tile + DesignTokens.Spacing.smPlus)
      }
      .padding(DesignTokens.Spacing.smPlus)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      background,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("reviews.row.\(presentation.id)")
  }

  private var background: Color {
    if isSelected { return .wbSurfaceSelected }
    return isHovered ? .wbSurfaceHover : .clear
  }

  private var titleLine: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      LetterTile(letter: presentation.repositoryLabel.first ?? "?", color: tileColor)
      Text(presentation.title)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: DesignTokens.Spacing.sm)
      Text(presentation.age)
        .wbText(.callout)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
        .fixedSize()
    }
  }

  private var metaLine: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(presentation.repositoryLabel)
        .wbText(.codeSmall)
        .fixedSize()
      Text("·").wbText(.callout)
      Text(presentation.author)
        .wbText(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: DesignTokens.Spacing.sm)
      signals
    }
    .foregroundStyle(Color.wbTextSecondary)
  }

  private var signals: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      if let sessionStatus, sessionStatus.shape != .ring {
        StatusGlyph(presentation: sessionStatus)
      }
      if let checks = presentation.checks {
        PullRequestChecksIcon(state: checks)
      }
    }
    .fixedSize()
  }
}

/// The 14 pt checks icon: pass, fail or pending.
struct PullRequestChecksIcon: View {
  let state: PullRequestChecksState

  var body: some View {
    Image(systemName: state.systemImage)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(color)
      .frame(width: 14, height: 14)
      .fixedSize()
      .accessibilityLabel(state.accessibilityLabel)
  }

  private var color: Color {
    switch state {
    case .pass: return .wbStatusReadyFill
    case .fail: return .wbStatusErrorFill
    case .pending: return .wbStatusIdleFill
    }
  }
}
