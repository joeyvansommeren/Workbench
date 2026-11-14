//
//  SprintDestinationLayout.swift
//  AgentHub
//
//  Frame shared by the Jira and Linear Sprint destinations: list head, an
//  optional banner, the content, and the ticket detail as a fixed-width
//  trailing panel. A plain HStack, never `.inspector` (NSSplitView-backed,
//  see CLAUDE.md "Layout-Loop Crash").
//

import SwiftUI

/// Sprint widths. With a ticket open at the 900 pt window minimum the board
/// keeps one readable column (`SprintLayoutTests`); more columns scroll.
enum SprintLayout {
  /// Width of the ticket detail panel.
  static let detailWidth: CGFloat = 380
  static let hairlineWidth: CGFloat = 1
  /// A column never gets narrower than this. Below it the board scrolls
  /// sideways instead of squeezing the cards. 170 lets four columns sit next
  /// to the detail in a 1440 pt window.
  static let columnMinWidth: CGFloat = 170
  /// Horizontal padding around the board's columns.
  static let boardInset: CGFloat = DesignTokens.Spacing.lg

  /// The narrowest board that still shows one whole column.
  static var boardMinWidth: CGFloat { columnMinWidth + 2 * boardInset }

  /// The narrowest content panel Sprint fits in, with the detail open.
  static var minimumContentWidth: CGFloat { boardMinWidth + hairlineWidth + detailWidth }
}

struct SprintDestinationLayout<ListHead: View, Content: View, Detail: View>: View {
  let isDetailVisible: Bool
  @ViewBuilder let listHead: ListHead
  @ViewBuilder let content: Content
  @ViewBuilder let detail: Detail

  /// True once no ticket was open while this destination was on screen: only
  /// then does the detail entrance run (not on ⌘3/⌘4 or at launch).
  @State private var detailWasClosed = false

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        listHead
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
      if isDetailVisible {
        Rectangle()
          .fill(Color.wbBorderHairline)
          .frame(width: SprintLayout.hairlineWidth)
        detail
          // Contents only; the hairline and the width appear at once.
          .wbPanelEntrance(animates: detailWasClosed)
          .frame(width: SprintLayout.detailWidth)
          .frame(maxHeight: .infinity)
      }
    }
    .wbTracksPanelOpen(isOpen: isDetailVisible, wasClosed: $detailWasClosed)
  }
}

/// A loading placeholder that does not animate (no layout passes while hidden).
struct SprintLoadingView: View {
  var body: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel("Loading sprint")
  }
}

/// Result of a status move, a sync or a failed refresh. Errors use
/// `ErrorBanner` and stay until dismissed, so a rolled-back move is never
/// missed; confirmations are a quiet line that dismisses itself.
struct SprintNoticeView: View {
  let text: String
  let isError: Bool
  /// Shown as a Retry button next to the error (a failed refresh).
  var onRetry: (() -> Void)?
  let onDismiss: () -> Void

  var body: some View {
    Group {
      if isError {
        HStack(spacing: DesignTokens.Spacing.sm) {
          ErrorBanner(text, onDismiss: onDismiss)
          if let onRetry {
            Button("Retry", action: onRetry)
              .buttonStyle(.wbSecondary)
              .fixedSize()
          }
        }
      } else {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.wbStatusReadyText)
          Text(text)
            .wbText(.callout)
            .foregroundStyle(Color.wbTextSecondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .frame(height: DesignTokens.Size.controlSmall)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.bottom, DesignTokens.Spacing.sm)
    .task(id: text) {
      // The notice can disappear on its own; VoiceOver users hear it.
      AccessibilityNotification.Announcement(text).post()
      guard !isError else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      onDismiss()
    }
  }
}

/// Filters hide every ticket: the buttons that undo them, instead of a
/// sentence telling the user where to click.
struct SprintNoMatchesView: View {
  let title: String
  /// Nil when no search or person filter is on.
  let onClearFilters: (() -> Void)?
  /// Nil unless the head is set to Mine.
  let onShowAll: (() -> Void)?

  var body: some View {
    WBEmptyState(systemImage: "line.3.horizontal.decrease", title: title) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if let onClearFilters {
          Button("Clear filters", action: onClearFilters)
            .buttonStyle(.wbSecondary)
        }
        if let onShowAll {
          Button("Show all") {
            onShowAll()
            MainThreadStallMonitor.breadcrumb("sprint filter: all")
          }
          .buttonStyle(.wbSecondary)
        }
      }
    }
  }
}

/// A refresh control: the icon button, or a spinner of the same size while
/// the tracker loads, so the head never shifts.
struct SprintRefreshButton: View {
  let isLoading: Bool
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    if isLoading {
      ProgressView()
        .controlSize(.small)
        .frame(width: DesignTokens.Size.control, height: DesignTokens.Size.control)
        .accessibilityLabel("Refreshing")
    } else {
      IconButton(
        systemImage: "arrow.clockwise",
        accessibilityLabel: accessibilityLabel,
        accessibilityIdentifier: "sprint.refresh",
        action: action
      )
      .help("\(accessibilityLabel)  \(ShellShortcut.refresh.keyCaps.joined())")
      .keyboardShortcut(ShellShortcut.refresh)
    }
  }
}

/// Error text for an empty or failure state: the first line of a CLI or API
/// message, capped, so raw stderr never floods the screen.
enum SprintErrorText {
  static let maxLength = 160

  static func summary(_ message: String) -> String {
    let firstLine =
      message.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    guard firstLine.count > maxLength else { return firstLine }
    return String(firstLine.prefix(maxLength - 1)) + "…"
  }
}

/// Arrow-key movement on a board. Shared by the Jira and Linear view models,
/// so both boards move the same way.
public enum SprintMoveDirection { case up, down, left, right }

enum SprintBoardNavigation {
  /// The ticket to select next, or nil when the selection stays. Up and down
  /// move within a column; left and right go to the nearest non-empty column
  /// at the same row. Nothing selected yet: the first ticket.
  static func target(
    columns: [[String]], selected: String?, direction: SprintMoveDirection
  ) -> String? {
    let columns = columns.filter { !$0.isEmpty }
    guard let first = columns.first?.first else { return nil }
    guard
      let selected,
      let column = columns.firstIndex(where: { $0.contains(selected) }),
      let row = columns[column].firstIndex(of: selected)
    else { return first }
    var target = (column: column, row: row)
    switch direction {
    case .up: target.row = max(row - 1, 0)
    case .down: target.row = min(row + 1, columns[column].count - 1)
    case .left: target.column = max(column - 1, 0)
    case .right: target.column = min(column + 1, columns.count - 1)
    }
    target.row = min(target.row, columns[target.column].count - 1)
    let next = columns[target.column][target.row]
    return next == selected ? nil : next
  }
}

/// Picks the agent for the card's "Start session": Claude Code when it is
/// installed, else Codex. The detail panel still offers both.
enum SprintStartProvider {
  static func preferred(isClaudeAvailable: Bool, isCodexAvailable: Bool) -> SessionProviderKind? {
    if isClaudeAvailable { return .claude }
    if isCodexAvailable { return .codex }
    return nil
  }

  /// The detail panel names the agent; a card's Start leaves it to `preferred`.
  static func resolve(
    _ explicit: SessionProviderKind?, isClaudeAvailable: Bool, isCodexAvailable: Bool
  ) -> SessionProviderKind? {
    explicit ?? preferred(isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable)
  }
}
