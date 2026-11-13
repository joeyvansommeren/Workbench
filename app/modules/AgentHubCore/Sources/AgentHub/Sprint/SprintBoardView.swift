//
//  SprintBoardView.swift
//  AgentHub
//
//  The shell's Sprint board (`SprintBoard`, `SprintColumn`, `TicketCard` in the
//  prototype). Tracker-neutral: it draws `SprintColumnItem`s and reports taps.
//
//  Layout-loop safety: no GeometryReader. Up to four columns share the width
//  equally; only boards with more columns scroll sideways, each column a
//  quarter of the visible width via `containerRelativeFrame`.
//

import SwiftUI

/// What a board can do with a card. Optional actions hide their menu items.
struct SprintBoardActions {
  var onOpen: (String) -> Void
  var onStart: (String) -> Void
  var onOpenSession: (String) -> Void
  /// Drag a card to another column. Nil when the tracker cannot move tickets.
  var onMove: ((_ ticketID: String, _ columnID: String) -> Void)?
  var browseURL: (String) -> URL? = { _ in nil }
}

struct SprintBoardView: View {
  let columns: [SprintColumnItem]
  let selectedTicketID: String?
  let actions: SprintBoardActions

  static let visibleColumnCount = 4

  var body: some View {
    Group {
      if columns.count > Self.visibleColumnCount {
        ScrollView(.horizontal) {
          columnStack
            .scrollTargetLayout()
        }
        .scrollIndicators(.automatic)
        .contentMargins(.horizontal, DesignTokens.Spacing.lg, for: .scrollContent)
      } else {
        columnStack
          .padding(.horizontal, DesignTokens.Spacing.lg)
      }
    }
    .padding(.bottom, DesignTokens.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var columnStack: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      ForEach(columns) { column in
        SprintColumnView(column: column, selectedTicketID: selectedTicketID, actions: actions)
          .modifier(SprintColumnWidth(isScrolling: columns.count > Self.visibleColumnCount))
      }
    }
  }
}

/// Equal flexible widths, or a quarter of the scroll view when scrolling.
private struct SprintColumnWidth: ViewModifier {
  let isScrolling: Bool

  func body(content: Content) -> some View {
    if isScrolling {
      content.containerRelativeFrame(
        .horizontal,
        count: SprintBoardView.visibleColumnCount,
        spacing: DesignTokens.Spacing.md
      )
    } else {
      content.frame(minWidth: 0, maxWidth: .infinity)
    }
  }
}

// MARK: - Column

struct SprintColumnView: View {
  let column: SprintColumnItem
  let selectedTicketID: String?
  let actions: SprintBoardActions

  @State private var isDropTargeted = false

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.container, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Inset.container) {
      header
      ScrollView(.vertical) {
        LazyVStack(spacing: DesignTokens.Inset.container) {
          ForEach(column.tickets) { ticket in
            card(ticket)
          }
        }
        // Room for the cards' raised shadow inside the clipped scroll view.
        .padding(.bottom, DesignTokens.Spacing.xs)
      }
      .scrollIndicators(.never)
    }
    .padding(DesignTokens.Inset.container)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.wbSurfaceColumn, in: shape)
    .overlay {
      if isDropTargeted {
        shape.strokeBorder(Color.wbAccent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
      }
    }
    .modifier(SprintColumnDrop(column: column, onMove: actions.onMove, isTargeted: $isDropTargeted))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(column.title)
  }

  private var header: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(column.title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
      Text(verbatim: "\(column.tickets.count)")
        .wbText(.body)
        .monospacedDigit()
        .foregroundStyle(Color.wbTextSecondary)
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: 30)
  }

  @ViewBuilder
  private func card(_ ticket: SprintTicketItem) -> some View {
    let card = SprintTicketCard(
      ticket: ticket,
      isSelected: ticket.id == selectedTicketID,
      onOpen: { actions.onOpen(ticket.id) },
      onStart: { actions.onStart(ticket.id) },
      onOpenSession: { actions.onOpenSession(ticket.id) }
    )
    .contextMenu { contextMenu(for: ticket) }
    if actions.onMove != nil {
      card.draggable(ticket.id)
    } else {
      card
    }
  }

  @ViewBuilder
  private func contextMenu(for ticket: SprintTicketItem) -> some View {
    Button("Open Details") { actions.onOpen(ticket.id) }
    if ticket.canStart {
      Button("Start Session") { actions.onStart(ticket.id) }
    }
    Divider()
    if let url = actions.browseURL(ticket.id) {
      Button("Open in Browser") { NSWorkspace.shared.open(url) }
    }
    Button("Copy Key") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(ticket.key, forType: .string)
    }
  }
}

