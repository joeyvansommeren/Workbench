//
//  ShellToolbar.swift
//  AgentHub
//
//  TOOLBAR SLOT of the new shell: the custom 52 pt title row above the
//  content panel (Variant B, see Shell/README.md). The row's structure never
//  changes; a destination change only swaps the leading content.
//
//  P6 replaces `ShellSessionsToolbarContent` with the session tab strip.
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
  /// Child minimums must fit the window minimum, or NSSplitView can loop
  /// (CLAUDE.md, layout-loop crash). The hosted legacy `GitHubReviewsView`
  /// needs 992: its `NavigationSplitView` sidebar column (min 260) + divider 1
  /// + the PR `HSplitView` (350 + divider 1 + 380). With the 288 shell sidebar
  /// and the 8 trailing panel inset: 288 + 992 + 8 = 1288.
  /// P8 lowers this to 900 when it replaces Reviews.
  static let windowMinWidth: CGFloat = 1288
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
      ShellSessionsToolbarContent(onNewSession: onNewSession)
    case .reviews:
      ShellToolbarTitle(text: "Reviews")
    case .sprint:
      ShellSprintToolbarContent()
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

/// P6 replaces this with the session tab strip.
private struct ShellSessionsToolbarContent: View {
  let onNewSession: () -> Void

  var body: some View {
    IconButton(
      systemImage: "plus",
      accessibilityLabel: "New session",
      accessibilityIdentifier: "shell.newSession",
      action: onNewSession
    )
    .help("New session  ⌘N")
  }
}

private struct ShellSprintToolbarContent: View {
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      ShellToolbarTitle(text: "Sprint")
      WorkbenchSegmentedControl(
        selection: Binding(
          get: { shellModel.sprintTracker },
          set: { shellModel.setSprintTracker($0) }
        ),
        accessibilityIdentifier: "shell.sprintTracker"
      )
      .fixedSize()
    }
  }
}

/// The toolbar search field (`.toolbar-search`). Opens the palette.
private struct ShellSearchButton: View {
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
