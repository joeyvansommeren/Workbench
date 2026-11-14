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

  @State private var isChevronHovered = false

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
      .background(WBSplitChevronFill(isHovered: isChevronHovered))
      .onHover { isChevronHovered = $0 }
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
    WBSplitLeftBody(configuration: configuration, leadingPadding: DesignTokens.Spacing.md, trailingPadding: DesignTokens.Spacing.md)
  }
}

/// The accent half of a split button. Hover and press change colour only, on
/// the first frame: hover `wbAccentHover`, press `wbAccentHover` plus a
/// `wbSurfacePressed` layer. Shared with the Approve split button.
struct WBSplitLeftBody: View {
  let configuration: ButtonStyleConfiguration
  let leadingPadding: CGFloat
  let trailingPadding: CGFloat

  @State private var isHovered = false

  var body: some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: DesignTokens.Radius.item,
      bottomLeadingRadius: DesignTokens.Radius.item,
      bottomTrailingRadius: 0,
      topTrailingRadius: 0
    )
    configuration.label
      .foregroundStyle(Color.wbTextOnAccent)
      .padding(.leading, leadingPadding)
      .padding(.trailing, trailingPadding)
      .frame(height: DesignTokens.Size.control)
      .background {
        ZStack {
          isHovered || configuration.isPressed ? Color.wbAccentHover : Color.wbAccent
          if configuration.isPressed {
            Color.wbSurfacePressed
          }
        }
      }
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false)
      }
      .onHover { isHovered = $0 }
  }
}

/// Fill behind the chevron half of a split button: accent, `wbAccentHover` on
/// hover. A `Menu` does not expose its pressed state; AppKit opens the menu on
/// mouse-down, which is its own feedback.
struct WBSplitChevronFill: View {
  let isHovered: Bool

  var body: some View {
    isHovered ? Color.wbAccentHover : Color.wbAccent
  }
}
