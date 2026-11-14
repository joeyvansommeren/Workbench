//
//  SprintProjectMenu.swift
//  AgentHub
//
//  Linear's project filter in the Sprint list head: "All projects", then the
//  team's open projects by name, a check on the selected one. Full: a menu
//  button with the selected name (capped width, truncates). Compact: a 28 pt
//  icon button for the narrowest head. Hover changes colour only.
//

import AgentWorkflowLinear
import SwiftUI

struct SprintProjectMenu: View {
  let projects: [LinearProject]
  /// Nil: all projects.
  let selected: LinearProject?
  let isCompact: Bool
  let onSelect: (_ projectID: String?) -> Void

  /// The full label's widest size. A fixed cap, so the head's `ViewThatFits`
  /// sees a stable ideal width; a longer name truncates.
  static let labelMaxWidth: CGFloat = 180
  static let allProjectsTitle = "All projects"

  var body: some View {
    Menu {
      Button {
        onSelect(nil)
      } label: {
        SprintProjectMenuItem(title: Self.allProjectsTitle, isSelected: selected == nil)
      }
      if !projects.isEmpty {
        Divider()
        ForEach(projects) { project in
          Button {
            onSelect(project.id)
          } label: {
            SprintProjectMenuItem(title: project.name, isSelected: project.id == selected?.id)
          }
        }
      }
    } label: {
      if isCompact {
        SprintProjectIconLabel(isFiltered: selected != nil)
      } else {
        WBMenuButtonLabel(selected?.name ?? Self.allProjectsTitle)
          .frame(maxWidth: Self.labelMaxWidth)
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(selected.map { "Project: \($0.name)" } ?? Self.allProjectsTitle)
    .accessibilityLabel("Project")
    .accessibilityValue(selected?.name ?? Self.allProjectsTitle)
    .accessibilityIdentifier("sprint.project")
  }
}

private struct SprintProjectMenuItem: View {
  let title: String
  let isSelected: Bool

  var body: some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}

/// The compact label: a project glyph on a 28 pt control. Accent tint while
/// a project filters the board, so the filter stays visible without a name.
private struct SprintProjectIconLabel: View {
  let isFiltered: Bool

  @State private var isHovered = false

  var body: some View {
    Image(systemName: "cube")
      .font(.system(size: 12))
      .foregroundStyle(isFiltered ? Color.wbAccentText : (isHovered ? Color.wbTextPrimary : Color.wbTextSecondary))
      .frame(width: DesignTokens.Size.control, height: DesignTokens.Size.control)
      .background(fill, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous))
      .wbElevation(.control, cornerRadius: DesignTokens.Radius.item)
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
  }

  private var fill: Color {
    if isFiltered { return .wbAccentTint }
    return isHovered ? .wbSurfaceControlHover : .wbSurfaceControl
  }
}
