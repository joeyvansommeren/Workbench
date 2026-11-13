//
//  WorkbenchField.swift
//  AgentHub
//
//  Text field with an icon. Matches `.field` in the prototype.
//

import SwiftUI

/// A styled text field with an optional leading icon.
public struct WorkbenchField: View {
  let placeholder: String
  @Binding var text: String
  let systemImage: String?

  public init(
    _ placeholder: String,
    text: Binding<String>,
    systemImage: String? = nil
  ) {
    self.placeholder = placeholder
    self._text = text
    self.systemImage = systemImage
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 13))
          .foregroundStyle(Color.wbTextSecondary)
      }
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .wbText(.body)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.control)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
  }
}
