//
//  StatusChip.swift
//  AgentHub
//
//  Tinted pill showing a status glyph and a word.
//  Matches the `.status-chip` component in the prototype.
//

import SwiftUI

/// A tinted pill with a small status glyph and a status word.
public struct StatusChip: View {
  let presentation: SessionStatusPresentation

  public init(presentation: SessionStatusPresentation) {
    self.presentation = presentation
  }

  public init(status: SessionStatus?, isPending: Bool = false) {
    self.presentation = SessionStatusPresentation(status: status, isPending: isPending)
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      StatusGlyph(presentation: presentation, size: 10)
      Text(presentation.word)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .wbText(.subheadline, family: .interDisplay)
    .fontWeight(.medium)
    .padding(.leading, DesignTokens.Spacing.xsPlus)
    .padding(.trailing, DesignTokens.Spacing.sm)
    .frame(height: 22)
    .background(presentation.tintColor, in: Capsule())
    .foregroundStyle(presentation.textColor)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(presentation.accessibilityLabel)
  }
}
