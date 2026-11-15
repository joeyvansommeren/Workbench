//
//  SprintListHead.swift
//  AgentHub
//
//  The row above the Jira and Linear boards (`.list-head`): the sprint or
//  cycle name with its days-left chip, All | Mine, the people filter (Jira)
//  or the project menu (Linear), and a trailing slot for Refresh and Filters.
//

import SwiftUI

/// The filter after All | Mine. Both kinds survive every width.
enum SprintListHeadFilter<Content: View> {
  /// Jira's people strip for a visible-avatar limit (`SprintPeopleFilter`).
  case people((Int) -> Content)
  /// Linear's project menu: full (false) or icon only (true, `isCompact`).
  case menu((Bool) -> Content)
}

struct SprintListHead<People: View, Trailing: View>: View {
  /// Nil hides the title (Linear without an active cycle or project).
  let title: SprintTitle?
  @Binding var scope: SprintAssigneeScope
  /// Nil when the tracker has no filter here.
  let filter: SprintListHeadFilter<People>?
  @ViewBuilder let trailing: Trailing

  init(
    title: SprintTitle?,
    scope: Binding<SprintAssigneeScope>,
    @ViewBuilder people: @escaping (Int) -> People,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self._scope = scope
    self.filter = .people(people)
    self.trailing = trailing()
  }

  /// A head with a menu filter (Linear's project menu).
  init(
    title: SprintTitle?,
    scope: Binding<SprintAssigneeScope>,
    @ViewBuilder menu: @escaping (_ isCompact: Bool) -> People,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self._scope = scope
    self.filter = .menu(menu)
    self.trailing = trailing()
  }

  var body: some View {
    // A narrow board (a ticket open in a small window) first shows fewer
    // avatars, then drops the days-left chip, the title, then All | Mine, so
    // the head never overflows. The people filter outlives All | Mine: it is
    // the only way to pick a person, so with a people filter the last
    // fallback (used even when nothing fits) still has its menu. Fixed avatar
    // counts, picked by `ViewThatFits`; layout-only, no size → state.
    //
    // The project menu works the same way: it keeps its full label (name
    // capped at `SprintProjectMenu.labelMaxWidth`) until only an icon fits.
    ViewThatFits(in: .horizontal) {
      switch filter {
      case .people(let people):
        row(title: title, showsScope: true) { people(SprintPeopleFilter.wideLimit) }
        row(title: title?.withoutDaysLeft, showsScope: true) { people(SprintPeopleFilter.wideLimit) }
        row(title: title?.withoutDaysLeft, showsScope: true) { people(SprintPeopleFilter.narrowLimit) }
        row(title: nil, showsScope: true) { people(SprintPeopleFilter.narrowLimit) }
        row(title: nil, showsScope: true) { people(SprintPeopleFilter.menuOnlyLimit) }
        SprintListHeadCompactRow { people(SprintPeopleFilter.menuOnlyLimit) } trailing: { trailing }
      case .menu(let menu):
        row(title: title, showsScope: true) { menu(false) }
        row(title: title?.withoutDaysLeft, showsScope: true) { menu(false) }
        row(title: nil, showsScope: true) { menu(false) }
        row(title: nil, showsScope: false) { menu(false) }
        SprintListHeadCompactRow { menu(true) } trailing: { trailing }
      case nil:
        row(title: title, showsScope: true) { EmptyView() }
        row(title: title?.withoutDaysLeft, showsScope: true) { EmptyView() }
        row(title: nil, showsScope: true) { EmptyView() }
        row(title: nil, showsScope: false) { EmptyView() }
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 56)
  }

  private func row<Filter: View>(
    title: SprintTitle?, showsScope: Bool, @ViewBuilder filter: () -> Filter
  ) -> some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      if let title {
        SprintTitleView(title: title)
      }
      if showsScope {
        WorkbenchSegmentedControl(
          selection: $scope, accessibilityLabel: "Assignee", accessibilityIdentifier: "sprint.assignee")
          .fixedSize()
      }
      filter()
      Spacer(minLength: 0)
      HStack(spacing: DesignTokens.Spacing.xs) {
        trailing
      }
      .fixedSize()
    }
  }
}

/// The head's last fallback, used even when nothing fits: the filter's
/// smallest form and the trailing controls, `Spacing.xs` apart and no spacer
/// gap. At 900 pt with a ticket open and a search active the head has 195 pt;
/// this row needs 192 (`SprintProjectMenuTests`). A row with a spacer and
/// `Spacing.sm` gaps needed 204, so the trailing controls overflowed.
struct SprintListHeadCompactRow<Filter: View, Trailing: View>: View {
  @ViewBuilder let filter: Filter
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      filter
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: DesignTokens.Spacing.xs) {
        trailing
      }
      .fixedSize()
    }
  }
}

extension SprintListHead where People == EmptyView {
  /// A head without a filter after All | Mine.
  init(
    title: SprintTitle?,
    scope: Binding<SprintAssigneeScope>,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self._scope = scope
    self.filter = nil
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
