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
  /// (CLAUDE.md, layout-loop crash). The widest child is the legacy Sessions
  /// workflow comparison, still hosted in the shell: an `HSplitView` with two
  /// 420 pt panes, plus the shell sidebar and the trailing panel inset.
  /// P6 lowers this to 900. `ReviewsLayoutTests` checks that Reviews fits.
  static let windowMinWidth: CGFloat = 1137
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

/// The toolbar search field (`.toolbar-search`). Opens the palette (P10).
private struct ShellSearchButton: View {
  @State private var isHovered = false

  var body: some View {
    Button {
      // TODO(P10): open the new command palette.
      MainThreadStallMonitor.breadcrumb("palette: open")
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
