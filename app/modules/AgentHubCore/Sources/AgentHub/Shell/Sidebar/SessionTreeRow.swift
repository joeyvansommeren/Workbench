//
//  SessionTreeRow.swift
//  AgentHub
//
//  Session row in the sidebar tree (`.session-row`): the status glyph sits on
//  a guide line, then the agent mark, the title, an optional workflow role and
//  the Approve or Answer pill. The guide line is an overlay `Path`, outside layout.
//

import AgentHubGitHub
import SwiftUI

struct SessionTreeRow: View, Equatable {
  let model: SessionRowModel
  let isSelected: Bool
  /// True when the content panel shows something else (Reviews, Sprint): the
  /// selected row then drops to `surfaceSelected` without a shadow.
  let isElsewhere: Bool
  let actions: SidebarTreeActions

  @State private var isHovered = false
  @State private var showsPreview = false

  nonisolated static func == (lhs: SessionTreeRow, rhs: SessionTreeRow) -> Bool {
    lhs.model == rhs.model && lhs.isSelected == rhs.isSelected && lhs.isElsewhere == rhs.isElsewhere
  }

  private var node: SessionNode { model.node }
  private var presentation: SessionStatusPresentation {
    SessionStatusPresentation(status: node.status, isPending: node.isPending)
  }

  var body: some View {
    HStack(spacing: 0) {
      Button { actions.open(node) } label: { label }
        .buttonStyle(.plain)
      if node.showsApprovePill {
        SessionApprovePill(node: node, actions: actions)
          .padding(.leading, DesignTokens.Spacing.xs)
      } else if node.showsAnswerPill {
        AttentionPill(
          title: "Answer",
          help: "Open the session to answer",
          accessibilityLabel: "Answer \(model.title)"
        ) { actions.open(node) }
        .padding(.leading, DesignTokens.Spacing.xs)
      }
    }
    .padding(.trailing, DesignTokens.Spacing.xs)
    .frame(height: DesignTokens.Size.row)
    .background(background)
    .overlay(alignment: .topLeading) {
      SessionGuideLine(isFirst: model.isFirstInBranch, isLast: model.isLastInBranch)
    }
    .onHover { isHovered = $0 }
    .task(id: isHovered) {
      // Hover preview after a short rest, like a tooltip; warm after the first.
      guard isHovered else {
        showsPreview = false
        return
      }
      let delay = actions.hoverPreview.delay(at: .now)
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      showsPreview = true
    }
    .onChange(of: showsPreview) { _, isShown in
      if isShown {
        actions.hoverPreview.previewOpened()
      } else {
        actions.hoverPreview.previewClosed(at: .now)
      }
    }
    .onDisappear {
      if showsPreview { actions.hoverPreview.previewClosed(at: .now) }
    }
    .popover(isPresented: $showsPreview, arrowEdge: .trailing) {
      SessionTreeHoverPreview(node: node, title: model.title)
    }
    .contextMenu { SessionRowMenu(node: node, actions: actions) }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var label: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      StatusGlyph(presentation: presentation)
        .frame(width: DesignTokens.Size.tile)
      SidebarIcon(glyph: node.providerKind.sidebarGlyph, size: 14)
        .foregroundStyle(isHovered || isSelected ? Color.wbTextPrimary : Color.wbTextTertiary)
      Text(model.title)
        .wbText(.body)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if let roleLabel = model.roleLabel {
        Text(roleLabel)
          .wbText(.subheadline)
          .foregroundStyle(Color.wbTextTertiary)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .padding(.leading, DesignTokens.Spacing.smPlus)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(model.title), \(node.providerKind.rawValue) session, \(presentation.word)"
        + (model.roleLabel.map { ", \($0)" } ?? ""))
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    if isSelected, !isElsewhere {
      shape.fill(Color.wbSurfaceRaised).wbElevation(.raised)
    } else if isSelected {
      shape.fill(Color.wbSurfaceSelected)
    } else if isHovered {
      shape.fill(Color.wbSurfaceHover)
    }
  }
}

// MARK: - Guide line

/// The vertical line that joins a branch's sessions, broken around the glyph.
/// Drawn in a fixed 30 pt overlay so it never takes part in layout.
private struct SessionGuideLine: View {
  let isFirst: Bool
  let isLast: Bool

  /// Centre of the lead column: row inset (10) + half the tile (9).
  private static let x = DesignTokens.Spacing.smPlus + DesignTokens.Size.tile / 2
  /// Gap above and below the glyph centre.
  private static let gap: CGFloat = 9
  /// The line stops this far above the last row's bottom.
  private static let lastInset: CGFloat = 6

