//
//  ApprovalBanner.swift
//  AgentHub
//
//  `ApprovalBanner` from the prototype: an overlay at the bottom of the
//  terminal area with the exact command or file, Deny, and Approve ⌘↩ with
//  "Always allow" in a chevron menu. It is an overlay on purpose: resizing the
//  terminal would resize the PTY in the middle of Claude's prompt. "Show in
//  terminal" moves it out of the way to reveal Claude's own menu.
//

import SwiftUI

// MARK: - Session overlay

/// Shows the banner for one Claude session while its permission prompt is
/// pending, and routes ⌘↩ in the terminal to Approve while it is visible.
struct SessionApprovalBannerOverlay: View {
  let sessionId: String
  let terminalKey: String
  let viewModel: CLISessionsViewModel

  var body: some View {
    // Claude permission prompts only; input questions are answered in the terminal.
    let pending = approvablePending
    let request = pending.map(ApprovalRequestKey.init(pending:))
    ZStack {
      if let pending, let request {
        ApprovalBannerHost(
          sessionId: sessionId,
          terminalKey: terminalKey,
          pending: pending,
          phase: viewModel.approvalTracker.phase(for: sessionId, request: request),
          viewModel: viewModel
        )
        // Fresh "Show in terminal" state and ⌘↩ registration per request.
        .id(request)
        .transition(Self.bannerTransition)
      }
    }
    // Scoped to this overlay: only the banner's opacity and offset change.
    // It floats over the terminal NSView, so no layout moves.
    .animation(.wbAnimation(DesignTokens.Motion.medium), value: request)
  }

  private var approvablePending: PendingToolUse? {
    guard let pending = viewModel.monitorStates[sessionId]?.pendingToolUse,
      pending.isApprovablePermission(providerKind: viewModel.providerKind)
    else { return nil }
    return pending
  }

  /// Rises 8 pt from the bottom edge it sits on (medium, ease-out); leaves
  /// with a shorter opacity-only fade (fast).
  static var bannerTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.combined(with: .offset(y: 8)),
      removal: .opacity.animation(.wbAnimation(DesignTokens.Motion.fast))
    )
  }
}

private struct ApprovalBannerHost: View {
  let sessionId: String
  let terminalKey: String
  let pending: PendingToolUse
  let phase: ApprovalResponsePhase?
  let viewModel: CLISessionsViewModel

  @State private var isRevealingTerminal = false

  var body: some View {
    Group {
      if isRevealingTerminal {
        ApprovalRevealedChip { isRevealingTerminal = false }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .transition(.opacity)
      } else {
        ApprovalBanner(
          presentation: ApprovalRequestPresentation(pending: pending),
          phase: phase,
          onDeny: { respond(.deny) },
          onApprove: { respond(.approveOnce) },
          onApproveAlways: { respond(.approveAlways) },
          onShowInTerminal: { isRevealingTerminal = true }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .transition(.opacity)
      }
    }
    // Banner ↔ chip crossfade: one control changing state, not a cut.
    .animation(.wbAnimation(DesignTokens.Motion.fast), value: isRevealingTerminal)
    .padding(DesignTokens.Spacing.lg)
    .onAppear {
      MainThreadStallMonitor.breadcrumb("approval: shown \(pending.toolName)")
      // `.id(request)` gives each request a fresh host, so this speaks once per request.
      AccessibilityNotification.Announcement(
        "Claude needs approval: \(ApprovalRequestPresentation(pending: pending).title)"
      ).post()
      updateShortcut()
    }
    .onChange(of: isRevealingTerminal) { _, _ in updateShortcut() }
    .onChange(of: phase) { _, _ in updateShortcut() }
    // Keyed by request: this runs after the exit fade, when the next
    // request's banner may already own ⌘↩.
    .onDisappear { viewModel.setApprovalShortcutHandler(forKey: terminalKey, request: request, nil) }
  }

  private var request: ApprovalRequestKey { ApprovalRequestKey(pending: pending) }

  private func respond(_ decision: ApprovalDecision) {
    viewModel.respondToApproval(sessionId: sessionId, decision: decision, terminalKey: terminalKey)
  }

  /// ⌘↩ approves while the banner offers Approve. With Claude's own menu
  /// revealed, or once the request was answered, the terminal gets its normal
  /// shortcut back. A second answer is refused by the view model regardless.
  private func updateShortcut() {
    guard !isRevealingTerminal, !(phase?.isAnswered ?? false) else {
      viewModel.setApprovalShortcutHandler(forKey: terminalKey, request: request, nil)
      return
    }
    let sessionId = sessionId
    let terminalKey = terminalKey
    viewModel.setApprovalShortcutHandler(forKey: terminalKey, request: request) { [weak viewModel] in
      viewModel?.respondToApproval(sessionId: sessionId, decision: .approveOnce, terminalKey: terminalKey)
    }
  }
}

// MARK: - Banner

struct ApprovalBanner: View {
  let presentation: ApprovalRequestPresentation
  let phase: ApprovalResponsePhase?
  let onDeny: () -> Void
  let onApprove: () -> Void
  let onApproveAlways: () -> Void
  let onShowInTerminal: () -> Void

