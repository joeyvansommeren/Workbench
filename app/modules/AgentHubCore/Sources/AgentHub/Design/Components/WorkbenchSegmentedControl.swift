//
//  WorkbenchSegmentedControl.swift
//  AgentHub
//
//  Segmented control matching `.segmented` in the prototype.
//  Segments sit in a field background with inset radius nesting.
//

import SwiftUI

/// A segmented control where each segment can have a title, an optional
/// count, and an optional icon.
public struct WorkbenchSegmentedControl<T: Hashable & CaseIterable & CustomStringConvertible>: View
where T.AllCases: RandomAccessCollection {

  @Binding var selection: T
  let showCounts: ((T) -> Int?)?
  let accessibilityIdentifier: String?

  public init(
    selection: Binding<T>,
    showCounts: ((T) -> Int?)? = nil,
    accessibilityIdentifier: String? = nil
  ) {
    self._selection = selection
    self.showCounts = showCounts
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(Array(T.allCases), id: \.self) { item in
        segmentButton(for: item)
      }
    }
    .padding(DesignTokens.Inset.control)
    .frame(height: DesignTokens.Size.control)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
  }

  @ViewBuilder
  private func segmentButton(for item: T) -> some View {
    let isSelected = selection == item
    let count = showCounts?(item)

    Button {
      selection = item
    } label: {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        Text(item.description)
        if let count {
          Text("\(count)")
            .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextTertiary)
            .wbText(.subheadline)
            .fontWeight(.medium)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .wbText(.callout)
    .fontWeight(.medium)
    .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
          .fill(Color.wbSurfaceSegmentSelected)
          .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
      }
    }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityLabel(segmentLabel(item: item, count: count))
    .accessibilityIdentifier(accessibilityIdentifier.map { "\($0).\(item.description)" } ?? "")
  }

  private func segmentLabel(item: T, count: Int?) -> String {
    if let count {
      return "\(item.description), \(count)"
    }
    return item.description
  }
}
