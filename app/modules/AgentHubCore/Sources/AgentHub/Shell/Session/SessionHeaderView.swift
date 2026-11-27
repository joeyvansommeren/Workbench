//
//  SessionHeaderView.swift
//  AgentHub
//
//  The session header (`.session-header` in the prototype): title and status
//  chip, a meta line (provider · repository · branch in mono), then the
//  trailing group: content modes, context details, the "…" menu and the
//  side-panel toggle (⌥⌘0).
//

import SwiftUI

struct SessionHeaderView<ActionsMenu: View>: View {
  let presentation: SessionPresentation
  let progress: SessionProgressPresentation
  let onProgressAction: () -> Void
  let contextFraction: Double?
  let availableContentModes: [MonitoringCardContentMode]
  @Binding var contentMode: MonitoringCardContentMode
  /// Whether the Result overlay is visible. Nil hides the button (pending sessions).
  let showsResult: Bool?
  let onToggleResult: () -> Void
  let isSidePanelVisible: Bool
  let onToggleSidePanel: () -> Void
  @ViewBuilder let actionsMenu: (_ dismiss: @escaping () -> Void) -> ActionsMenu

  @State private var isShowingActions = false

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      heading
        .layoutPriority(1)
      Spacer(minLength: DesignTokens.Spacing.md)
      trailing
    }
    .padding(.leading, DesignTokens.Spacing.xl)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 64)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.wbBorderHairline).frame(height: 1)
    }
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        Text(presentation.title)
          .wbText(.title3)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        SessionProgressButton(progress: progress, onAction: onProgressAction)
          .fixedSize()
      }
      metaLine
    }
  }

  private var metaLine: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(presentation.providerKind == .claude ? "Claude Code" : "Codex")
        .lineLimit(1)
        .fixedSize()
      separator
      Text(presentation.repositoryName)
        .lineLimit(1)
        .help(presentation.repositoryPath)
      if let branch = presentation.branchName {
        separator
        Text(branch)
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(branch)
      }
    }
    .wbText(.callout)
    .foregroundStyle(Color.wbTextSecondary)
    .accessibilityElement(children: .combine)
  }

  private var separator: some View {
    Text("·").foregroundStyle(Color.wbTextTertiary).accessibilityHidden(true)
  }

  private var trailing: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      modesAndContext
      if let showsResult {
        ToolbarDivider()
        IconButton(
          systemImage: showsResult ? "xmark.circle" : "doc.text.magnifyingglass",
          isToggled: showsResult,
          accessibilityLabel: showsResult ? "Hide result" : "Show result",
          accessibilityIdentifier: "session.toggleResult",
          action: onToggleResult
        )
        .help(showsResult ? "Hide result" : "Show result")
      }
      ToolbarDivider()
      IconButton(
        systemImage: "ellipsis",
        accessibilityLabel: "Session actions",
        accessibilityIdentifier: "session.actions"
      ) {
        isShowingActions = true
      }
      .help("Session actions")
      .popover(isPresented: $isShowingActions, arrowEdge: .bottom) {
        actionsMenu { isShowingActions = false }
      }
      IconButton(
        systemImage: "sidebar.right",
        isToggled: isSidePanelVisible,
        accessibilityLabel: isSidePanelVisible ? "Hide side panel" : "Show side panel",
        accessibilityIdentifier: "session.toggleSidePanel",
        action: onToggleSidePanel
      )
      .help("\(isSidePanelVisible ? "Hide" : "Show") side panel  \(ShellShortcut.toggleSidePanel.keyCaps.joined())")
    }
  }

  private var modesAndContext: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      if availableContentModes.count > 1 {
        // Icon-only segments: each mode's label is its tooltip and VoiceOver name.
        WorkbenchSegmentedControl(
          selection: $contentMode,
          items: availableContentModes,
          title: { $0.label },
          showsTitle: false,
          icon: { $0.systemImage },
          size: .small,
          accessibilityLabel: "Session view"
        )
        .padding(.trailing, DesignTokens.Spacing.xs)
      }
      if let contextFraction, contextFraction.isFinite, contextFraction > 0 {
        ContextUsageButton(fraction: contextFraction)
      }
    }
    .fixedSize()
  }
}

/// Compact usage with the calculation detail available on demand.
private struct ContextUsageButton: View {
  let fraction: Double
  @State private var isShowingDetail = false

  var body: some View {
    Button {
      isShowingDetail = true
    } label: {
      Text("Context \(percent)%")
        .wbText(.callout)
        .fontWeight(.medium)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.control)
    .accessibilityLabel("Context used")
    .accessibilityValue("\(percent) percent")
    .accessibilityHint("Show context usage details")
    .popover(isPresented: $isShowingDetail, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("Estimated from recorded input tokens and the model's context size.")
        Text("The CLI may show a different value.")
      }
      .wbText(.callout)
      .foregroundStyle(Color.wbTextSecondary)
      .padding(DesignTokens.Spacing.md)
      .frame(width: DesignTokens.Width.popover)
    }
  }

  /// Clamped once, so the screen and VoiceOver say the same number.
  private var percent: Int { Int((min(max(fraction, 0), 1) * 100).rounded()) }
}

private struct ToolbarDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.wbBorderHairline)
      .frame(width: 1, height: 18)
      .padding(.horizontal, DesignTokens.Spacing.xs)
  }
}

