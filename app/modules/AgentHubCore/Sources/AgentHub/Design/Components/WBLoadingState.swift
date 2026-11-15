//
//  WBLoadingState.swift
//  AgentHub
//
//  The loading state of a destination: a small spinner, centred in the space
//  the content will fill. Sits where `WBEmptyState` sits once loading ends.
//

import SwiftUI

/// A centred small spinner. `title` is always read by VoiceOver; it shows
/// under the spinner only when `showsTitle` is true (most screens need no
/// visible label).
public struct WBLoadingState: View {
  let title: String
  let showsTitle: Bool

  public init(_ title: String, showsTitle: Bool = false) {
    self.title = title
    self.showsTitle = showsTitle
  }

  public var body: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      ProgressView()
        .controlSize(.small)
      if showsTitle {
        Text(title)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}