  /// The text column's ideal width in the one-row layout. Below it the
  /// buttons move under the text, so the command keeps a readable width.
  static let rowTextIdealWidth: CGFloat = 220

  @State private var isShowingFullDetail = false

  var body: some View {
    // Layout only, no size → state: each option is measured, one is drawn.
    // The text columns carry an explicit ideal width, so a long command
    // never decides the layout by its unwrapped length.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DesignTokens.Spacing.md) {
        glyph
        text
          .frame(minWidth: 0, idealWidth: Self.rowTextIdealWidth, maxWidth: .infinity, alignment: .leading)
        trailing(isCompact: false)
      }
      stacked(isCompact: false)
      // Narrowest (260 pt session content): no key caps, and "Show in
      // terminal" moves into the chevron menu.
      stacked(isCompact: true)
    }
    .padding(.vertical, DesignTokens.Spacing.md)
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .background {
      // The dark tints are translucent; the terminal text must not show through.
      let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
      shape.fill(Color.wbSurfaceTerminal).overlay(shape.fill(Color.wbStatusAttentionTint))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Approval needed")
  }

  private var glyph: some View {
    StatusGlyph(status: .awaitingApproval(tool: "approval"), size: 16)
      .frame(width: 16, height: 16)
      .fixedSize()
  }

  /// Text on top, buttons trailing below it.
  private func stacked(isCompact: Bool) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
        glyph
          .padding(.top, 1)
        text
          .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
      }
      trailing(isCompact: isCompact)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(presentation.title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if let detail = presentation.fullDetail {
        ApprovalDetailText(detail: detail, isShowingAll: $isShowingFullDetail)
      }
      if let hint {
        Text(hint.text)
          .wbText(.subheadline)
          .foregroundStyle(Color.wbStatusAttentionText)
          .lineLimit(1)
          .help(hint.help)
      }
    }
  }

  private var hint: (text: String, help: String)? {
    switch phase {
    case .answerInTerminal:
      ("Answer in the terminal.", "The app could not confirm Claude's menu. Use “Show in terminal” to answer there.")
    case .checkTerminal:
      ("Sent. Check the terminal.", "The answer was sent once; the app can't confirm Claude took it.")
    default:
      nil
    }
  }

  /// Buttons only while nothing has been sent for this request: once a key went
  /// out, a second one could land in a running turn.
  /// A 120 ms crossfade between phases confirms the click was taken. Scoped
  /// to the trailing slot; the slot's children keep `.fixedSize()`.
  private func trailing(isCompact: Bool) -> some View {
    ZStack(alignment: .trailing) {
      trailingContent(isCompact: isCompact)
    }
    .animation(.wbAnimation(DesignTokens.Motion.fast), value: phase)
  }

  @ViewBuilder
  private func trailingContent(isCompact: Bool) -> some View {
    switch phase {
    case .sending(let decision):
      ApprovalStatusLabel(decision: decision, isSettled: false)
        .transition(.opacity)
    case .answered(let decision):
      ApprovalStatusLabel(decision: decision, isSettled: true)
        .transition(.opacity)
    case .checkTerminal:
      showInTerminalButton
        .transition(.opacity)
    case .answerInTerminal, nil:
      actions(isCompact: isCompact)
        .transition(.opacity)
    }
  }

  private var showInTerminalButton: some View {
    Button(action: onShowInTerminal) {
      Image(systemName: "terminal")
        .font(.system(size: 13, weight: .medium))
        .frame(width: DesignTokens.Size.control, height: DesignTokens.Size.control)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(Color.wbTextSecondary)
    .help("Show in terminal")
    .accessibilityLabel("Show in terminal")
  }

  private func actions(isCompact: Bool) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if !isCompact {
        showInTerminalButton
      }
      Button("Deny", action: onDeny)
        .buttonStyle(.wbSecondary)
        .help("Deny: Claude asks what to do instead")
      ApprovalSplitButton(
        showsKeyCaps: !isCompact,
        onApprove: onApprove,
        onApproveAlways: onApproveAlways,
        onShowInTerminal: isCompact ? onShowInTerminal : nil
      )
    }
    .fixedSize()
  }
}

// MARK: - Detail

/// The command, path or URL in mono. Short text shows whole. Longer text
/// shows four lines and "Show all", which opens the whole text in a scroll
/// area capped at `expandedMaxHeight`. The banner floats over the terminal,
/// so growing it never resizes the PTY.
private struct ApprovalDetailText: View {
  let detail: String
  @Binding var isShowingAll: Bool

  static let collapsedLineLimit = 4
  /// About five code lines: text up to that shows whole, longer text gets
  /// four lines plus the "Show all" row. Generous on purpose, so it holds
  /// whichever line height the code style resolves to.
  static let collapsedMaxHeight: CGFloat = 110
  static let expandedMaxHeight: CGFloat = 160

