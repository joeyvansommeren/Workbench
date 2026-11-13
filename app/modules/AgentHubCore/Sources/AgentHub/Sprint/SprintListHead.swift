//
//  SprintListHead.swift
//  AgentHub
//
//  The row above the board (`.list-head`): Jira | Linear, All | Mine, and a
//  trailing slot for Refresh and Filters.
//

import SwiftUI

struct SprintListHead<Trailing: View>: View {
  @Binding var tracker: SprintTracker
  @Binding var scope: SprintAssigneeScope
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      WorkbenchSegmentedControl(selection: $tracker, accessibilityIdentifier: "shell.sprintTracker")
        .fixedSize()
      WorkbenchSegmentedControl(selection: $scope, accessibilityIdentifier: "sprint.assignee")
        .fixedSize()
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Spacing.xs) {
        trailing
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 56)
  }
}

/// A Filters popover section: a small label over its controls.
struct SprintFilterSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xsPlus) {
      Text(title)
        .wbText(.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(Color.wbTextSecondary)
      content
    }
  }
}
