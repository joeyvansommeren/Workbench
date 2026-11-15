//
//  IconButton.swift
//  AgentHub
//
//  An icon-only button with hover/pressed states.
//  Matches `.icon-button` and `.icon-button-small` in the prototype.
//

import SwiftUI

/// An icon-only button that shows a hover background.
public struct IconButton: View {
  let systemImage: String
  let size: CGFloat
  let isSmall: Bool
  let isToggled: Bool
  let accessibilityLabel: String
  let accessibilityIdentifier: String?
  let action: () -> Void

  @State private var isHovered = false

  /// - Parameters:
  ///   - systemImage: SF Symbol name.
  ///   - isSmall: Use the small size (24 pt). Defaults to false (28 pt).
  ///   - isToggled: Draw the toggled-on background.
  ///   - accessibilityLabel: VoiceOver label for the button.
  ///   - accessibilityIdentifier: Optional identifier for UI automation.
  ///   - action: The tap action.
  public init(
    systemImage: String,
    isSmall: Bool = false,
    isToggled: Bool = false,
    accessibilityLabel: String,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.isSmall = isSmall
    self.isToggled = isToggled
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityIdentifier = accessibilityIdentifier
    self.action = action
    self.size = isSmall ? DesignTokens.Size.controlSmall : DesignTokens.Size.control
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: isSmall ? 11 : 13))
        .frame(width: size, height: size)
        .contentShape(Rectangle())
    }
    .buttonStyle(IconButtonStyle(isToggled: isToggled, isHovered: isHovered, cornerRadius: cornerRadius))
    // `IconButtonBody` draws `wbFocusRing` in place of the native ring.
    .focusEffectDisabled()
    .onHover { isHovered = $0 }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isToggled ? .isSelected : [])
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }

  private var cornerRadius: CGFloat {
    isSmall ? DesignTokens.Radius.segment : DesignTokens.Radius.item
  }
}

/// Reads `isPressed` for the icon button. Colour only, instant (no scale).
/// Order: toggled > pressed > hover > clear (prototype `.icon-button:active`).
private struct IconButtonStyle: ButtonStyle {
  let isToggled: Bool
  let isHovered: Bool
  let cornerRadius: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    IconButtonBody(
      configuration: configuration, isToggled: isToggled, isHovered: isHovered, cornerRadius: cornerRadius)
  }
}

/// A view (not the style), so it can read `isEnabled` and keyboard focus.
/// A disabled icon button dims like the other button styles and shows no
/// hover or press fill; the toggled fill stays.
private struct IconButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let isToggled: Bool
  let isHovered: Bool
  let cornerRadius: CGFloat

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused

  var body: some View {
    let isPressed = isEnabled && configuration.isPressed
    let isHovered = isEnabled && isHovered
    configuration.label
      .foregroundStyle(isHovered || isToggled || isPressed ? Color.wbTextPrimary : Color.wbTextSecondary)
      .background(
        fill(isPressed: isPressed, isHovered: isHovered),
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      .wbFocusRing(isFocused, cornerRadius: cornerRadius)
  }

  private func fill(isPressed: Bool, isHovered: Bool) -> Color {
    if isToggled { return .wbSurfaceSelected }
    if isPressed { return .wbSurfacePressed }
    if isHovered { return .wbSurfaceHover }
    return .clear
  }
}
