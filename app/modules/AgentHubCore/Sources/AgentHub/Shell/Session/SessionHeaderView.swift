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
  let presentation: SessionTabPresentation
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
      .help(isSidePanelVisible ? "Hide side panel  ⌥⌘0" : "Show side panel  ⌥⌘0")
    }
  }

  private func modesAndContext(showsLabel: Bool, showsDots: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      if availableContentModes.count > 1 {
        ContentModeControl(modes: availableContentModes, selection: $contentMode)
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
      Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Color.wbTextPrimary)
        .frame(minWidth: 28, alignment: .trailing)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.control)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Context used")
    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
  }
}

private struct ToolbarDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.wbBorderHairline)
      .frame(width: 1, height: 18)
      .padding(.horizontal, DesignTokens.Spacing.xs)
  }
}

/// A small icon segmented control for Terminal / Chat / Files / Diffs.
private struct ContentModeControl: View {
  let modes: [MonitoringCardContentMode]
  @Binding var selection: MonitoringCardContentMode

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xxs) {
      ForEach(modes) { mode in
        let isSelected = mode == selection
        Button {
          selection = mode
        } label: {
          Image(systemName: mode.systemImage)
            .font(.system(size: 11))
            .frame(width: 26, height: DesignTokens.Size.controlSmall - 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
              .fill(Color.wbSurfaceSegmentSelected)
              .wbElevation(.raised, cornerRadius: DesignTokens.Radius.segment)
          }
        }
        .help(mode.label)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .padding(DesignTokens.Inset.control)
    .frame(height: DesignTokens.Size.controlSmall)
    .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Session view")
  }
}
