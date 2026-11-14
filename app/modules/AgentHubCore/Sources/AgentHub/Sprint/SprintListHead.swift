//
//  SprintListHead.swift
//  AgentHub
//
//  The row above the Jira and Linear boards (`.list-head`): the sprint or
//  cycle name with its days-left chip, All | Mine, the people filter (Jira)
//  and a trailing slot for Refresh and Filters.
//

import SwiftUI

struct SprintListHead<People: View, Trailing: View>: View {
  /// Nil hides the title (Linear without an active cycle).
  let title: SprintTitle?
  @Binding var scope: SprintAssigneeScope
  /// The people filter for a visible-avatar limit (`SprintPeopleFilter`).
  /// Nil when the tracker has no per-person filter (Linear).
  let people: ((Int) -> People)?
  @ViewBuilder let trailing: Trailing

  init(
    title: SprintTitle?,
    scope: Binding<SprintAssigneeScope>,
    @ViewBuilder people: @escaping (Int) -> People,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self._scope = scope
    self.people = people
    self.trailing = trailing()
  }

  var body: some View {
    // A narrow board (a ticket open in a small window) first shows fewer
    // avatars, then drops the days-left chip, the title, then All | Mine, so
    // the head never overflows. The people filter outlives All | Mine: it is
    // the only way to pick a person, so with a people filter the last
    // fallback (used even when nothing fits) still has its menu. Fixed avatar
    // counts, picked by `ViewThatFits`; layout-only, no size → state.
    ViewThatFits(in: .horizontal) {
      if people != nil {
        row(title: title, showsScope: true, peopleLimit: SprintPeopleFilter.wideLimit)
        row(title: title?.withoutDaysLeft, showsScope: true, peopleLimit: SprintPeopleFilter.wideLimit)
        row(title: title?.withoutDaysLeft, showsScope: true, peopleLimit: SprintPeopleFilter.narrowLimit)
        row(title: nil, showsScope: true, peopleLimit: SprintPeopleFilter.narrowLimit)
        row(title: nil, showsScope: true, peopleLimit: SprintPeopleFilter.menuOnlyLimit)
        // Tighter gaps: at 900 pt with a ticket open and a search active the
        // other rows are a few points too wide (Codex review).
        row(title: nil, showsScope: false, peopleLimit: SprintPeopleFilter.menuOnlyLimit, compact: true)
      } else {
        row(title: title, showsScope: true, peopleLimit: nil)
        row(title: title?.withoutDaysLeft, showsScope: true, peopleLimit: nil)
        row(title: nil, showsScope: true, peopleLimit: nil)
        row(title: nil, showsScope: false, peopleLimit: nil)
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 56)
  }

  private func row(title: SprintTitle?, showsScope: Bool, peopleLimit: Int?, compact: Bool = false) -> some View {
    HStack(spacing: compact ? DesignTokens.Spacing.sm : DesignTokens.Spacing.md) {
      if let title {
        SprintTitleView(title: title)
      }
      if showsScope {
        WorkbenchSegmentedControl(
          selection: $scope, accessibilityLabel: "Assignee", accessibilityIdentifier: "sprint.assignee")
          .fixedSize()
      }
      if let peopleLimit, let people {
        people(peopleLimit)
      }
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Spacing.xs) {
        trailing
      }
      .fixedSize()
    }
  }
}

extension SprintListHead where People == EmptyView {
  /// A head without a people filter (Linear).
  init(
    title: SprintTitle?,
    scope: Binding<SprintAssigneeScope>,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self._scope = scope
    self.people = nil
    self.trailing = trailing()
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
