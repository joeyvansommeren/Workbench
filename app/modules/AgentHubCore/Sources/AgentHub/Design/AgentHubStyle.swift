//
//  AgentHubStyle.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI

public enum AgentHubLayout {
  public static let panelCornerRadius: CGFloat = DesignTokens.Radius.lg  // 14
  public static let cardCornerRadius: CGFloat = DesignTokens.Radius.md   // 10
  public static let rowCornerRadius: CGFloat = DesignTokens.Radius.sm    // 6
  public static let chipCornerRadius: CGFloat = DesignTokens.Radius.sm   // 6
  public static let buttonCornerRadius: CGFloat = DesignTokens.Radius.sm // 6

  /// Shared height for top bars across panels (MonitoringCardView header,
  /// GitHubPanelView header, etc.) so sibling panels line up exactly.
  public static let topBarHeight: CGFloat = 34

  /// Shared height for the secondary bar immediately below a top bar
  /// (MonitoringCardView path row, GitHubPanelView tab bar, etc.).
  public static let subBarHeight: CGFloat = 30

  /// Smallest window that still fits the sidebar (280) and one 400 px session
  /// column with a side panel closed. 1100 is the design target for laptops.
  public static let windowMinWidth: CGFloat = 900
  public static let windowMinHeight: CGFloat = 600
}

private struct AgentHubPanelModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  func body(content: Content) -> some View {
    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.panelCornerRadius, style: .continuous)
          .fill(Color.clear)
      )
  }
}

private struct AgentHubCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool
  let transparent: Bool

  func body(content: Content) -> some View {
    // Dark surfaces are translucent lifts over the themed background, so the
    // theme's own color shows through instead of a fixed near-black.
    let backgroundColor = colorScheme == .dark ? Color.white.opacity(0.035) : Color(white: 0.98)
    let highlightOpacity = colorScheme == .dark ? 0.6 : 0.85
    let strokeColor = isHighlighted
      ? Color.brandPrimary.opacity(highlightOpacity)
      : Color.primary.opacity(0.08)
    let strokeWidth: CGFloat = isHighlighted ? 2 : 1

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .fill(transparent ? Color.clear : backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: strokeWidth)
      )
  }
}

private struct AgentHubRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    let backgroundColor = colorScheme == .dark ? Color.white.opacity(0.05) : Color(white: 0.96)
    let highlightOpacity = colorScheme == .dark ? 0.5 : 0.75
    let strokeColor = isHighlighted
      ? Color.brandPrimary.opacity(highlightOpacity)
      : Color.primary.opacity(0.08)

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: 1)
      )
  }
}

private struct AgentHubInsetModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    // Insets are recessed: darker than the surface they sit on.
    let backgroundColor = colorScheme == .dark ? Color.black.opacity(0.18) : Color(white: 0.94)

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      )
  }
}

private struct AgentHubChipModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isActive: Bool

  func body(content: Content) -> some View {
    let fillOpacity = colorScheme == .dark ? 0.15 : 0.4
    let fillColor = isActive
      ? Color.brandPrimary.opacity(fillOpacity)
      : (colorScheme == .dark ? Color.white.opacity(0.07) : Color(white: 0.92))
    let chipStrokeOpacity = colorScheme == .dark ? 0.4 : 0.65
    let strokeColor = isActive
      ? Color.brandPrimary.opacity(chipStrokeOpacity)
      : Color.secondary.opacity(0.25)

    return content
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .fill(fillColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: 1)
      )
  }
}

private struct AgentHubFlatRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool
  let providerKind: SessionProviderKind?

  @State private var isHovered = false

  func body(content: Content) -> some View {
    let accentColor: Color = if let provider = providerKind {
      Color.brandPrimary(for: provider)
    } else {
      Color.brandPrimary
    }

    let hoverBackground = accentColor.opacity(colorScheme == .dark ? 0.12 : 0.35)

    return content
      .background(isHovered ? hoverBackground : .clear)
      .overlay(alignment: .leading) {
        if isHighlighted {
          Rectangle()
            .fill(accentColor)
            .frame(width: 2)
        }
      }
      .onHover { hovering in
        withAnimation(.easeInOut(duration: 0.12)) {
          isHovered = hovering
        }
      }
  }
}

public extension View {
  func agentHubPanel() -> some View {
    modifier(AgentHubPanelModifier())
  }

  func agentHubCard(isHighlighted: Bool = false, transparent: Bool = false) -> some View {
    modifier(AgentHubCardModifier(isHighlighted: isHighlighted, transparent: transparent))
  }

  func agentHubRow(isHighlighted: Bool = false) -> some View {
    modifier(AgentHubRowModifier(isHighlighted: isHighlighted))
  }

  func agentHubInset() -> some View {
    modifier(AgentHubInsetModifier())
  }

  func agentHubChip(isActive: Bool = false) -> some View {
    modifier(AgentHubChipModifier(isActive: isActive))
  }

  func agentHubFlatRow(isHighlighted: Bool = false, providerKind: SessionProviderKind? = nil) -> some View {
    modifier(AgentHubFlatRowModifier(isHighlighted: isHighlighted, providerKind: providerKind))
  }
}
