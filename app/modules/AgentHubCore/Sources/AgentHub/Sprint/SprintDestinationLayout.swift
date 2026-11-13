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

enum SprintLayout {
  /// Width of the ticket detail panel.
  static let detailWidth: CGFloat = 380
}

struct SprintDestinationLayout<ListHead: View, Content: View, Detail: View>: View {
  let isDetailVisible: Bool
  @ViewBuilder let listHead: ListHead
  @ViewBuilder let content: Content
  @ViewBuilder let detail: Detail

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
          .frame(width: 1)
        detail
          .frame(width: SprintLayout.detailWidth)
          .frame(maxHeight: .infinity)
      }
    }
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

/// Result of a status move or sync. Errors use `ErrorBanner`; confirmations
/// are a quiet line. Both dismiss themselves.
struct SprintNoticeView: View {
  let text: String
  let isError: Bool
  let onDismiss: () -> Void

  var body: some View {
    Group {
      if isError {
        ErrorBanner(text, onDismiss: onDismiss)
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
      try? await Task.sleep(for: .seconds(isError ? 8 : 4))
      guard !Task.isCancelled else { return }
      onDismiss()
    }
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
}
