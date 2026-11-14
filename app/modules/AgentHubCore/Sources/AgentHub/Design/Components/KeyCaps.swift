//
//  KeyCaps.swift
//  AgentHub
//
//  Keyboard shortcut key caps. Matches `.keycap` and `.button-primary
//  .keycap` in the prototype.
//
//  Key caps stay on the system font: Inter has no ⌘ ⌥ ⇧ ↩ glyphs.
//

import SwiftUI

/// A single key cap, like "K" or "⌘".
public struct KeyCap: View {
  /// `.standard` on a surface; `.onAccent` inside a primary button.
  public enum Style: Sendable {
    case standard
    case onAccent
  }

  let text: String
  let style: Style
  let cornerRadius: CGFloat

  /// - Parameter cornerRadius: Pass `outer radius − inset` when the cap sits
  ///   near the edge of a rounded control, so the corners stay concentric.
  public init(_ text: String, style: Style = .standard, cornerRadius: CGFloat = DesignTokens.Radius.small) {
    self.text = text
    self.style = style
    self.cornerRadius = cornerRadius
  }

  public var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(style == .onAccent ? Color.wbTextOnAccent : Color.wbTextSecondary)
      .padding(.horizontal, DesignTokens.Spacing.xs)
      .frame(minWidth: 20, minHeight: 20)
      .background(
        style == .onAccent ? Color.black.opacity(0.22) : Color.wbSurfaceKeycap,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
  }
}

/// A row of key caps for a keyboard shortcut.
public struct KeyCaps: View {
  let keys: [String]
  let style: KeyCap.Style
  let cornerRadius: CGFloat

  public init(
    _ keys: [String],
    style: KeyCap.Style = .standard,
    cornerRadius: CGFloat = DesignTokens.Radius.small
  ) {
    self.keys = keys
    self.style = style
    self.cornerRadius = cornerRadius
  }

  /// A shortcut string like "⌘K", "⌃⌥Space" or "Esc".
  public init(_ shortcut: String, style: KeyCap.Style = .standard) {
    self.init(Self.split(shortcut), style: style)
  }

  /// One cap per modifier glyph, then the rest as one cap, so "Esc" stays
  /// one key instead of three.
  static func split(_ shortcut: String) -> [String] {
    let modifiers: Set<Character> = ["⌘", "⌥", "⇧", "⌃"]
    var keys: [String] = []
    var rest = Substring(shortcut)
    while let first = rest.first, modifiers.contains(first) {
      keys.append(String(first))
      rest = rest.dropFirst()
    }
    if !rest.isEmpty {
      keys.append(String(rest))
    }
    return keys
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
        KeyCap(key, style: style, cornerRadius: cornerRadius)
      }
    }
    .fixedSize()
  }
}
