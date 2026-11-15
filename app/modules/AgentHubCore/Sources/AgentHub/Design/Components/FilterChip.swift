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
  let accessibilityIdentifier: String?
  let onRemove: () -> Void

  public init(
    _ title: String,
    accessibilityIdentifier: String? = nil,
    onRemove: @escaping () -> Void
  ) {
    self.title = title
    self.accessibilityIdentifier = accessibilityIdentifier
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
          .frame(width: DesignTokens.Size.controlSmall, height: DesignTokens.Size.controlSmall)
          .contentShape(Rectangle())
      }
      // Hover tints the "x" only, as the prototype does; press adds a fill.
      .buttonStyle(WBInlineButtonStyle(hoverFill: false))
      .accessibilityLabel("Remove filter \(title)")
    }
    .frame(height: DesignTokens.Size.controlSmall)
    .background(Color.wbSurfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.segment, style: .continuous))
    .wbElevation(.control, cornerRadius: DesignTokens.Radius.segment)
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }
}

/// A "Filters" button with an active count and a clear action.
public struct FiltersButton: View {
  let activeCount: Int
  let accessibilityIdentifier: String?
  let onOpen: () -> Void
  let onClear: () -> Void

  public init(
    activeCount: Int,
    accessibilityIdentifier: String? = nil,
    onOpen: @escaping () -> Void,
    onClear: @escaping () -> Void
  ) {
    self.activeCount = activeCount
    self.accessibilityIdentifier = accessibilityIdentifier
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
            CountBadge(activeCount, style: .accent)
          }
        }
        .padding(.leading, DesignTokens.Spacing.smPlus)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Size.control)
        .contentShape(Rectangle())
      }
      .buttonStyle(WBInlineButtonStyle(tintsLabel: false, cornerRadius: 0))

      if activeCount > 0 {
        Divider()
          .frame(height: DesignTokens.Size.tile)
          .overlay(Color.wbBorderHairline)

        Button(action: onClear) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .medium))
            .frame(width: 28, height: DesignTokens.Size.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(WBInlineButtonStyle(cornerRadius: 0))
        .accessibilityLabel("Clear filters")
      }
    }
    .background(Color.wbSurfaceControl)
    // The halves' hover fills are square; the outer shape rounds them.
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous))
    .wbElevation(.control)
    .optionalAccessibilityIdentifier(accessibilityIdentifier)
  }
}
