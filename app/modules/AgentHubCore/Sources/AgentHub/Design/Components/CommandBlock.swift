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

  /// True for a moment after a copy, to swap the icon to a check mark.
  @State private var didCopy = false

  public init(_ command: String) {
    self.command = command
  }

  public var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(command)
        .wbText(.code)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      IconButton(
        systemImage: didCopy ? "checkmark" : "doc.on.doc",
        isSmall: true,
        accessibilityLabel: didCopy ? "Copied" : "Copy command",
        action: copy
      )
      .help(didCopy ? "Copied" : "Copy command")
    }
    .padding(.leading, DesignTokens.Spacing.md)
    .padding(.trailing, DesignTokens.Spacing.xs)
    .frame(height: 32)
    .background(
      Color.wbSurfaceField,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .task(id: didCopy) {
      guard didCopy else { return }
      try? await Task.sleep(for: .seconds(1.5))
      didCopy = false
    }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    didCopy = true
    AccessibilityNotification.Announcement("Copied").post()
  }
}
