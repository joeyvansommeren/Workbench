//
//  CountBadge.swift
//  AgentHub
//
//  Matches `.count-badge` in the prototype.
//

import SwiftUI

/// A small pill with a number.
public struct CountBadge: View {
  let count: Int
  let style: Style

  /// Badge style: neutral (default) or accent (tinted).
  public enum Style {
    /// Muted background, secondary text. Used for sidebar counts.
    case neutral
    /// Accent background, on-accent text. Used for active filter counts.
    case accent
  }

  public init(_ count: Int, style: Style = .neutral) {
    self.count = count
    self.style = style
  }

  public var body: some View {
    Text("\(count)")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(foreground)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .frame(minWidth: DesignTokens.Size.tile, minHeight: DesignTokens.Size.tile)
      .background(background, in: Capsule())
      .fixedSize()
  }

  private var foreground: Color {
    switch style {
    case .neutral: return .wbTextSecondary
    case .accent:  return .wbTextOnAccent
    }
  }

  private var background: Color {
    switch style {
    case .neutral: return .wbSurfaceKeycap
    case .accent:  return .wbAccent
    }
  }
}