  var body: some View {
    if isShowingAll {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        // Whole text when it fits in 160 pt, else a scroll area that tall.
        HuggingMaxHeight(maxHeight: Self.expandedMaxHeight) {
          ViewThatFits(in: .vertical) {
            code
            ScrollView(.vertical) {
              code.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        toggle(title: "Show less")
      }
    } else {
      HuggingMaxHeight(maxHeight: Self.collapsedMaxHeight) {
        ViewThatFits(in: .vertical) {
          code
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            code.lineLimit(Self.collapsedLineLimit)
            toggle(title: "Show all")
          }
          // Never squeezed below its four lines by the height cap.
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var code: some View {
    Text(detail)
      .wbText(.code)
      .foregroundStyle(Color.wbTextPrimary)
      .textSelection(.enabled)
  }

  private func toggle(title: String) -> some View {
    Button {
      isShowingAll.toggle()
    } label: {
      Text(title)
        .wbText(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(Color.wbAccentText)
        .frame(height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isShowingAll ? "Show less of the command" : "Show the whole command")
  }
}

/// Offers its content at most `maxHeight` and takes the content's own
/// height. `.frame(maxHeight:)` would instead grow to the cap whenever the
/// parent offers more, leaving a gap under a short command. Layout only.
private struct HuggingMaxHeight: Layout {
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let height = proposal.height.map { min($0, maxHeight) } ?? maxHeight
    return content.sizeThatFits(ProposedViewSize(width: proposal.width, height: height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

// MARK: - Approve split button

/// Approve ⌘↩ plus a chevron menu with "Always allow". Mirrors the P2
/// `SplitButton`, which only takes a text title.
private struct ApprovalSplitButton: View {
  var showsKeyCaps = true
  let onApprove: () -> Void
  let onApproveAlways: () -> Void
  /// Set in the narrowest layout, where the banner has no room for the icon.
  var onShowInTerminal: (() -> Void)?

  @State private var isChevronHovered = false

  var body: some View {
    HStack(spacing: 1) {
      Button(action: onApprove) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text("Approve")
            .wbText(.bodyEmphasis)
          if showsKeyCaps {
            HStack(spacing: DesignTokens.Spacing.xxs) {
              OnAccentKeyCap("⌘")
              OnAccentKeyCap("↩")
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(ApprovalSplitLeftStyle())
      .keyboardShortcut(.return, modifiers: .command)
      .help("Allow once")
      .accessibilityLabel("Approve once")

      Menu {
        Button("Always allow", action: onApproveAlways)
        if let onShowInTerminal {
          Divider()
          Button("Show in terminal", action: onShowInTerminal)
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Color.wbTextOnAccent)
          .frame(width: 28, height: DesignTokens.Size.control)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(width: 28, height: DesignTokens.Size.control)
      .background(WBSplitChevronFill(isHovered: isChevronHovered))
      .onHover { isChevronHovered = $0 }
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 0, bottomLeadingRadius: 0,
          bottomTrailingRadius: DesignTokens.Radius.item, topTrailingRadius: DesignTokens.Radius.item)
      )
      .accessibilityLabel("More approval options")
    }
    .fixedSize()
  }
}

private struct ApprovalSplitLeftStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    // Colour-only hover and press, shared with the P2 `SplitButton`.
    WBSplitLeftBody(
      configuration: configuration,
      leadingPadding: DesignTokens.Spacing.md,
      trailingPadding: DesignTokens.Spacing.sm
    )
  }
}

/// `.button-primary .keycap`: a darker cap with on-accent text.
private struct OnAccentKeyCap: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Color.wbTextOnAccent)
      .frame(minWidth: 18, minHeight: 18)
      .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
      .accessibilityHidden(true)
  }
}

// MARK: - Progress and revealed states

/// "Approving…" while the key is in flight; "Approved" / "Denied" once the
/// menu went away (an approved tool may still be running).
private struct ApprovalStatusLabel: View {
  let decision: ApprovalDecision
  let isSettled: Bool

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if isSettled {
        Image(systemName: decision.isApproval ? "checkmark" : "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.wbTextSecondary)
          .accessibilityHidden(true)
      } else {
        ProgressView()
          .controlSize(.small)
      }
      Text(title)
        .wbText(.body)
        .foregroundStyle(Color.wbTextSecondary)
    }
    .frame(height: DesignTokens.Size.control)
    .fixedSize()
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    switch (decision.isApproval, isSettled) {
    case (true, false): "Approving…"
    case (false, false): "Denying…"
    case (true, true): "Approved"
    case (false, true): "Denied"
    }
  }
}

/// While Claude's own menu is revealed: a small chip in the top corner that
/// brings the banner back. The top keeps it clear of the menu at the bottom.
private struct ApprovalRevealedChip: View {
  let onShowBanner: () -> Void

  var body: some View {
    Button(action: onShowBanner) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        StatusGlyph(status: .awaitingApproval(tool: "approval"), size: 12)
          .frame(width: 12, height: 12)
        Text("Show approval")
          .wbText(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(Color.wbStatusAttentionText)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.controlSmall)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background {
      Capsule().fill(Color.wbSurfaceTerminal).overlay(Capsule().fill(Color.wbStatusAttentionTint))
    }
    .fixedSize()
    .help("Show the approval banner")
  }
}
