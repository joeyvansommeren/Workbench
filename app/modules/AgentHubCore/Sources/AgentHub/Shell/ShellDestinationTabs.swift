//
//  ShellDestinationTabs.swift
//  AgentHub
//
//  The destination tabs in the title row: Sessions, Reviews, Jira, Linear.
//  Same look as the P6 session tabs (`.tab` in the prototype): lead icon,
//  title, and a raised pill for the selected tab. Reviews, Jira and Linear
//  show a count. No close buttons and no "+": ⌘N and the palette start
//  sessions.
//
//  Layout-loop safety: tabs hug their content and never measure anything.
//  When the full titles do not fit (900 pt window), `ViewThatFits` shows the
//  tabs as icon and count, then icon only. It picks from the proposed width
//  alone, so nothing feeds back into the layout. The row reports no minimum
//  width (`minWidth: 0`) and gives way to the trailing controls, so it can
//  never push a minimum size into the hosting view.
//

import SwiftUI

struct ShellDestinationTabs: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    let counts = destinationCounts
    ViewThatFits(in: .horizontal) {
      tabs(counts: counts, showsTitles: true, showsCounts: true)
      tabs(counts: counts, showsTitles: false, showsCounts: true)
      tabs(counts: counts, showsTitles: false, showsCounts: false)
    }
    .frame(minWidth: 0, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Destinations")
  }

  private func tabs(counts: ShellDestinationCounts, showsTitles: Bool, showsCounts: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      ForEach(ShellDestination.allCases, id: \.self) { destination in
        ShellDestinationTab(
          destination: destination,
          count: showsCounts ? counts.count(for: destination) : nil,
          accessibilityCount: counts.count(for: destination),
          showsTitle: showsTitles,
          isSelected: shellModel.destination == destination,
          onSelect: { shellModel.select(destination) }
        )
      }
    }
  }

  private var destinationCounts: ShellDestinationCounts {
    guard let agentHub else {
      return ShellDestinationCounts(reviewQueueCount: 0, jiraOpenTicketCount: 0, linearOpenIssueCount: 0)
    }
    return ShellDestinationCounts(
      reviewQueueCount: agentHub.gitHubReviewsViewModel.count(for: .requested),
      jiraOpenTicketCount: agentHub.jiraSprintViewModel.myOpenTicketCount,
      linearOpenIssueCount: agentHub.linearViewModel.myOpenIssueCount
    )
  }
}

struct ShellDestinationTab: View {
  let destination: ShellDestination
  let count: Int?
  /// Spoken even when the count is not drawn (icon-only row).
  var accessibilityCount: Int?
  /// False in a short title row: icon and count only (title in the tooltip).
  var showsTitle = true
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        ShellDestinationIcon(destination: destination)
        if showsTitle {
          Text(destination.title)
            .wbText(.bodyEmphasis)
            .lineLimit(1)
        }
        if let count {
          Text("\(count)")
            .wbText(.callout)
            .monospacedDigit()
            .foregroundStyle(Color.wbTextSecondary)
            .fixedSize()
        }
      }
      .padding(.leading, DesignTokens.Spacing.sm)
      .padding(.trailing, DesignTokens.Spacing.smPlus)
      // Control height, not tab height: the pill fits the title band with
      // room above and below it.
      .frame(height: DesignTokens.Size.control)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // Fixed intrinsic size: the sidebar animation moves the tabs, it never
    // truncates or resizes them (motion plan item 7).
    .fixedSize()
    .foregroundStyle(isSelected || isHovered ? Color.wbTextPrimary : Color.wbTextSecondary)
    .background { background }
    .onHover { isHovered = $0 }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("shell.tab.\(destination.rawValue)")
    .help("\(destination.title)  \(destination.shortcut.keyCaps.joined())")
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    if isSelected {
      shape.fill(Color.wbSurfaceRaised)
        .wbElevation(.raised, cornerRadius: DesignTokens.Radius.row)
    } else if isHovered {
      shape.fill(Color.wbSurfaceHover)
    }
  }

  private var accessibilityLabel: String {
    guard let count = accessibilityCount ?? count else { return destination.title }
    return "\(destination.title), \(count)"
  }
}

/// The tab's lead icon in a fixed 16 pt frame: a terminal for Sessions, the
/// pull-request glyph for Reviews, the board for Jira and Linear (there are
/// no tracker logos in the app).
private struct ShellDestinationIcon: View {
  let destination: ShellDestination

  var body: some View {
    Group {
      switch destination {
      case .sessions:
        Image(systemName: "terminal")
          .font(.system(size: 12))
      case .reviews:
        PullRequestGlyph()
      case .jira, .linear:
        SidebarIcon(glyph: .board)
      }
    }
    .frame(width: DesignTokens.Size.icon, height: DesignTokens.Size.icon)
    .fixedSize()
    .accessibilityHidden(true)
  }
}
