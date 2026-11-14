//
//  SplitButton.swift
//  AgentHub
//
//  Primary action + chevron menu. Matches `.split-button` in the prototype.
//  The one split button in the app: the Approve button can pass its own label
//  (text plus on-accent key caps) through `init(label:…)`.
//

import SwiftUI

/// A split button: a primary action on the left and a menu on the right.
public struct SplitButton<Label: View, MenuContent: View>: View {
  let label: () -> Label
  let accessibilityIdentifier: String?
  let isPrimaryEnabled: Bool
  let menuAccessibilityLabel: String
  let primaryAccessibilityLabel: String?
  let primaryHelp: String?
  let primaryShortcut: KeyboardShortcut?
  let leadingPadding: CGFloat
  let trailingPadding: CGFloat
  let action: () -> Void
  @ViewBuilder let menu: () -> MenuContent

  @Environment(\.isEnabled) private var isEnabled
  @State private var isChevronHovered = false

  /// - Parameters:
  ///   - isPrimaryEnabled: Disables the left half only. The chevron menu stays
  ///     live, so the user can still pick another option.
  ///   - menuAccessibilityLabel: VoiceOver label for the chevron half.
  ///   - primaryAccessibilityLabel: VoiceOver label for the left half, when
  ///     its label is more than words (for example text plus key caps).
  ///   - primaryHelp: Tooltip for the left half only.
  ///   - primaryShortcut: Keyboard shortcut for the left half only.
  ///   - trailingPadding: Space after the label; use `Spacing.sm` when the
  ///     label ends in key caps.
  public init(
    accessibilityIdentifier: String? = nil,
    isPrimaryEnabled: Bool = true,
    menuAccessibilityLabel: String = "More options",
    primaryAccessibilityLabel: String? = nil,
    primaryHelp: String? = nil,
    primaryShortcut: KeyboardShortcut? = nil,
    trailingPadding: CGFloat = DesignTokens.Spacing.md,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label,
    @ViewBuilder menu: @escaping () -> MenuContent
  ) {
    self.label = label
    self.accessibilityIdentifier = accessibilityIdentifier
    self.isPrimaryEnabled = isPrimaryEnabled
    self.menuAccessibilityLabel = menuAccessibilityLabel
    self.primaryAccessibilityLabel = primaryAccessibilityLabel
    self.primaryHelp = primaryHelp
    self.primaryShortcut = primaryShortcut
    self.leadingPadding = DesignTokens.Spacing.md
    self.trailingPadding = trailingPadding
    self.action = action
    self.menu = menu
  }

  public var body: some View {
    HStack(spacing: 1) {
      Button(action: action) {
        label()
          .contentShape(Rectangle())
      }
      .buttonStyle(SplitLeftStyle(leadingPadding: leadingPadding, trailingPadding: trailingPadding))
      // Our `wbFocusRing` replaces the native one (see `WBSplitLeftBody`).
      .focusEffectDisabled()
      .disabled(!isPrimaryEnabled)
      .keyboardShortcut(primaryShortcut)
      .help(primaryHelp ?? "")
      .modifier(SplitPrimaryAccessibilityLabel(label: primaryAccessibilityLabel))

      // .borderlessButton lets AppKit draw the label: it ignores the token colour
      // (white chevron on Warm dark's near-white accent) and adds a second arrow.
      // A plain-button menu with the indicator hidden draws our own chevron.
      Menu(content: menu) {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
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
      .clipShape(WBSplitShape.trailing)
      // A disabled split button dims both halves, like the button styles.
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      .accessibilityLabel(menuAccessibilityLabel)
    }
    // One drop shadow for the pair, like `WBPrimaryButtonStyle`.
    .shadow(color: .black.opacity(0.12), radius: 0.75, x: 0, y: 0.5)
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }
}

extension SplitButton where Label == Text {
  /// A split button with a text title.
  public init(
    _ title: String,
    accessibilityIdentifier: String? = nil,
    isPrimaryEnabled: Bool = true,
    menuAccessibilityLabel: String = "More options",
    action: @escaping () -> Void,
    @ViewBuilder menu: @escaping () -> MenuContent
  ) {
    self.init(
      accessibilityIdentifier: accessibilityIdentifier,
      isPrimaryEnabled: isPrimaryEnabled,
      menuAccessibilityLabel: menuAccessibilityLabel,
      action: action,
      label: { Text(title) },
      menu: menu
    )
  }
}

/// Sets the left half's VoiceOver label only when the caller gives one, so a
/// text label keeps reading as its own text.
private struct SplitPrimaryAccessibilityLabel: ViewModifier {
  let label: String?

  func body(content: Content) -> some View {
    if let label {
      content.accessibilityLabel(label)
    } else {
      content
    }
  }
}

/// The two halves' shapes. Continuous corners, like every other control.
enum WBSplitShape {
  static var leading: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: DesignTokens.Radius.item,
      bottomLeadingRadius: DesignTokens.Radius.item,
      bottomTrailingRadius: 0,
      topTrailingRadius: 0,
      style: .continuous
    )
  }

  static var trailing: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: 0,
      bottomLeadingRadius: 0,
      bottomTrailingRadius: DesignTokens.Radius.item,
      topTrailingRadius: DesignTokens.Radius.item,
      style: .continuous
    )
  }
}

private struct SplitLeftStyle: ButtonStyle {
  let leadingPadding: CGFloat
  let trailingPadding: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    WBSplitLeftBody(
      configuration: configuration,
      leadingPadding: leadingPadding,
      trailingPadding: trailingPadding,
      drawsFocusRing: true
    )
  }
}

/// The accent half of a split button. Hover and press change colour only, on
/// the first frame: hover `wbAccentHover`, press `wbAccentHover` plus a
/// `wbSurfacePressed` layer.
struct WBSplitLeftBody: View {
  let configuration: ButtonStyleConfiguration
  let leadingPadding: CGFloat
  let trailingPadding: CGFloat
  /// Draw `wbFocusRing` on keyboard focus. Only when the owner of the
  /// `Button` also applies `.focusEffectDisabled()`; otherwise the native
  /// macOS ring shows and a second ring would double it.
  var drawsFocusRing = false

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    let shape = WBSplitShape.leading
    // Disabled: no hover or press fill, as in `WBButtonBody`.
    let isPressed = isEnabled && configuration.isPressed
    let showsHover = isEnabled && (isHovered || isPressed)
    configuration.label
      .wbText(.bodyEmphasis)
      .foregroundStyle(Color.wbTextOnAccent)
      .padding(.leading, leadingPadding)
      .padding(.trailing, trailingPadding)
      .frame(height: DesignTokens.Size.control)
      .background {
        ZStack {
          showsHover ? Color.wbAccentHover : Color.wbAccent
          if isPressed {
            Color.wbSurfacePressed
          }
        }
      }
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false)
      }
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      .wbFocusRing(drawsFocusRing && isFocused, cornerRadius: DesignTokens.Radius.item)
      .onHover { isHovered = $0 }
  }
}

/// Fill behind the chevron half of a split button: accent, `wbAccentHover` on
/// hover, with the same `white 0.18` inner ring as the left half. A `Menu`
/// does not expose its pressed state; AppKit opens the menu on mouse-down,
/// which is its own feedback.
struct WBSplitChevronFill: View {
  let isHovered: Bool

  var body: some View {
    ZStack {
      isHovered ? Color.wbAccentHover : Color.wbAccent
      WBSplitShape.trailing
        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
  }
}
