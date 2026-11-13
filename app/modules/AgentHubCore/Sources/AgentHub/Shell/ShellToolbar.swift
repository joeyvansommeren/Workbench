//
//  ShellToolbar.swift
//  AgentHub
//
//  TOOLBAR SLOT of the new shell: the custom 52 pt title row above the
//  content panel (Variant B, see Shell/README.md). The row's structure never
//  changes; a destination change only swaps the leading content.
//
//  Sessions shows the P6 tab strip (`SessionsToolbarContent`).
//  P8 and P9 may replace the Reviews and Sprint titles.
//

import SwiftUI

/// Fixed positions from the prototype's window chrome.
enum ShellLayout {
  /// Leading edge of the sidebar toggle, just right of the traffic lights.
  static let sidebarToggleLeading: CGFloat = 84
  /// Leading padding of the title row while the sidebar is hidden, so its
  /// content clears the traffic lights and the sidebar toggle.
  static let collapsedToolbarLeading: CGFloat = 132
  /// Child minimums must fit the window minimum (CLAUDE.md, layout-loop
  /// crash). No split view is hosted in the shell any more: Reviews (P8) and
  /// the Sessions detail (P6, `SessionDetailLayout`) both fit 288 + 8 + their
  /// content minimum. `ReviewsLayoutTests` and `SessionTabsModelTests` check it.
  static let windowMinWidth: CGFloat = 900
  static let windowMinHeight: CGFloat = 600
}

struct ShellToolbar: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  let onNewSession: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      leadingContent
        .frame(maxWidth: .infinity, alignment: .leading)
      ShellSearchButton()
    }
    .padding(.leading, shellModel.sidebarVisible ? 0 : ShellLayout.collapsedToolbarLeading)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: DesignTokens.Size.titlebar)
    .background(TitleBarDragArea())
  }

  @ViewBuilder
  private var leadingContent: some View {
    switch shellModel.destination {
    case .sessions:
      SessionsToolbarContent(onNewSession: onNewSession)
    case .reviews:
      ShellToolbarTitle(text: "Reviews")
    case .sprint:
      SprintToolbarContent()
    }
  }
}

/// The window controls next to the traffic lights: the sidebar toggle. It
/// stays put when the sidebar hides, like `.window-controls` in the prototype.
struct ShellWindowControls: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    IconButton(
      systemImage: "sidebar.left",
      accessibilityLabel: shellModel.sidebarVisible ? "Hide sidebar" : "Show sidebar",
      accessibilityIdentifier: "shell.toggleSidebar"
    ) {
      shellModel.toggleSidebar()
    }
    .help(shellModel.sidebarVisible ? "Hide sidebar  ⌃⌘S" : "Show sidebar  ⌃⌘S")
    .padding(.leading, ShellLayout.sidebarToggleLeading)
    .frame(height: DesignTokens.Size.titlebar)
  }
}

private struct ShellToolbarTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .wbText(.title3)
      .foregroundStyle(Color.wbTextPrimary)
      .lineLimit(1)
      .fixedSize()
      .padding(.leading, DesignTokens.Spacing.sm)
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
