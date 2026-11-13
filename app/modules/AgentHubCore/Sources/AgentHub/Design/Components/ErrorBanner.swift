//
//  ErrorBanner.swift
//  AgentHub
//
//  An error banner using the error status tokens.
//

import SwiftUI

/// A tinted error banner with an icon and a message.
public struct ErrorBanner: View {
  let message: String
  let onDismiss: (() -> Void)?

  public init(_ message: String, onDismiss: (() -> Void)? = nil) {
    self.message = message
    self.onDismiss = onDismiss
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 13))
        .foregroundStyle(Color.wbStatusErrorFill)

      Text(message)
        .wbText(.body)
        .foregroundStyle(Color.wbStatusErrorText)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.wbStatusErrorText)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(Color.wbStatusErrorTint, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
  }
}
