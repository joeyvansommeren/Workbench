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
    .buttonStyle(.plain)
    .foregroundStyle(isHovered || isToggled ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background(backgroundColor, in: RoundedRectangle(cornerRadius: cornerRadius))
    .onHover { isHovered = $0 }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }

  private var backgroundColor: Color {
    if isToggled { return .wbSurfaceSelected }
    if isHovered { return .wbSurfaceHover }
    return .clear
  }

  private var cornerRadius: CGFloat {
    isSmall ? DesignTokens.Radius.segment : DesignTokens.Radius.item
  }
}
