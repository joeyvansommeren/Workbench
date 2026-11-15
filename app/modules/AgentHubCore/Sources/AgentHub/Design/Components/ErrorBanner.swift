//
//  ErrorBanner.swift
//  AgentHub
//
//  An error banner using the error status tokens.
//

import SwiftUI

/// A tinted error banner with an icon, a message, an optional action (for
/// example Retry) and an optional dismiss "x".
public struct ErrorBanner: View {
  /// A trailing button in the banner, such as "Retry".
  public struct Action {
    let title: String
    let perform: () -> Void

    public init(_ title: String, perform: @escaping () -> Void) {
      self.title = title
      self.perform = perform
    }
  }

  let message: String
  let action: Action?
  let onDismiss: (() -> Void)?

  public init(_ message: String, action: Action? = nil, onDismiss: (() -> Void)? = nil) {
    self.message = message
    self.action = action
    self.onDismiss = onDismiss
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 13))
        .foregroundStyle(Color.wbStatusErrorFill)

      // Raw CLI stderr can run long: cap it, keep the full text in the
      // tooltip, and let the user select and copy it.
      Text(message)
        .wbText(.body)
        .foregroundStyle(Color.wbStatusErrorText)
        .lineLimit(4)
        .textSelection(.enabled)
        .help(message)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let action {
        Button(action.title, action: action.perform)
          .buttonStyle(.wbSecondary)
          .fixedSize()
      }

      if let onDismiss {
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.wbStatusErrorText)
            .frame(
              width: DesignTokens.Size.controlSmall,
              height: DesignTokens.Size.controlSmall
            )
            .contentShape(Rectangle())
        }
        // The "x" keeps the error colour; hover and press add a fill.
        .buttonStyle(WBInlineButtonStyle(tintsLabel: false))
        .accessibilityLabel("Dismiss")
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      Color.wbStatusErrorTint,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    )
  }
}
