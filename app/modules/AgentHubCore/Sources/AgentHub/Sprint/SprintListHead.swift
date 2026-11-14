//
//  SprintListHead.swift
//  AgentHub
//
//  The row above the Jira and Linear boards (`.list-head`): the sprint or
//  cycle name with its days-left chip, All | Mine, and a trailing slot for
//  Refresh and Filters.
//

import SwiftUI

struct SprintListHead<Trailing: View>: View {
  /// Nil hides the title (Linear without an active cycle).
  let title: SprintTitle?
  @Binding var scope: SprintAssigneeScope
  @ViewBuilder let trailing: Trailing

  var body: some View {
    // A narrow board (a ticket open in a small window) drops the days-left
    // chip, then the title, then All | Mine, so the head never overflows.
    // Layout-only choice, no size → state.
    ViewThatFits(in: .horizontal) {
      row(title: title, showsScope: true)
      row(title: title?.withoutDaysLeft, showsScope: true)
      row(title: nil, showsScope: true)
      row(title: nil, showsScope: false)
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 56)
  }

  private func row(title: SprintTitle?, showsScope: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      if let title {
        SprintTitleView(title: title)
      }
      if showsScope {
        WorkbenchSegmentedControl(
          selection: $scope, accessibilityLabel: "Assignee", accessibilityIdentifier: "sprint.assignee")
          .fixedSize()
      }
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Spacing.xs) {
        trailing
      }
      .fixedSize()
    }
  }
}

/// "Sprint 47" and a days-left chip (was `#toolbar-sprint` in the prototype).
struct SprintTitleView: View {
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
