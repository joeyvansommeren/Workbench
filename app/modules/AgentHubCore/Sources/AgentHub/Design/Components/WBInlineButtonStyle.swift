//
//  WBInlineButtonStyle.swift
//  AgentHub
//
//  Hover and press for a small button that is part of a larger component:
//  the FilterChip "x", the two FiltersButton halves, the ErrorBanner "x".
//  Same rules as `WBButtonBody`: colour only, instant, no scale, no
//  animation; disabled dims to `DesignTokens.Opacity.disabled` and shows no
//  hover or press.
//

import SwiftUI

/// Which feedback layers an inline button draws. Pure, so it is testable.
struct WBInlineButtonFeedback: Equatable {
  /// `wbSurfaceHover` under the label (also while pressed: the pointer is on it).
  var showsHoverFill: Bool
  /// `wbSurfacePressed` on top of the hover fill.
  var showsPressedFill: Bool
  /// Label goes from `wbTextSecondary` to `wbTextPrimary`.
  var emphasisesLabel: Bool

  static func resolve(
    isEnabled: Bool,
    isHovered: Bool,
    isPressed: Bool,
    hoverFill: Bool
  ) -> WBInlineButtonFeedback {
    let isPressed = isEnabled && isPressed
    let isActive = isEnabled && (isHovered || isPressed)
    return WBInlineButtonFeedback(
      showsHoverFill: hoverFill && isActive,
      showsPressedFill: isPressed,
      emphasisesLabel: isActive
    )
  }
}

/// A borderless button inside a component.
/// - `hoverFill`: draw `wbSurfaceHover` on hover (FiltersButton, banner "x").
///   Off for the FilterChip "x", which only changes colour (prototype
///   `.filter-chip .remove:hover`).
/// - `tintsLabel`: secondary at rest, primary on hover or press. Off when the
///   label keeps its own colour (the banner "x" stays error-coloured).
struct WBInlineButtonStyle: ButtonStyle {
  var hoverFill = true
  var tintsLabel = true
  var cornerRadius: CGFloat = DesignTokens.Radius.segment

  func makeBody(configuration: Configuration) -> some View {
    WBInlineButtonBody(
      configuration: configuration,
      hoverFill: hoverFill,
      tintsLabel: tintsLabel,
      cornerRadius: cornerRadius
    )
  }
}

/// A view (not the style) owns the hover state, as in `WBButtonBody`.
private struct WBInlineButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let hoverFill: Bool
  let tintsLabel: Bool
  let cornerRadius: CGFloat

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    let feedback = WBInlineButtonFeedback.resolve(
      isEnabled: isEnabled,
      isHovered: isHovered,
      isPressed: configuration.isPressed,
      hoverFill: hoverFill
    )
    configuration.label
      .foregroundStyle(labelColor(feedback))
      .background {
        ZStack {
          if feedback.showsHoverFill { Color.wbSurfaceHover }
          if feedback.showsPressedFill { Color.wbSurfacePressed }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      }
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      .onHover { isHovered = $0 }
    // No `.animation`: feedback lands on the first frame.
  }

  private func labelColor(_ feedback: WBInlineButtonFeedback) -> AnyShapeStyle {
    guard tintsLabel else { return AnyShapeStyle(.foreground) }
    return AnyShapeStyle(feedback.emphasisesLabel ? Color.wbTextPrimary : Color.wbTextSecondary)
  }
}
