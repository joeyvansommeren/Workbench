//
//  ShellToolbar.swift
//  AgentHub
//
//  TOOLBAR SLOT of the new shell: the 52 pt title row above the content panel
//  (`.titlebar` in the prototype). Destination tabs at the content column, a
//  flexible spacer, then Search. The row's structure never changes with the
//  destination; only the selected tab does. Appearance and palette live in
//  Settings › Appearance and the palette's "Switch appearance". The sidebar
//  toggle is `ShellWindowControls`. See Shell/README.md, "P12" and "Title row
//  clicks".
//

import SwiftUI

/// Fixed positions from the prototype's window chrome.
enum ShellLayout {
  /// Leading edge of the sidebar toggle (`ShellWindowControls`): 15 pt
  /// right of the traffic lights, which AppKit puts at x 9–69 in a window
  /// without a toolbar (measured, `ShellTitleBarHitTests`).
  static let sidebarToggleLeading: CGFloat = 84
  /// The same in full screen, where the traffic lights hide.
  static let fullScreenSidebarToggleLeading: CGFloat = 8

  static func sidebarToggleLeading(isFullScreen: Bool) -> CGFloat {
    isFullScreen ? fullScreenSidebarToggleLeading : sidebarToggleLeading
  }

  /// Leading padding of the title row while the sidebar is hidden, so its
  /// content clears the traffic lights and the 28 pt sidebar toggle: 14 pt
  /// after the toggle, as in the prototype.
  static let collapsedToolbarLeading: CGFloat = sidebarToggleLeading + DesignTokens.Size.control + 14
  /// The same in full screen.
  static let fullScreenCollapsedToolbarLeading: CGFloat = fullScreenSidebarToggleLeading + DesignTokens.Size.control + 14

  /// Leading padding of the title row.
  static func toolbarLeading(sidebarVisible: Bool, isFullScreen: Bool) -> CGFloat {
    guard !sidebarVisible else { return 0 }
    return isFullScreen ? fullScreenCollapsedToolbarLeading : collapsedToolbarLeading
  }
  /// Child minimums must fit the window minimum (CLAUDE.md, layout-loop
  /// crash). No split view is hosted in the shell any more: Reviews (P8) and
  /// the Sessions detail (P6, `SessionDetailLayout`) both fit 288 + 8 + their
  /// content minimum. `ReviewsLayoutTests` and `SessionDetailStateModelTests`
  /// check it. In the title row Search keeps its size and the tabs truncate
  /// their titles when the row is short.
  static let windowMinWidth: CGFloat = 900
  static let windowMinHeight: CGFloat = 600
}

struct ShellToolbar: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      ShellDestinationTabs()
      Spacer(minLength: 0)
        .layoutPriority(-1)
      ShellSearchButton()
        .fixedSize()
        .layoutPriority(1)
    }
    .padding(
      .leading,
      ShellLayout.toolbarLeading(sidebarVisible: shellModel.sidebarVisible, isFullScreen: shellModel.isFullScreen)
    )
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
        // Field radius 8 − 4 pt inset, so the caps' corners stay concentric.
        KeyCaps(ShellShortcut.search.keyCaps, cornerRadius: 4)
      }
      .padding(.leading, DesignTokens.Spacing.sm)
      .padding(.trailing, DesignTokens.Spacing.xs)
      .frame(width: 168, height: DesignTokens.Size.control)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background {
      // Hover lays one hover step over the field; the pressed colour is
      // kept for presses, as on every other control.
      let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
      shape.fill(Color.wbSurfaceField)
        .overlay(shape.fill(isHovered ? Color.wbSurfaceHover : Color.clear))
    }
    .onHover { isHovered = $0 }
    .accessibilityLabel("Search")
    .accessibilityHint("Command K")
  }
}
