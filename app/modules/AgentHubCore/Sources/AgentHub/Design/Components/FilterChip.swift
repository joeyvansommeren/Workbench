//
//  FilterChip.swift
//  AgentHub
//
//  Matches `.filter-chip` and `.filters-button` in the prototype.
//

import SwiftUI

/// A removable filter chip.
public struct FilterChip: View {
  let title: String
  let onRemove: () -> Void

  public init(_ title: String, onRemove: @escaping () -> Void) {
    self.title = title
    self.onRemove = onRemove
  }

  public var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .wbText(.callout)
        .fontWeight(.medium)
        .padding(.leading, DesignTokens.Spacing.sm)

      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.wbTextSecondary)
          .frame(width: DesignTokens.Size.controlSmall, height: DesignTokens.Size.controlSmall)
      }
      .buttonStyle(.plain)
    }
    .frame(height: DesignTokens.Size.controlSmall)
    .background(Color.wbSurfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.segment))
    .wbElevation(.control)
  }
}

/// A "Filters" button with an active count and a clear action.
public struct FiltersButton: View {
  let activeCount: Int
  let onOpen: () -> Void
  let onClear: () -> Void

  public init(activeCount: Int, onOpen: @escaping () -> Void, onClear: @escaping () -> Void) {
    self.activeCount = activeCount
    self.onOpen = onOpen
    self.onClear = onClear
  }

  public var body: some View {
    HStack(spacing: 0) {
      Button(action: onOpen) {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 12))
          Text("Filters")
            .wbText(.bodyEmphasis)
          if activeCount > 0 {
            Text("\(activeCount)")
              .font(.system(size: 11, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(Color.wbTextOnAccent)
              .frame(minWidth: 18, minHeight: 18)
              .padding(.horizontal, DesignTokens.Spacing.xs)
              .background(Color.wbAccent, in: Capsule())
          }
        }
        .padding(.leading, DesignTokens.Spacing.smPlus)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Size.control)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if activeCount > 0 {
        Divider()
          .frame(height: 18)
          .overlay(Color.wbBorderHairline)

        Button(action: onClear) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.wbTextSecondary)
            .frame(width: 28, height: DesignTokens.Size.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(Color.wbSurfaceControl, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .wbElevation(.control)
  }
}
