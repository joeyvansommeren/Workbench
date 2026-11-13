//
//  WorkbenchButtonStyles.swift
//  AgentHub
//
//  Button styles for the new shell: primary, secondary, plain, destructive.
//  All use scale 0.97 when pressed.
//

import SwiftUI

// MARK: - Primary

/// Accent-filled button. Matches `.button-primary` in the prototype.
public struct WBPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(Color.wbTextOnAccent)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background(configuration.isPressed ? Color.wbAccentHover : Color.wbAccent)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
          .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
          .allowsHitTesting(false)
      }
      .shadow(color: .black.opacity(0.12), radius: 0.75, x: 0, y: 0.5)
      .shadow(color: .black.opacity(0.12), radius: 0.75, x: 0, y: 0.5)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
  }
}

// MARK: - Secondary

/// Surface-coloured button with a control shadow. Matches `.button-secondary`.
public struct WBSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(Color.wbTextPrimary)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background(isHovered ? Color.wbSurfaceControlHover : Color.wbSurfaceControl)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
      .wbElevation(.control)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .onHover { isHovered = $0 }
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
  }
}

// MARK: - Plain

/// Transparent button that shows a hover background. Matches `.button-plain`.
public struct WBPlainButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(Color.wbTextPrimary)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background(isHovered ? Color.wbSurfaceHover : .clear)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .onHover { isHovered = $0 }
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
  }
}

// MARK: - Destructive

/// Surface-coloured button with error text. Matches `.button-destructive`.
public struct WBDestructiveButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(Color.wbStatusErrorText)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background(isHovered ? Color.wbSurfaceControlHover : Color.wbSurfaceControl)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
      .wbElevation(.control)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(isEnabled ? 1 : 0.45)
      .onHover { isHovered = $0 }
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
  }
}

// MARK: - Convenience extensions

extension ButtonStyle where Self == WBPrimaryButtonStyle {
  public static var wbPrimary: WBPrimaryButtonStyle { WBPrimaryButtonStyle() }
}

extension ButtonStyle where Self == WBSecondaryButtonStyle {
  public static var wbSecondary: WBSecondaryButtonStyle { WBSecondaryButtonStyle() }
}

extension ButtonStyle where Self == WBPlainButtonStyle {
  public static var wbPlain: WBPlainButtonStyle { WBPlainButtonStyle() }
}

extension ButtonStyle where Self == WBDestructiveButtonStyle {
  public static var wbDestructive: WBDestructiveButtonStyle { WBDestructiveButtonStyle() }
}
