//
//  Avatar.swift
//  AgentHub
//
//  Avatar circle and person chip. Matches `.avatar` and `.person-chip`.
//

import SwiftUI

/// A circle with initials. 20 pt by default; 18 pt lines up with a
/// `LetterTile` in the same row.
///
/// Hidden from VoiceOver: the full name always sits next to it, so the
/// initials would only be read twice.
public struct WBAvatar: View {
  let initials: String
  let size: CGFloat

  public init(initials: String, size: CGFloat = 20) {
    self.initials = String(initials.prefix(2)).uppercased()
    self.size = size
  }

  public var body: some View {
    Text(initials)
      // Prototype `.avatar`: Inter 600 9px, letter-spacing 0.02em.
      .font(WorkbenchTypography.uiFont(size: 9, weight: .semibold))
      .tracking(0.02 * 9)
      .foregroundStyle(Color.wbTextSecondary)
      .frame(width: size, height: size)
      .background(Color.wbSurfaceRaised, in: Circle())
      .overlay {
        Circle()
          .strokeBorder(Color.wbBorderControl, lineWidth: 0.5)
      }
      .fixedSize()
      .accessibilityHidden(true)
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
