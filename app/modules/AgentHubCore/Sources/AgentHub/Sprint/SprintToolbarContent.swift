//
//  SprintToolbarContent.swift
//  AgentHub
//
//  Sprint's leading toolbar content: "Sprint 47" and a days-left chip
//  (`#toolbar-sprint` in the prototype). Jira | Linear sits in the board's
//  list head, as in the prototype.
//

import SwiftUI

struct SprintToolbarContent: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    SprintToolbarTitleView(title: title)
  }

  private var title: SprintTitle {
    guard let agentHub else { return .fallback }
    switch shellModel.sprintTracker {
    case .jira: return .jira(agentHub.jiraSprintViewModel.selectedSprint)
    case .linear: return .linear(agentHub.linearViewModel.activeCycle)
    }
  }
}

struct SprintToolbarTitleView: View {
  let title: SprintTitle

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(title.title)
        .wbText(.title3)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      if let daysLeft = title.daysLeft {
        SprintDaysLeftChip(text: daysLeft)
      }
    }
    .padding(.leading, DesignTokens.Spacing.sm)
  }
}

/// `.status-chip[data-status="idle"]` without a glyph.
private struct SprintDaysLeftChip: View {
  let text: String

  var body: some View {
    Text(text)
      .wbText(.subheadline)
      .fontWeight(.medium)
      .foregroundStyle(Color.wbStatusIdleText)
      .lineLimit(1)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: 22)
      .background(Color.wbStatusIdleTint, in: Capsule())
      .fixedSize()
  }
}
