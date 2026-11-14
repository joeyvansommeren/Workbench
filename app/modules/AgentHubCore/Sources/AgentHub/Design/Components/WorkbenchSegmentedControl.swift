//
//  WorkbenchSegmentedControl.swift
//  AgentHub
//
//  Segmented control matching `.segmented` in the prototype.
//  Segments sit in a field background with inset radius nesting.
//  The one segmented control in the app: text, text + count, icon-only
//  (`.small`), equal-width (`fillsWidth`) and disabled segments.
//

import SwiftUI

/// A segmented control where each segment can have a title, an optional
/// count, and an optional icon.
public struct WorkbenchSegmentedControl<T: Hashable>: View {

  /// Control height: 28 pt (`.regular`) or 24 pt (`.small`).
  public enum Size: Sendable {
    case regular
    case small
  }

  @Binding var selection: T
  let items: [T]
  let title: (T) -> String
  let showsTitle: Bool
  let icon: ((T) -> String?)?
  let showCounts: ((T) -> Int?)?
  let isItemEnabled: ((T) -> Bool)?
  let help: ((T) -> String?)?
  let fillsWidth: Bool
  let size: Size
  let accessibilityLabel: String?
  let accessibilityIdentifier: String?

  /// The general form.
  /// - Parameters:
  ///   - items: The segments, in order.
  ///   - title: Each segment's name. Also its VoiceOver label and, for
  ///     icon-only segments, its tooltip.
  ///   - showsTitle: `false` draws icon-only segments.
  ///   - icon: Optional SF Symbol per segment.
  ///   - isItemEnabled: A disabled segment dims and cannot be picked.
  ///   - help: Optional tooltip per segment (for example why it is disabled).
  ///   - fillsWidth: Equal-width segments that fill the proposed width.
  ///   - accessibilityLabel: What the control picks ("Review scope").
  public init(
    selection: Binding<T>,
    items: [T],
    title: @escaping (T) -> String,
    showsTitle: Bool = true,
    icon: ((T) -> String?)? = nil,
    showCounts: ((T) -> Int?)? = nil,
    isItemEnabled: ((T) -> Bool)? = nil,
    help: ((T) -> String?)? = nil,
    fillsWidth: Bool = false,
    size: Size = .regular,
    accessibilityLabel: String? = nil,
    accessibilityIdentifier: String? = nil
  ) {
    self._selection = selection
    self.items = items
    self.title = title
    self.showsTitle = showsTitle
    self.icon = icon
    self.showCounts = showCounts
    self.isItemEnabled = isItemEnabled
    self.help = help
    self.fillsWidth = fillsWidth
    self.size = size
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(items, id: \.self) { item in
        segmentButton(for: item)
      }
    }
    .padding(DesignTokens.Inset.control)
    .frame(height: controlHeight)
    .background(
      Color.wbSurfaceField,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }

  private var controlHeight: CGFloat {
    size == .small ? DesignTokens.Size.controlSmall : DesignTokens.Size.control
  }

  @ViewBuilder
  private func segmentButton(for item: T) -> some View {
    let isSelected = selection == item
    let isEnabled = isItemEnabled?(item) ?? true
    let count = showCounts?(item)
    let name = title(item)

    Button {
      selection = item
    } label: {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        if let symbol = icon?(item) {
          Image(systemName: symbol)
            .font(.system(size: 11))
        }
        if showsTitle {
          Text(name)
        }
        if let count {
          Text("\(count)")
            .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextTertiary)
            .wbText(.subheadline)
            .fontWeight(.medium)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, showsTitle ? DesignTokens.Spacing.smPlus : DesignTokens.Spacing.sm)
      .frame(maxWidth: fillsWidth ? .infinity : nil, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(WBSegmentStyle(isSelected: isSelected))
    // `WBSegmentBody` draws `wbFocusRing` in place of the native ring.
    .focusEffectDisabled()
    .disabled(!isEnabled)
    .help(help?(item) ?? (showsTitle ? "" : name))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityLabel(segmentLabel(name: name, count: count))
    .optionalAccessibilityIdentifier(accessibilityIdentifier.map { "\($0).\(name)" })
  }

  private func segmentLabel(name: String, count: Int?) -> String {
    if let count {
      return "\(name), \(count)"
    }
    return name
  }
}

extension WorkbenchSegmentedControl
where T: CaseIterable & CustomStringConvertible, T.AllCases: RandomAccessCollection {
  /// Every case of `T`, titled by `description`.
  public init(
    selection: Binding<T>,
    showCounts: ((T) -> Int?)? = nil,
    accessibilityLabel: String? = nil,
    accessibilityIdentifier: String? = nil
  ) {
    self.init(
      selection: selection,
      items: Array(T.allCases),
      title: { $0.description },
      showCounts: showCounts,
      accessibilityLabel: accessibilityLabel,
      accessibilityIdentifier: accessibilityIdentifier
    )
  }
}

/// One segment: selected fill + raised elevation, keyboard focus ring,
/// disabled opacity. Colour only, no scale.
private struct WBSegmentStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    WBSegmentBody(configuration: configuration, isSelected: isSelected)
  }
}

private struct WBSegmentBody: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var isFocused
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .wbText(.callout)
      .fontWeight(.medium)
      // Prototype `.segment:hover { color: primary }`.
      .foregroundStyle(isSelected || isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: DesignTokens.Radius.segment, style: .continuous)
            .fill(Color.wbSurfaceSegmentSelected)
            .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
        }
      }
      .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
      .wbFocusRing(isFocused, cornerRadius: DesignTokens.Radius.segment)
      .onHover { isHovered = $0 }
  }
}

/// Applies an accessibility label only when one is given, so an unlabelled
/// container does not read as an empty string.
private struct OptionalAccessibilityLabel: ViewModifier {
  let label: String?

  func body(content: Content) -> some View {
    if let label {
      content.accessibilityLabel(label)
    } else {
      content
    }
  }
}
