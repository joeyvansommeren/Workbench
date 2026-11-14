//
//  ReviewsTableView.swift
//  AgentHub
//
//  The new shell's Reviews table: sortable column headers and 40 pt rows
//  with every column the legacy table had (pull request, checks, status,
//  priority, repository, author, updated, session, review).
//
//  Layout-loop rules (CLAUDE.md, plan section 4): a `ScrollView` with a
//  `LazyVStack`, not `Table` (an AppKit table view). Columns have fixed
//  widths; only the title flexes. At narrow widths `ViewThatFits` picks the
//  first column set whose fixed widths fit (`ReviewsTableLayout.columnSets`).
//  Every row and the header get the same proposal and the same fixed widths,
//  so they always pick the same set. No geometry is read.
//

import AgentHubGitHub
import SwiftUI

/// What a row needs besides its presentation.
struct ReviewsTableRowContext {
  let tileColor: RepositoryTileColor
  let review: PullRequestReviewControl
  let onOpenSession: (() -> Void)?
}

struct ReviewsTableView: View {
  let rows: [ReviewsTableRowPresentation]
  let selectedID: String?
  let sort: ReviewsTableSort?
  let context: (String) -> ReviewsTableRowContext
  let onSort: (ReviewsTableColumn) -> Void
  let onSelect: (String) -> Void
  let onMoveSelection: (Int) -> Void
  let onOpenDetail: () -> Void
  let onCloseDetail: () -> Void

  @FocusState private var isFocused: Bool
  @State private var acceptsFocus = false

  private func takeFocus() {
    guard !isFocused else { return }
    acceptsFocus = true
    // The view becomes focusable in this update; focus it in the next one.
    Task { @MainActor in isFocused = true }
  }

  var body: some View {
    VStack(spacing: 0) {
      ReviewsTableHeader(sort: sort, onSort: onSort)
        .padding(.horizontal, ReviewsTableLayout.outerInset)
      Color.wbBorderHairline.frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(rows, id: \.id) { row in
              let rowContext = context(row.id)
              ReviewsTableRow(
                presentation: row,
                tileColor: rowContext.tileColor,
                review: rowContext.review,
                isSelected: row.id == selectedID,
                onSelect: {
                  takeFocus()
                  onSelect(row.id)
                },
                onOpenSession: rowContext.onOpenSession
              )
              .id(row.id)
            }
          }
          .padding(.horizontal, ReviewsTableLayout.outerInset)
          .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .onChange(of: selectedID) { _, id in
          guard let id else { return }
          proxy.scrollTo(id)
        }
      }
    }
    // Focusable only after the first click, so the table never becomes the
    // window's first responder on appear (plan section 4).
    .focusable(acceptsFocus)
    .focusEffectDisabled()
    .focused($isFocused)
    .onKeyPress(.upArrow) {
      onMoveSelection(-1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      onMoveSelection(1)
      return .handled
    }
    .onKeyPress(.return) {
      onOpenDetail()
      return .handled
    }
    .onKeyPress(.escape) {
      onCloseDetail()
      return .handled
    }
    .accessibilityIdentifier("reviews.table")
  }
}

// MARK: - Header

private struct ReviewsTableHeader: View {
  let sort: ReviewsTableSort?
  let onSort: (ReviewsTableColumn) -> Void

  var body: some View {
    let sets = ReviewsTableLayout.columnSets
    ViewThatFits(in: .horizontal) {
      header(sets[0])
      header(sets[1])
      header(sets[2])
      header(sets[3])
      header(sets[4])
      header(sets[5])
      header(sets[6])
      header(sets[7])
    }
    .padding(.horizontal, ReviewsTableLayout.rowPadding)
    .frame(height: ReviewsTableLayout.headerHeight)
  }

  private func header(_ columns: [ReviewsTableColumn]) -> some View {
    HStack(spacing: ReviewsTableLayout.columnSpacing) {
      ForEach(columns, id: \.self) { column in
        headerCell(column)
          .reviewsColumnFrame(column)
      }
    }
  }

