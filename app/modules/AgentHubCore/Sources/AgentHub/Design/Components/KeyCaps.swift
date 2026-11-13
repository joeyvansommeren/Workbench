//
//  KeyCaps.swift
//  AgentHub
//
//  Keyboard shortcut key caps. Matches `.keycap` in the prototype.
//

import SwiftUI

/// A single key cap, like "K" or "⌘".
public struct KeyCap: View {
  let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .monospacedDigit()
      .foregroundStyle(Color.wbTextSecondary)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .frame(minWidth: 20, minHeight: 20)
      .background(Color.wbSurfaceKeycap, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
  }
}

/// A row of key caps for a keyboard shortcut.
public struct KeyCaps: View {
  let keys: [String]

  public init(_ keys: [String]) {
    self.keys = keys
  }

  /// Convenience for common shortcuts like "⌘K".
  public init(_ shortcut: String) {
    // Split into individual characters for display
    self.keys = shortcut.map(String.init)
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
        KeyCap(key)
      }
    }
    .fixedSize()
  }
}
