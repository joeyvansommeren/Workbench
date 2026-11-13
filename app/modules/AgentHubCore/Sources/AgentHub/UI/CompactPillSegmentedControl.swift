//
//  CompactPillSegmentedControl.swift
//  AgentHub
//

import SwiftUI

public struct CompactPillSegmentedControlItem<Value: Hashable>: Identifiable {
  public let value: Value
  public let title: String
  public let helpText: String?

  public var id: AnyHashable {
    AnyHashable(value)
  }

  public init(
    value: Value,
    title: String,
    helpText: String? = nil
  ) {
    self.value = value
    self.title = title
    self.helpText = helpText
  }
}

public struct CompactPillSegmentedControl<Value: Hashable>: View {
  private static var controlHeight: CGFloat { 26 }
  private static var selectedPillVerticalInset: CGFloat { 2 }

  @Binding private var selection: Value
  private let items: [CompactPillSegmentedControlItem<Value>]
  private let selectedColor: Color
  private let textColor: Color
  private let accessibilityLabel: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Namespace private var selectionNamespace

  public init(
    selection: Binding<Value>,
    items: [CompactPillSegmentedControlItem<Value>],
    selectedColor: Color = .brandSecondary,
    textColor: Color = .secondary,
    accessibilityLabel: String = "Segmented control"
  ) {
    self._selection = selection
    self.items = items
    self.selectedColor = selectedColor
    self.textColor = textColor
    self.accessibilityLabel = accessibilityLabel
  }

  @Environment(\.runtimeTheme) private var runtimeTheme

  public var body: some View {
    HStack(spacing: 2) {
      ForEach(items) { item in
        segmentButton(for: item)
      }
    }
    .padding(3)
    .frame(height: Self.controlHeight)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
        .fill(Color.primary.opacity(0.045))
    )
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func segmentButton(for item: CompactPillSegmentedControlItem<Value>) -> some View {
    let isSelected = selection == item.value

    return Button {
      withAnimation(selectionAnimation) {
        selection = item.value
      }
    } label: {
      Text(item.title)
        .font(.geist(size: 11, weight: isSelected ? .semibold : .medium))
        .lineLimit(1)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(height: Self.controlHeight - (Self.selectedPillVerticalInset * 2))
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous)
              .fill(Color.surfaceCard)
              .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous)
                  .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
              )
              .matchedGeometryEffect(id: "selected-pill", in: selectionNamespace)
          }
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm + 1, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(item.helpText ?? item.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var selectionAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
  }
}
