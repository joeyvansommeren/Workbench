//
//  SplitButton.swift
//  AgentHub
//
//  Primary action + chevron menu. Matches `.split-button` in the prototype.
//

import SwiftUI

/// A split button: a primary action on the left and a menu on the right.
public struct SplitButton<MenuContent: View>: View {
  let title: String
  let accessibilityIdentifier: String?
  let action: () -> Void
  @ViewBuilder let menu: () -> MenuContent

  public init(
    _ title: String,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void,
    @ViewBuilder menu: @escaping () -> MenuContent
  ) {
    self.title = title
    self.accessibilityIdentifier = accessibilityIdentifier
    self.action = action
    self.menu = menu
  }

  public var body: some View {
    HStack(spacing: 1) {
      Button(action: action) {
        Text(title)
          .wbText(.bodyEmphasis)
      }
      .buttonStyle(SplitLeftStyle())

      // .borderlessButton lets AppKit draw the label: it ignores the token colour
      // (white chevron on Warm dark's near-white accent) and adds a second arrow.
      // A plain-button menu with the indicator hidden draws our own chevron.
      Menu(content: menu) {
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.wbTextOnAccent)
          .frame(width: 28, height: DesignTokens.Size.control)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(width: 28, height: DesignTokens.Size.control)
      .background(Color.wbAccent)
      .foregroundStyle(Color.wbTextOnAccent)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 0,
          bottomLeadingRadius: 0,
          bottomTrailingRadius: DesignTokens.Radius.item,
          topTrailingRadius: DesignTokens.Radius.item
        )
      )
      .accessibilityLabel("More options")
    }
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }
}

private struct SplitLeftStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(Color.wbTextOnAccent)
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: DesignTokens.Size.control)
      .background(configuration.isPressed ? Color.wbAccentHover : Color.wbAccent)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: DesignTokens.Radius.item,
          bottomLeadingRadius: DesignTokens.Radius.item,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0
        )
      )
      .overlay {
        UnevenRoundedRectangle(
          topLeadingRadius: DesignTokens.Radius.item,
          bottomLeadingRadius: DesignTokens.Radius.item,
          bottomTrailingRadius: 0,
          topTrailingRadius: 0
        )
        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        .allowsHitTesting(false)
      }
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
  }
}