  @ViewBuilder
  private func headerCell(_ column: ReviewsTableColumn) -> some View {
    let isActive = sort?.column == column
    if column.isSortable {
      Button {
        onSort(column)
      } label: {
        HStack(spacing: DesignTokens.Spacing.xs) {
          if column == .checks {
            Image(systemName: "checkmark.circle")
              .font(.system(size: 11, weight: .medium))
          } else {
            Text(column.header).lineLimit(1)
          }
          if isActive, column != .checks {
            Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
              .font(.system(size: 8, weight: .bold))
          }
        }
        .frame(maxWidth: .infinity, alignment: column.alignment)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(isActive ? Color.wbTextPrimary : Color.wbTextSecondary)
      .wbText(.subheadline)
      .fontWeight(.medium)
      .help("Sort by \(column.header.lowercased())")
      .accessibilityLabel("Sort by \(column.header)")
      .accessibilityAddTraits(isActive ? .isSelected : [])
    } else {
      Text(column.header)
        .wbText(.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: column.alignment)
    }
  }
}

// MARK: - Row

private struct ReviewsTableRow: View {
  let presentation: ReviewsTableRowPresentation
  let tileColor: RepositoryTileColor
  let review: PullRequestReviewControl
  let isSelected: Bool
  let onSelect: () -> Void
  let onOpenSession: (() -> Void)?

  @State private var isHovered = false

  var body: some View {
    let sets = ReviewsTableLayout.columnSets
    ViewThatFits(in: .horizontal) {
      cells(sets[0])
      cells(sets[1])
      cells(sets[2])
      cells(sets[3])
      cells(sets[4])
      cells(sets[5])
      cells(sets[6])
      cells(sets[7])
    }
    .padding(.horizontal, ReviewsTableLayout.rowPadding)
    .frame(height: ReviewsTableLayout.rowHeight)
    // Not a Button: the session and review cells hold their own controls.
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .background(
      background,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
    )
    .overlay(alignment: .bottom) {
      Color.wbBorderHairline
        .frame(height: 1)
        .padding(.horizontal, ReviewsTableLayout.rowPadding)
        .opacity(isSelected || isHovered ? 0 : 1)
    }
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(presentation.title), \(presentation.repositoryName) \(presentation.number)")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction(.default, onSelect)
    .accessibilityIdentifier("reviews.row.\(presentation.id)")
  }

  private var background: Color {
    if isSelected { return .wbSurfaceSelected }
    return isHovered ? .wbSurfaceHover : .clear
  }

  private func cells(_ columns: [ReviewsTableColumn]) -> some View {
    HStack(spacing: ReviewsTableLayout.columnSpacing) {
      ForEach(columns, id: \.self) { column in
        cell(column)
          .reviewsColumnFrame(column)
      }
    }
  }

  @ViewBuilder
  private func cell(_ column: ReviewsTableColumn) -> some View {
    switch column {
    case .title: titleCell
    case .checks:
      if let checks = presentation.checks { PullRequestChecksIcon(state: checks) }
    case .status:
      if let status = presentation.status {
        ReviewsTagChip(tag: ReviewsTag(text: status, tone: .neutral))
      } else {
        emptyValue
      }
    case .priority:
      if let priority = presentation.priority {
        ReviewsTagChip(tag: ReviewsTag(text: priority, tone: presentation.isUrgent ? .attention : .neutral))
      } else {
        emptyValue
      }
    case .repository: repositoryCell
    case .author: authorCell
    case .updated:
      Text(presentation.age)
        .wbText(.callout)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
    case .session: sessionCell
    case .review: ReviewsRowReviewMenu(review: review)
    }
  }

