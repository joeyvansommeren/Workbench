//
//  WorkbenchField.swift
//  AgentHub
//
//  Text field with an icon. Matches `.field` in the prototype.
//

import SwiftUI

/// A styled text field with an optional leading icon. Shows the focus ring
/// while it has keyboard focus, so the user sees where typing goes.
public struct WorkbenchField: View {
  let placeholder: String
  @Binding var text: String
  let systemImage: String?
  let isSecure: Bool

  @FocusState private var isFocused: Bool

  /// - Parameter isSecure: Hide the text (API keys, tokens).
  public init(
    _ placeholder: String,
    text: Binding<String>,
    systemImage: String? = nil,
    isSecure: Bool = false
  ) {
    self.placeholder = placeholder
    self._text = text
    self.systemImage = systemImage
    self.isSecure = isSecure
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 13))
          .foregroundStyle(Color.wbTextSecondary)
      }
      input
        .textFieldStyle(.plain)
        .wbText(.body)
        .focused($isFocused)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.control)
    .background(
      Color.wbSurfaceField,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .wbFocusRing(isFocused, cornerRadius: DesignTokens.Radius.item)
  }

  @ViewBuilder
  private var input: some View {
    if isSecure {
      SecureField(placeholder, text: $text)
    } else {
      TextField(placeholder, text: $text)
    }
  }
}
