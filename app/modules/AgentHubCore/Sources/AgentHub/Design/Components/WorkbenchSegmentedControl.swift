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

  public init(selection: Binding<T>, showCounts: ((T) -> Int?)? = nil) {
    self._selection = selection
    self.showCounts = showCounts
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
  }

  @ViewBuilder
  private func segmentButton(for item: T) -> some View {
    let isSelected = selection == item

    Button {
      selection = item
    } label: {
      HStack(spacing: DesignTokens.Spacing.xsPlus) {
        Text(item.description)
        if let count = showCounts?(item) {
          Text("\(count)")
            .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextTertiary)
            .wbText(.subheadline)
            .fontWeight(.medium)
            .monospacedDigit()
        }
      }
    }
    .buttonStyle(.plain)
    .wbText(.callout)
    .fontWeight(.medium)
    .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(maxHeight: .infinity)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
          .fill(Color.wbSurfaceSegmentSelected)
          .wbElevation(.raised)
      }
    }
    .contentShape(Rectangle())
  }
}
