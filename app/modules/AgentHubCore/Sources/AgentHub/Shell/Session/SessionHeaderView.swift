//
//  SessionHeaderView.swift
//  AgentHub
//
//  The session header (`.session-header` in the prototype): title and status
//  chip, a meta line (provider · repository · branch in mono), then the
//  trailing group: content modes, Context meter, the "…" menu and the
//  side-panel toggle (⌥⌘0).
//

import SwiftUI

struct SessionHeaderView<ActionsMenu: View>: View {
  let presentation: SessionPresentation
  let contextFraction: Double?
  let availableContentModes: [MonitoringCardContentMode]
  @Binding var contentMode: MonitoringCardContentMode
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
        StatusChip(status: presentation.status, isPending: presentation.isPending)
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
      if let branch = presentation.branchName {
        separator
        Text(branch)
          .wbText(.codeSmall)
          .lineLimit(1)
          .truncationMode(.middle)
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
      // In a narrow window the meter compacts before the title truncates.
      ViewThatFits(in: .horizontal) {
        modesAndContext(showsLabel: true, showsDots: true)
        modesAndContext(showsLabel: false, showsDots: true)
        modesAndContext(showsLabel: false, showsDots: false)
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

  private func modesAndContext(showsLabel: Bool, showsDots: Bool) -> some View {
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
      if let contextFraction {
        ContextMeter(fraction: contextFraction, showsLabel: showsLabel, showsDots: showsDots)
      }
    }
    .fixedSize()
  }
}

/// `.context-meter`: label, 20×3 dot meter, percentage.
private struct ContextMeter: View {
  let fraction: Double
  var showsLabel = true
  var showsDots = true

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if showsLabel {
        Text("Context")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
      if showsDots {
        DotMeter(fraction: fraction)
      }
      Text("\(percent)%")
        .wbText(.callout)
        .fontWeight(.medium)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextPrimary)
        .frame(minWidth: 28, alignment: .trailing)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.control)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Context used")
    .accessibilityValue("\(percent) percent")
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

