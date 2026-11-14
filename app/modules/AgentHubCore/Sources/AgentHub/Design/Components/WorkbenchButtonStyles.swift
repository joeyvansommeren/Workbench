//
//  WorkbenchButtonStyles.swift
//  AgentHub
//
//  Button styles for the new shell: primary, secondary, plain, destructive.
//  Hover and press change colour only, instantly (Joey, 2026-11-14: no scale
//  on hover or press, anywhere). Press = the hover fill plus a
//  `wbSurfacePressed` layer, which darkens in light themes and lightens in
//  dark themes, like a native AppKit button highlight.
//

import SwiftUI

/// Which fill set a `WBButtonBody` draws.
enum WBButtonKind {
  case primary, secondary, plain, destructive

  /// Rest / hover fills from the prototype (`.button-*` and `:hover`).
  @MainActor
  func fill(isHovered: Bool) -> Color {
    switch self {
    case .primary: return isHovered ? .wbAccentHover : .wbAccent
    case .secondary, .destructive: return isHovered ? .wbSurfaceControlHover : .wbSurfaceControl
    case .plain: return isHovered ? .wbSurfaceHover : .clear
    }
  }

  @MainActor
  var foreground: Color {
    switch self {
    case .primary: return .wbTextOnAccent
    case .secondary, .plain: return .wbTextPrimary
    case .destructive: return .wbStatusErrorText
    }
  }
}

/// Shared body for the four button styles. A view (not the style) owns the
/// hover state, so `@State` lives in a real view identity.
struct WBButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: WBButtonKind

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    // A pressed button always shows the hover fill underneath: the pointer is on it.
    let showsHoverFill = isHovered || configuration.isPressed

    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(kind.foreground)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background {
        ZStack {
          kind.fill(isHovered: showsHoverFill)
          if configuration.isPressed {
            Color.wbSurfacePressed
          }
        }
      }
      .clipShape(shape)
      .modifier(WBButtonChrome(kind: kind))
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      // Keyboard focus: the caller owns the `Button`, so it keeps the native
      // macOS focus ring (a style cannot switch that off, and drawing
      // `wbFocusRing` too would double it).
      .onHover { isHovered = $0 }
      // No `.animation`: feedback lands on the first frame (plan item 1).
  }
}

/// The per-kind border and elevation around the fill.
private struct WBButtonChrome: ViewModifier {
  let kind: WBButtonKind

  func body(content: Content) -> some View {
    switch kind {
    case .primary:
      content
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.12), radius: 0.75, x: 0, y: 0.5)
    case .secondary, .destructive:
      content.wbElevation(.control)
    case .plain:
      content
    }
  }
}

// MARK: - Primary

/// Accent-filled button. Matches `.button-primary` in the prototype.
public struct WBPrimaryButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    WBButtonBody(configuration: configuration, kind: .primary)
  }
}

// MARK: - Secondary

/// Surface-coloured button with a control shadow. Matches `.button-secondary`.
public struct WBSecondaryButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    WBButtonBody(configuration: configuration, kind: .secondary)
  }
}

// MARK: - Plain

/// Transparent button that shows a hover background. Matches `.button-plain`.
public struct WBPlainButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    WBButtonBody(configuration: configuration, kind: .plain)
  }
}

// MARK: - Destructive

/// Surface-coloured button with error text. Matches `.button-destructive`.
public struct WBDestructiveButtonStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    WBButtonBody(configuration: configuration, kind: .destructive)
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