  private var titleCell: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      PullRequestGlyph(size: 14)
        .foregroundStyle(Color.wbTextSecondary)
      Text(presentation.title)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Text(verbatim: presentation.number)
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextTertiary)
        .fixedSize()
    }
    .help(presentation.title)
  }

  private var repositoryCell: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      LetterTile(letter: presentation.repositoryName.first ?? "?", color: tileColor)
      Text(presentation.repositoryName)
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help(presentation.repositoryFullName)
  }

  private var authorCell: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      WBAvatar(initials: presentation.author)
      Text(presentation.author)
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  @ViewBuilder
  private var sessionCell: some View {
    if let name = presentation.sessionName, let status = presentation.sessionStatus {
      Button {
        onOpenSession?()
      } label: {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          StatusGlyph(presentation: status)
          Text(name)
            .wbText(.callout)
            .foregroundStyle(Color.wbTextPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
          if presentation.extraSessionCount > 0 {
            Text(verbatim: "+\(presentation.extraSessionCount)")
              .wbText(.callout)
              .foregroundStyle(Color.wbTextTertiary)
              .fixedSize()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(onOpenSession == nil)
      .help("Open session \(name)")
      .accessibilityLabel("Open session \(name), \(status.word)")
    } else {
      emptyValue
    }
  }

  private var emptyValue: some View {
    Text("—")
      .wbText(.callout)
      .foregroundStyle(Color.wbTextTertiary)
  }
}

// MARK: - Review menu

/// The compact per-row "Review" action: the same agent and prompt menu as
/// the detail's split button.
private struct ReviewsRowReviewMenu: View {
  let review: PullRequestReviewControl

  @State private var isHovered = false

  var body: some View {
    Menu {
      PullRequestReviewMenuItems(review: review)
    } label: {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Text(review.isStarting ? "Starting…" : "Review")
          .wbText(.callout)
          .fontWeight(.medium)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .bold))
      }
      .foregroundStyle(Color.wbTextPrimary)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.controlSmall)
      .background(
        isHovered ? Color.wbSurfaceControlHover : Color.wbSurfaceControl,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.segment)
      )
      .wbElevation(.control, cornerRadius: DesignTokens.Radius.segment)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(review.isStarting)
    .onHover { isHovered = $0 }
    .help("Review with \(PullRequestReviewControl.displayName(review.agent))")
    .accessibilityLabel("Review with \(PullRequestReviewControl.displayName(review.agent))")
  }
}

// MARK: - Shared pieces

/// A small tinted label: project status, priority, pull request state.
struct ReviewsTagChip: View {
  let tag: ReviewsTag

  var body: some View {
    Text(tag.text)
      .wbText(.subheadline)
      .fontWeight(.medium)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: 20)
      .foregroundStyle(textColor)
      .background(tintColor, in: Capsule())
      .help(tag.text)
  }

  private var textColor: Color {
    switch tag.tone {
    case .neutral: return .wbTextSecondary
    case .ready: return .wbStatusReadyText
    case .attention: return .wbStatusAttentionText
    case .error: return .wbStatusErrorText
    case .working: return .wbStatusWorkingText
    }
  }

  private var tintColor: Color {
    switch tag.tone {
    case .neutral: return .wbSurfaceField
    case .ready: return .wbStatusReadyTint
    case .attention: return .wbStatusAttentionTint
    case .error: return .wbStatusErrorTint
    case .working: return .wbStatusWorkingTint
    }
  }
}

extension ReviewsTableColumn {
  var alignment: Alignment {
    switch self {
    case .checks: return .center
    case .updated: return .trailing
    default: return .leading
    }
  }
}

extension View {
  /// The column's fixed width, or for the title a flexible width whose ideal
  /// is fixed, so `ViewThatFits` measures the same width on every row. The
  /// cell sits in an overlay on a fixed slot: an empty cell (no checks icon)
  /// still takes its width, and no cell's content can change the row's size.
  fileprivate func reviewsColumnFrame(_ column: ReviewsTableColumn) -> some View {
    Group {
      if column == .title {
        Color.clear
          .frame(minWidth: 0, idealWidth: column.width, maxWidth: .infinity)
          .frame(height: ReviewsTableLayout.cellHeight)
          .overlay(alignment: .leading) { self }
      } else {
        Color.clear
          .frame(width: column.width, height: ReviewsTableLayout.cellHeight)
          .overlay(alignment: column.alignment) { self }
      }
    }
  }
}