  var body: some View {
    Path { path in
      let height = DesignTokens.Size.row
      let mid = height / 2
      path.move(to: CGPoint(x: Self.x, y: 0))
      path.addLine(to: CGPoint(x: Self.x, y: mid - Self.gap))
      let bottom = isLast ? height - Self.lastInset : height
      if bottom > mid + Self.gap {
        path.move(to: CGPoint(x: Self.x, y: mid + Self.gap))
        path.addLine(to: CGPoint(x: Self.x, y: bottom))
      }
    }
    .stroke(Color.wbBorderControl, lineWidth: 1)
    .frame(width: Self.x + 1, height: DesignTokens.Size.row)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

// MARK: - Approve pill

/// The Approve pill with the progress of the last click. Reads the approval
/// tracker in its own body, so only the pill redraws when the phase changes.
private struct SessionApprovePill: View {
  let node: SessionNode
  let actions: SidebarTreeActions

  var body: some View {
    let phase = actions.approvalPhase(for: node)
    let toolName = node.pendingToolName
    AttentionPill(
      title: "Approve",
      isBusy: Self.isBusy(phase),
      help: Self.help(phase, toolName: toolName),
      accessibilityLabel: toolName.map { "Approve \($0)" } ?? "Approve"
    ) { actions.approve(node) }
  }

  /// Spinner while the key is in flight and while an approved tool runs.
  private static func isBusy(_ phase: ApprovalResponsePhase?) -> Bool {
    switch phase {
    case .sending, .answered: true
    case .checkTerminal, .answerInTerminal, nil: false
    }
  }

  private static func help(_ phase: ApprovalResponsePhase?, toolName: String?) -> String {
    switch phase {
    case .answerInTerminal: "The app could not confirm Claude's menu. Answer in the terminal."
    // A click now is refused (already answered) and opens the session.
    case .checkTerminal: "Sent once. Check the terminal."
    default: toolName.map { "Allow \($0) once" } ?? "Allow once"
    }
  }
}

/// `.approve-pill`: attention tint, 24 pt high. While busy, a spinner covers
/// the title, which stays in layout so the pill keeps its width.
struct AttentionPill: View {
  let title: String
  var isBusy = false
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    // Taps are ignored while busy; `.disabled` would dim the spinner.
    Button { if !isBusy { action() } } label: {
      Text(title)
        .wbText(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(Color.wbStatusAttentionText)
        .opacity(isBusy ? 0 : 1)
        .overlay {
          if isBusy {
            ProgressView()
              .controlSize(.mini)
              .tint(Color.wbStatusAttentionText)
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .frame(height: DesignTokens.Size.controlSmall)
        .contentShape(Capsule())
        // Title ↔ spinner crossfade confirms the click. The width never
        // changes: the title is hidden by opacity, not removed.
        .animation(.wbAnimation(DesignTokens.Motion.fast), value: isBusy)
    }
    .buttonStyle(AttentionPillStyle(isHovered: isHovered, isBusy: isBusy))
    .onHover { isHovered = $0 }
    .fixedSize()
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(isBusy ? "Sending" : "")
  }
}

/// Colour-only hover and press for `AttentionPill`, instant: hover shows the
/// attention stroke; press keeps the stroke and adds a `wbSurfacePressed` fill.
/// No press effect while busy.
private struct AttentionPillStyle: ButtonStyle {
  let isHovered: Bool
  let isBusy: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed && !isBusy
    configuration.label
      .background {
        ZStack {
          Capsule().fill(Color.wbStatusAttentionTint)
          if isPressed {
            Capsule().fill(Color.wbSurfacePressed)
          }
        }
      }
      .overlay {
        Capsule()
          .strokeBorder(Color.wbStatusAttentionFill, lineWidth: 1)
          .opacity((isHovered || isPressed) && !isBusy ? 1 : 0)
      }
  }
}

// MARK: - Context menu

private struct SessionRowMenu: View {
  let node: SessionNode
  let actions: SidebarTreeActions

  var body: some View {
    Button("Open", systemImage: "arrow.right.circle") { actions.open(node) }
    if !node.isPending {
      Button("Copy Session ID", systemImage: "doc.on.doc") { actions.copySessionID(node) }
      if node.providerKind == .claude {
        Button("Open in Terminal", systemImage: "rectangle.portrait.and.arrow.right") {
          actions.openInTerminal(node)
        }
      }
      Button("Fork…", systemImage: "arrow.triangle.branch") { actions.fork(node) }
    }
    Divider()
    Button(
      node.isPending ? "Cancel Launch" : "Archive",
      systemImage: node.isPending ? "xmark" : "archivebox"
    ) {
      actions.archive(node)
    }
  }
}

// MARK: - Hover preview

/// `SessionHoverPreviewCard` for a tree row, with its own GitHub snapshot.
private struct SessionTreeHoverPreview: View {
  let node: SessionNode
  let title: String

  @Environment(\.agentHub) private var agentHub
  @State private var gitHubViewModel = SessionGitHubQuickAccessViewModel()

  var body: some View {
    SessionHoverPreviewCard(
      preview: preview,
      timestamp: node.session.lastActivityAt,
      gitHubViewModel: gitHubViewModel
    )
    .task {
      guard !node.isPending, let observationService = agentHub?.gitHubPRObservationService else {
        return
      }
      await gitHubViewModel.load(
        projectPath: node.session.projectPath,
        branchName: node.session.branchName,
        observationService: observationService,
        refreshOnSubscribe: false,
        recordInitialActivity: false,
        forceRefreshLinkedPullRequest: false
      )
    }
    .onDisappear { gitHubViewModel.stopPolling() }
  }

  private var preview: SessionHoverPreview {
    let repositories =
      agentHub.map {
        ShellSessionItems.repositories(
          claude: $0.claudeSessionsViewModel, codex: $0.codexSessionsViewModel)
      } ?? []
    return SessionHoverPreview.make(
      session: node.session,
      customName: title,
      repositories: repositories
    )
  }
}
