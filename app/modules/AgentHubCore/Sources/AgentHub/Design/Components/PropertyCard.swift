//
//  PropertyCard.swift
//  AgentHub
//
//  Matches `.property-card` and `.property-row` in the prototype.
//

import SwiftUI

/// A raised card with labelled property rows.
public struct PropertyCard<Content: View>: View {
  @ViewBuilder let content: () -> Content

  public init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  public var body: some View {
    VStack(spacing: 0) {
      content()
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .background(Color.wbSurfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.container))
    .wbElevation(.raised)
  }
}

/// A single row inside a PropertyCard.
public struct PropertyRow<ValueContent: View>: View {
  let label: String
  let systemImage: String?
  @ViewBuilder let value: () -> ValueContent

  public init(
    _ label: String,
    systemImage: String? = nil,
    @ViewBuilder value: @escaping () -> ValueContent
  ) {
    self.label = label
    self.systemImage = systemImage
    self.value = value
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(Color.wbTextSecondary)
        }
        Text(label)
          .foregroundStyle(Color.wbTextSecondary)
      }
      .frame(width: 108, alignment: .leading)

      Spacer(minLength: 0)

      value()
    }
    .wbText(.body)
    .frame(minHeight: 40)
    .overlay(alignment: .bottom) {
      Color.wbBorderHairline.frame(height: 1)
    }
  }
}
