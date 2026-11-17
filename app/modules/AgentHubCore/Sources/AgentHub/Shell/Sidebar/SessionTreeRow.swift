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
  @State private var showsResult = false
  @State private var accessibilityCallbacks = SidebarTreeAccessibilityRowCallbacks()
  @Environment(\.sidebarTreeAccessibilityRegistry) private var accessibilityRegistry
  @Environment(SessionDetailStateModel.self) private var resultDetailState

  nonisolated static func == (lhs: SessionTreeRow, rhs: SessionTreeRow) -> Bool {
    lhs.model == rhs.model && lhs.isSelected == rhs.isSelected && lhs.isElsewhere == rhs.isElsewhere
  }

  private var node: SessionNode { model.node }

  var body: some View {
    HStack(spacing: 0) {
      Button {
        actions.open(node)
      } label: {
        SessionTreeRowLabel(model: model)
      }
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
    .frame(minHeight: DesignTokens.Size.row)
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
    .onAppear {
      accessibilityCallbacks.showResult = { showsResult = true }
      accessibilityRegistry?.register(accessibilityCallbacks, for: model.id)
    }
    .onDisappear {
      accessibilityRegistry?.unregister(accessibilityCallbacks, for: model.id)
      if showsPreview { actions.hoverPreview.previewClosed(at: .now) }
    }
    .popover(isPresented: $showsPreview, arrowEdge: .trailing) {
      SessionTreeHoverPreview(node: node, title: model.title)
    }
    .contextMenu { SessionRowMenu(node: node, actions: actions, onShowResult: { showsResult = true }) }
    .sheet(isPresented: $showsResult) {
      SessionResultView(session: node.session, provider: node.providerKind, agentHub: actions.agentHub,
        filesActionLabel: "Reveal files",
        onTerminal: {
          resultDetailState.setShowsResult(false, for: node.id)
          resultDetailState.setContentMode(.terminal, for: node.id, defaultProjectPath: node.session.projectPath)
          showsResult = false
          actions.open(node)
        },
        onFiles: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.session.projectPath) },
        onChecks: { showsResult = false; actions.showGitHub(path: node.session.projectPath) })
        .frame(minWidth: 700, minHeight: 550)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// Pure label shared by the row and its visual fixture.
struct SessionTreeRowLabel: View {
  let model: SessionRowModel
  private var node: SessionNode { model.node }
  private var presentation: SessionStatusPresentation {
    SessionStatusPresentation(status: node.status, isPending: node.isPending)
  }

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.smPlus) {
      StatusGlyph(presentation: presentation)
        .frame(width: DesignTokens.Size.tile, height: DesignTokens.Size.tile)
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(model.title).wbText(.body).foregroundStyle(Color.wbTextPrimary)
            .lineLimit(1).truncationMode(.tail)
          if model.isUnread {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityHidden(true)
          }
          if model.showProvider {
            SidebarIcon(glyph: node.providerKind.sidebarGlyph, size: 14)
              .foregroundStyle(Color.wbTextTertiary)
          }
          Spacer(minLength: 0)
          if let roleLabel = model.roleLabel {
            Text(roleLabel).wbText(.subheadline).foregroundStyle(Color.wbTextTertiary).lineLimit(1)
          }
        }
        if (model.diff?.fileCount ?? 0) > 0 || model.action != nil {
          HStack(spacing: DesignTokens.Spacing.sm) {
            if let diff = model.diff, diff.fileCount > 0 {
              DiffStat(additions: diff.additions, deletions: diff.deletions)
                .help("Worktree changes")
            }
            if let action = model.action {
              Text(action).wbText(.subheadline).foregroundStyle(Color.wbTextTertiary).lineLimit(1)
            }
          }
        }
      }
    }
    .padding(.leading, SidebarTreeInset.session)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.sidebarAccessibilityLabel)
  }

}

extension SessionRowModel {
  var sidebarAccessibilityLabel: String {
    let status = SessionStatusPresentation(status: node.status, isPending: node.isPending)
    return "\(title), \(node.providerKind.agentDisplayName) session, \(status.accessibilityLabel)"
      + (roleLabel.map { ", \($0)" } ?? "")
      + (action.map { ", \($0)" } ?? "")
      + (diff.flatMap {
        $0.fileCount > 0 ? ", Worktree changes: \($0.additions) additions, \($0.deletions) deletions" : nil
      } ?? "")
      + (isUnread ? ", Unread updates" : "")
  }
}

// MARK: - Guide line

/// The vertical line that joins a branch's sessions, broken around the glyph.
/// Drawn in a fixed 30 pt overlay so it never takes part in layout.
private struct SessionGuideLine: View {
  let isFirst: Bool
  let isLast: Bool

  /// Centre of the session status column.
  fileprivate static let x = SidebarTreeInset.session + DesignTokens.Size.tile / 2
  /// Gap above and below the glyph centre.
  fileprivate static let gap: CGFloat = 9
  /// The line stops this far above the last row's bottom.
  fileprivate static let lastInset: CGFloat = 6

  var body: some View {
    GuideShape(isLast: isLast)
      .stroke(Color.wbBorderControl, lineWidth: 1)
      .frame(width: SessionGuideLine.x + 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct GuideShape: Shape {
  let isLast: Bool
  func path(in rect: CGRect) -> Path {
    Path { path in
      let height = rect.height
      let mid = DesignTokens.Spacing.xs + DesignTokens.Size.tile / 2
      path.move(to: CGPoint(x: SessionGuideLine.x, y: 0))
      path.addLine(to: CGPoint(x: SessionGuideLine.x, y: mid - SessionGuideLine.gap))
      let bottom = isLast ? height - SessionGuideLine.lastInset : height
      if bottom > mid + SessionGuideLine.gap {
        path.move(to: CGPoint(x: SessionGuideLine.x, y: mid + SessionGuideLine.gap))
        path.addLine(to: CGPoint(x: SessionGuideLine.x, y: bottom))
      }
    }
  }
}

// MARK: - Approve pill

/// The Approve pill with the progress of the last answer. It opens the
/// session, whose banner shows the whole command (`SidebarApprovePillText`).
/// Reads the approval tracker in its own body, so only the pill redraws
/// when the phase changes.
private struct SessionApprovePill: View {
  let node: SessionNode
  let actions: SidebarTreeActions

  var body: some View {
    let phase = actions.approvalPhase(for: node)
    let presentation = actions.approvalPresentation(for: node)
    AttentionPill(
      title: "Review request",
      isBusy: SidebarApprovePillText.isBusy(phase),
      help: SidebarApprovePillText.help(phase, presentation: presentation),
      accessibilityLabel: SidebarApprovePillText.accessibilityLabel(
        toolName: node.pendingToolName, presentation: presentation)
    ) { actions.open(node) }
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
  let onShowResult: () -> Void

  var body: some View {
    SidebarMenuCommands(
      entries: sessionMenuEntries(node: node, actions: actions, onShowResult: onShowResult))
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
