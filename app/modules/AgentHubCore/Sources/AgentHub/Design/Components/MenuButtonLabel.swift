//
//  MenuButtonLabel.swift
//  AgentHub
//
//  The label of a menu button: control surface, optional leading content,
//  title, trailing chevron. Matches `.popup-button` in the prototype.
//
//  Use it as the label of a plain `Menu`:
//
//    Menu { … } label: { WBMenuButtonLabel("Actions") }
//      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
//

import SwiftUI

/// A control-surface menu button label with a chevron. Hover changes colour
/// only.
public struct WBMenuButtonLabel<Leading: View>: View {
  /// 28 pt (`.regular`, body text) or 24 pt (`.small`, callout text).
  public enum Size: Sendable {
    case regular
    case small
  }

  let title: String
  let size: Size
  let isMonospaced: Bool
  let leading: Leading

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  /// - Parameters:
  ///   - isMonospaced: Code text (branch and worktree names).
  ///   - leading: Content before the title, for example a `LetterTile`.
  public init(
    _ title: String,
    size: Size = .regular,
    isMonospaced: Bool = false,
    @ViewBuilder leading: () -> Leading
  ) {
    self.title = title
    self.size = size
    self.isMonospaced = isMonospaced
    self.leading = leading()
  }

  public var body: some View {
    let radius = size == .small ? DesignTokens.Radius.segment : DesignTokens.Radius.item
    HStack(spacing: size == .small ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm) {
      leading
      titleText
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
      Image(systemName: "chevron.down")
        // 9 pt on 28 pt controls, 8 pt on 24 pt controls.
        .font(.system(size: size == .small ? 8 : 9, weight: .semibold))
        .foregroundStyle(Color.wbTextSecondary)
        .padding(.leading, size == .small ? 0 : DesignTokens.Spacing.xs)
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: size == .small ? DesignTokens.Size.controlSmall : DesignTokens.Size.control)
    .background(
      isHovered && isEnabled ? Color.wbSurfaceControlHover : Color.wbSurfaceControl,
      in: RoundedRectangle(cornerRadius: radius, style: .continuous)
    )
    .wbElevation(.control, cornerRadius: radius)
    .opacity(isEnabled ? 1 : DesignTokens.Opacity.disabled)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }

  @ViewBuilder
  private var titleText: some View {
    switch (size, isMonospaced) {
    case (_, true):
      Text(title).wbText(.code)
    case (.regular, false):
      Text(title).wbText(.body)
    case (.small, false):
      Text(title).wbText(.callout).fontWeight(.medium)
    }
  }
}

extension WBMenuButtonLabel where Leading == EmptyView {
  /// A menu button label with a title only.
  public init(_ title: String, size: Size = .regular, isMonospaced: Bool = false) {
    self.init(title, size: size, isMonospaced: isMonospaced) { EmptyView() }
  }
}
