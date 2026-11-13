//
//  Avatar.swift
//  AgentHub
//
//  Avatar circle and person chip. Matches `.avatar` and `.person-chip`.
//

import SwiftUI

/// A 20 pt circle with initials.
public struct WBAvatar: View {
  let initials: String

  public init(initials: String) {
    self.initials = String(initials.prefix(2)).uppercased()
  }

  public var body: some View {
    Text(initials)
      .font(.system(size: 9, weight: .semibold))
      .tracking(0.02 * 9)
      .foregroundStyle(Color.wbTextSecondary)
      .frame(width: 20, height: 20)
      .background(Color.wbSurfaceRaised, in: Circle())
      .overlay {
        Circle()
          .strokeBorder(Color.wbBorderControl, lineWidth: 0.5)
      }
      .fixedSize()
  }
}

/// A chip with an avatar and a name.
public struct PersonChip: View {
  let initials: String
  let name: String

  public init(initials: String, name: String) {
    self.initials = initials
    self.name = name
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      WBAvatar(initials: initials)
      Text(name)
        .wbText(.callout)
        .fontWeight(.medium)
    }
    .padding(.leading, DesignTokens.Spacing.xxs)
    .padding(.trailing, DesignTokens.Spacing.sm)
    .frame(height: DesignTokens.Size.controlSmall)
    .background(Color.wbSurfaceField, in: Capsule())
  }
}