private struct SprintColumnDrop: ViewModifier {
  let column: SprintColumnItem
  let onMove: ((String, String) -> Void)?
  @Binding var isTargeted: Bool

  func body(content: Content) -> some View {
    if let onMove {
      content.dropDestination(for: String.self) { ids, _ in
        guard let id = ids.first, !column.tickets.contains(where: { $0.id == id }) else {
          return false
        }
        onMove(id, column.id)
        return true
      } isTargeted: { isTargeted = $0 }
    } else {
      content
    }
  }
}

// MARK: - Ticket card

/// `TicketCard`: key and assignee, two-line title, an optional footer. On
/// hover, open tickets show "Start session" where the avatar was.
struct SprintTicketCard: View {
  let ticket: SprintTicketItem
  let isSelected: Bool
  let onOpen: () -> Void
  let onStart: () -> Void
  let onOpenSession: () -> Void
  /// Lets renders and previews show the hover state.
  var forceHover = false

  @State private var isHovered = false

  private var showsStart: Bool { ticket.canStart && (isHovered || forceHover) }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xsPlus) {
      top
      Text(ticket.title)
        .wbText(.body)
        .foregroundStyle(ticket.isDone ? Color.wbTextSecondary : Color.wbTextPrimary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let footer = ticket.footer {
        SprintTicketFooterView(footer: footer, onOpenSession: onOpenSession)
      }
    }
    .padding(.top, DesignTokens.Spacing.smPlus)
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.bottom, DesignTokens.Spacing.md)
    .background(Color.wbSurfaceRaised, in: shape)
    .wbElevation(.raised, cornerRadius: DesignTokens.Radius.item)
    .overlay {
      if isSelected {
        shape.strokeBorder(Color.wbAccent, lineWidth: 1.5)
      }
    }
    // Floats over the top row like `.ticket .start` (top 7, right 8), so it
    // takes no width from the key when hidden.
    .overlay(alignment: .topTrailing) {
      if ticket.canStart {
        startButton
          .padding(.top, 7)
          .padding(.trailing, DesignTokens.Spacing.sm)
          .opacity(showsStart ? 1 : 0)
          .allowsHitTesting(showsStart)
      }
    }
    .contentShape(shape)
    // A tap gesture, not a Button: the card holds its own buttons, and a
    // button nested in a button never receives the click on macOS.
    .onTapGesture(perform: onOpen)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(ticket.key): \(ticket.title)")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Open details", onOpen)
  }

  private var top: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text(ticket.key)
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 0)
      // Hidden, not removed, on hover, so the card never changes size.
      if let initials = ticket.assigneeInitials {
        WBAvatar(initials: initials)
          .help(ticket.assigneeName ?? "")
          .opacity(showsStart ? 0 : 1)
      }
    }
    .frame(height: 20)
  }

  private var startButton: some View {
    Button(action: onStart) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Image(systemName: "play.fill")
          .font(.system(size: 9))
        Text("Start session")
      }
      .wbText(.callout)
      .fontWeight(.medium)
      .foregroundStyle(Color.wbTextPrimary)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.controlSmall)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(Color.wbSurfaceControl, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
    .wbElevation(.control)
    .fixedSize()
    .accessibilityLabel("Start session for \(ticket.key)")
  }
}

private struct SprintTicketFooterView: View {
  let footer: SprintTicketFooter
  let onOpenSession: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      content
    }
    .wbText(.callout)
    .foregroundStyle(Color.wbTextSecondary)
    .lineLimit(1)
    .frame(minHeight: DesignTokens.Size.controlSmall)
  }

  @ViewBuilder
  private var content: some View {
    switch footer {
    case .session(let providerName, let presentation):
      Button(action: onOpenSession) {
        HStack(spacing: DesignTokens.Spacing.xsPlus) {
          StatusGlyph(presentation: presentation)
            .fixedSize()
          Text(providerName)
          Text("·")
          Text(presentation.word)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open session")
      .accessibilityLabel("Open session: \(providerName), \(presentation.accessibilityLabel)")
    case .pullRequest(let number, let isMerged):
      PullRequestGlyph(size: DesignTokens.Size.iconSmall)
      // Verbatim: a PR number never gets a grouping separator ("#1.843").
      Text(verbatim: "#\(number)")
        .wbText(.codeSmall)
      Text("·")
      Text(isMerged ? "Merged" : "In review")
    case .done:
      Image(systemName: "checkmark")
        .font(.system(size: DesignTokens.Size.iconSmall - 2, weight: .medium))
      Text("Done")
    }
  }
}
