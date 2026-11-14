//
//  ShellToolbar.swift
//  AgentHub
//
//  TOOLBAR SLOT of the new shell: the 52 pt title row above the content panel
//  (`.titlebar` in the prototype). Destination tabs at the content column, a
//  flexible spacer, then Search, Standard | Warm and the light/dark button.
//  The row's structure never changes with the destination; only the selected
//  tab does. See Shell/README.md, "P12", for how the real traffic lights are
//  centred in this row.
//

import SwiftUI

/// Fixed positions from the prototype's window chrome.
enum ShellLayout {
  /// Leading padding of the title row while the sidebar is hidden, so its
  /// content clears the traffic lights (x 19–79) and the sidebar toggle,
  /// which AppKit places at x 100–128 (`ShellTitlebarToolbar`); 14 pt after
  /// the toggle, as in the prototype.
  static let collapsedToolbarLeading: CGFloat = 142
  /// Child minimums must fit the window minimum (CLAUDE.md, layout-loop
  /// crash). No split view is hosted in the shell any more: Reviews (P8) and
  /// the Sessions detail (P6, `SessionDetailLayout`) both fit 288 + 8 + their
  /// content minimum. `ReviewsLayoutTests` and `SessionDetailStateModelTests`
  /// check it. In the title row the trailing controls keep their size and
  /// the tabs truncate their titles when the row is short.
  static let windowMinWidth: CGFloat = 900
  static let windowMinHeight: CGFloat = 600
}

struct ShellToolbar: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      ShellDestinationTabs()
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Spacing.sm) {
        ShellSearchButton()
        ShellPaletteSwitch()
        ShellAppearanceButton()
      }
      .fixedSize()
    }
    .padding(.leading, shellModel.sidebarVisible ? 0 : ShellLayout.collapsedToolbarLeading)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: DesignTokens.Size.titlebar)
    .background(TitleBarDragArea())
  }
}

/// The toolbar search field (`.toolbar-search`). Opens the palette.
struct ShellSearchButton: View {
  @Environment(ShellOverlayModel.self) private var overlays
  @State private var isHovered = false

  var body: some View {
    Button {
      overlays.openPalette()
    } label: {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13))
          .foregroundStyle(Color.wbTextSecondary)
        Text("Search")
          .wbText(.body)
          .foregroundStyle(Color.wbTextPlaceholder)
        Spacer(minLength: 0)
        KeyCaps(["⌘", "K"])
      }
      .padding(.leading, DesignTokens.Spacing.sm)
      .padding(.trailing, DesignTokens.Spacing.xs)
      .frame(width: 168, height: DesignTokens.Size.control)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered ? Color.wbSurfacePressed : Color.wbSurfaceField,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .onHover { isHovered = $0 }
    .accessibilityLabel("Search")
    .accessibilityHint("Command K")
  }
}
