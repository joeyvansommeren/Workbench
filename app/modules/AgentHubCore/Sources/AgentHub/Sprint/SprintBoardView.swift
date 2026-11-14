//
//  SprintBoardView.swift
//  AgentHub
//
//  The shell's Sprint board (`SprintBoard`, `SprintColumn`, `TicketCard` in the
//  prototype). Tracker-neutral: it draws `SprintColumnItem`s and reports taps.
//
//  Layout-loop safety: no GeometryReader, no size → state. Up to four columns
//  share the width equally while each keeps `SprintLayout.columnMinWidth`.
//  When they do not fit (more columns, or a ticket open in a narrow window)
//  the board scrolls sideways instead. `ViewThatFits` picks between the two
//  from the columns' fixed ideal widths, inside one layout pass.
//

import SwiftUI

/// What a board can do with a card. Optional actions hide their menu items.
struct SprintBoardActions {
  var onOpen: (String) -> Void
  var onStart: (String) -> Void
  var onOpenSession: (String) -> Void
  /// Move a card to another column (drag, the context menu, or a VoiceOver
  /// action). Nil when the tracker cannot move tickets.
  var onMove: ((_ ticketID: String, _ columnID: String) -> Void)?
  var browseURL: (String) -> URL? = { _ in nil }
}

struct SprintBoardView: View {
  let columns: [SprintColumnItem]
  let selectedTicketID: String?
  /// Whether the board has keyboard focus: the selected card then shows the
  /// accent ring, else a grey one (the macOS list rule).
  var isFocused = true
  let actions: SprintBoardActions

  static let visibleColumnCount = 4

  var body: some View {
    Group {
      if columns.count > Self.visibleColumnCount {
        scrollingBoard
      } else {
        ViewThatFits(in: .horizontal) {
          fittedBoard
          scrollingBoard
        }
      }
    }
    .padding(.bottom, DesignTokens.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  /// Equal columns. Its ideal width is every column at its minimum, so
  /// `ViewThatFits` only picks it when no column would be squeezed.
  private var fittedBoard: some View {
    columnStack { column in
      column.frame(
        minWidth: SprintLayout.columnMinWidth,
        idealWidth: SprintLayout.columnMinWidth,
        maxWidth: .infinity)
    }
    .padding(.horizontal, SprintLayout.boardInset)
  }

  /// A quarter of the visible width per column, never under the minimum.
  private var scrollingBoard: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        columnStack { column in
          column.containerRelativeFrame(.horizontal) { length, _ in
            let spacing = DesignTokens.Spacing.md * CGFloat(Self.visibleColumnCount - 1)
            let quarter = (length - spacing) / CGFloat(Self.visibleColumnCount)
            return max(SprintLayout.columnMinWidth, quarter.rounded(.down))
          }
        }
        .scrollTargetLayout()
      }
      .scrollIndicators(.automatic)
      .contentMargins(.horizontal, SprintLayout.boardInset, for: .scrollContent)
      // Arrow keys can select a card in a column scrolled out of view.
      .onChange(of: selectedTicketID) { _, selected in
        guard let selected,
          let column = columns.first(where: { $0.tickets.contains { $0.id == selected } })
        else { return }
        proxy.scrollTo(column.id)
      }
    }
  }

  private func columnStack<Sized: View>(
    @ViewBuilder width: @escaping (SprintColumnView) -> Sized
  ) -> some View {
    let moveTargets = columns.map { SprintMoveTarget(id: $0.id, title: $0.title) }
    return HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      ForEach(columns) { column in
        width(
          SprintColumnView(
            column: column,
            moveTargets: moveTargets,
            selectedTicketID: selectedTicketID,
            isBoardFocused: isFocused,
            actions: actions))
      }
    }
  }
}

/// A column a card can move to.
struct SprintMoveTarget: Identifiable, Equatable {
  let id: String
  let title: String
}

// MARK: - Column

struct SprintColumnView: View {
  let column: SprintColumnItem
  /// Every column of the board, for "Move to".
  let moveTargets: [SprintMoveTarget]
  let selectedTicketID: String?
  let isBoardFocused: Bool
  let actions: SprintBoardActions

  @State private var isDropTargeted = false

