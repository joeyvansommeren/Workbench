//
//  CountBadge.swift
//  AgentHub
//
//  Matches `.count-badge` in the prototype.
//

import SwiftUI

/// A small pill with a number.
public struct CountBadge: View {
  let count: Int

  public init(_ count: Int) {
    self.count = count
  }

  public var body: some View {
    Text("\(count)")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .foregroundStyle(Color.wbTextSecondary)
      .frame(minWidth: 18, minHeight: 18)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .background(Color.wbSurfaceKeycap, in: Capsule())
      .fixedSize()
  }
}
