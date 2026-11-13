//
//  CommandBlock.swift
//  AgentHub
//
//  Matches `.command-block` in the prototype.
//

import SwiftUI

/// A monospaced command block with a copy button.
public struct CommandBlock: View {
  let command: String

  public init(_ command: String) {
    self.command = command
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(command)
        .wbText(.code)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
          .font(.system(size: 11))
          .foregroundStyle(Color.wbTextSecondary)
          .frame(
            width: DesignTokens.Size.controlSmall,
            height: DesignTokens.Size.controlSmall
          )
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, DesignTokens.Spacing.md)
    .padding(.trailing, DesignTokens.Spacing.xs)
    .frame(height: 32)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
  }
}