  /// The other columns, when the tracker can move tickets.
  private var otherColumns: [SprintMoveTarget] {
    guard actions.onMove != nil else { return [] }
    return moveTargets.filter { $0.id != column.id }
  }

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
      isBoardFocused: isBoardFocused,
      moveTargets: otherColumns,
      onOpen: { actions.onOpen(ticket.id) },
      onStart: { actions.onStart(ticket.id) },
      onOpenSession: { actions.onOpenSession(ticket.id) },
      onMove: { columnID in actions.onMove?(ticket.id, columnID) }
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
        .disabled(ticket.isStarting)
    }
    // Dragging is not the only way to change a status (keyboard users).
    if let onMove = actions.onMove, !otherColumns.isEmpty {
      Menu("Move To") {
        ForEach(otherColumns) { target in
          Button(target.title) { onMove(ticket.id, target.id) }
        }
      }
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
/// hover, open tickets show "Start session" where the avatar was; it stays
/// while the session starts. Keyboard users press Return on the selected
/// card instead (a permanent reveal would cover the key on narrow cards).
struct SprintTicketCard: View {
  let ticket: SprintTicketItem
  let isSelected: Bool
  var isBoardFocused = true
  /// Columns this card can move to; empty when the tracker cannot move it.
  var moveTargets: [SprintMoveTarget] = []
  let onOpen: () -> Void
  let onStart: () -> Void
  let onOpenSession: () -> Void
  var onMove: (String) -> Void = { _ in }
  /// Lets renders and previews show the hover state.
  var forceHover = false

  @State private var isHovered = false

  private var showsStart: Bool {
    ticket.canStart && (isHovered || forceHover || ticket.isStarting)
  }

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
        // Accent while the board has focus (arrow keys go here), grey otherwise.
        shape.strokeBorder(isBoardFocused ? Color.wbAccent : Color.wbBorderStrong, lineWidth: 1.5)
      }
    }
    // Floats over the top row (`.ticket .start`), centred on it, so it
    // takes no width from the key when hidden.
    .overlay(alignment: .topTrailing) {
      if ticket.canStart {
        startButton
          .padding(.top, DesignTokens.Spacing.sm)
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
    // The avatar is hidden from VoiceOver, so the assignee is said here.
    .accessibilityValue(ticket.assigneeName.map { "Assigned to \($0)" } ?? "")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Open details", onOpen)
    .accessibilityActions {
      // The Start button is invisible until hover, so VoiceOver skips it.
      if ticket.canStart && !ticket.isStarting {
        Button("Start session", action: onStart)
      }
      ForEach(moveTargets) { target in
        Button("Move to \(target.title)") { onMove(target.id) }
      }
    }
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
        if ticket.isStarting {
          ProgressView()
            .controlSize(.mini)
            .frame(width: 10, height: 10)
          Text("Starting…")
        } else {
          Image(systemName: "play.fill")
            .font(.system(size: 9))
            .frame(width: 10, height: 10)
          Text("Start session")
        }
      }
      .wbText(.callout)
      .fontWeight(.medium)
      .foregroundStyle(Color.wbTextPrimary)
      // The glyph leads, so the leading side is 2 pt tighter (optical balance).
      .padding(.leading, DesignTokens.Spacing.xsPlus)
      .padding(.trailing, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.controlSmall)
      .contentShape(Rectangle())
    }
    .buttonStyle(SprintCardButtonStyle())
    .disabled(ticket.isStarting)
    .fixedSize()
    .accessibilityLabel(
      ticket.isStarting ? "Starting session for \(ticket.key)" : "Start session for \(ticket.key)")
  }
}

/// The card's 24 pt secondary button: the `.wbSecondary` fills (hover, then
/// pressed), colour only, at the small control size and segment radius.
private struct SprintCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SprintCardButtonBody(configuration: configuration)
  }
}

private struct SprintCardButtonBody: View {
  let configuration: ButtonStyleConfiguration

  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.segment, style: .continuous)
    configuration.label
      .background {
        ZStack {
          WBButtonKind.secondary.fill(isHovered: isHovered || configuration.isPressed)
          if configuration.isPressed {
            Color.wbSurfacePressed
          }
        }
      }
      .clipShape(shape)
      .wbElevation(.control, cornerRadius: DesignTokens.Radius.segment)
      .onHover { isHovered = $0 }
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
