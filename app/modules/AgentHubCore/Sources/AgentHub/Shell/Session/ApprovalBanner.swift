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
    if let pending = viewModel.monitorStates[sessionId]?.pendingToolUse,
      pending.isApprovablePermission(providerKind: viewModel.providerKind)
    {
      let request = ApprovalRequestKey(pending: pending)
      ApprovalBannerHost(
        sessionId: sessionId,
        terminalKey: terminalKey,
        pending: pending,
        phase: viewModel.approvalTracker.phase(for: sessionId, request: request),
        viewModel: viewModel
      )
      // Fresh "Show in terminal" state and ⌘↩ registration per request.
      .id(request)
    }
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
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .onAppear {
      MainThreadStallMonitor.breadcrumb("approval: shown \(pending.toolName)")
      updateShortcut()
    }
    .onChange(of: isRevealingTerminal) { _, _ in updateShortcut() }
    .onChange(of: phase) { _, _ in updateShortcut() }
    .onDisappear { viewModel.setApprovalShortcutHandler(forKey: terminalKey, nil) }
  }

  private func respond(_ decision: ApprovalDecision) {
    viewModel.respondToApproval(sessionId: sessionId, decision: decision, terminalKey: terminalKey)
  }

  /// ⌘↩ approves while the banner offers Approve. With Claude's own menu
  /// revealed, or once the request was answered, the terminal gets its normal
  /// shortcut back. A second answer is refused by the view model regardless.
  private func updateShortcut() {
    guard !isRevealingTerminal, !(phase?.isAnswered ?? false) else {
      viewModel.setApprovalShortcutHandler(forKey: terminalKey, nil)
      return
    }
    let sessionId = sessionId
    let terminalKey = terminalKey
    viewModel.setApprovalShortcutHandler(forKey: terminalKey) { [weak viewModel] in
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

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      StatusGlyph(status: .awaitingApproval(tool: "approval"), size: 16)
        .frame(width: 16, height: 16)
        .fixedSize()
      text
        .frame(maxWidth: .infinity, alignment: .leading)
      trailing
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

  private var text: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(presentation.title)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
      if let detail = presentation.detail {
        Text(detail)
          .wbText(.code)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          // Paths keep the file name visible; commands keep their start.
          .truncationMode(presentation.kind == .fileEdit || presentation.kind == .fileWrite ? .middle : .tail)
          .help(detail)
          .textSelection(.enabled)
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
  @ViewBuilder
  private var trailing: some View {
    switch phase {
    case .sending(let decision):
      ApprovalStatusLabel(decision: decision, isSettled: false)
    case .answered(let decision):
      ApprovalStatusLabel(decision: decision, isSettled: true)
    case .checkTerminal:
      showInTerminalButton
    case .answerInTerminal, nil:
      actions
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

  private var actions: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      showInTerminalButton
      Button("Deny", action: onDeny)
        .buttonStyle(.wbSecondary)
        .help("Deny: Claude asks what to do instead")
      ApprovalSplitButton(onApprove: onApprove, onApproveAlways: onApproveAlways)
    }
    .fixedSize()
  }
}

// MARK: - Approve split button

/// Approve ⌘↩ plus a chevron menu with "Always allow". Mirrors the P2
/// `SplitButton`, which only takes a text title.
private struct ApprovalSplitButton: View {
  let onApprove: () -> Void
  let onApproveAlways: () -> Void

  var body: some View {
    HStack(spacing: 1) {
      Button(action: onApprove) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text("Approve")
            .wbText(.bodyEmphasis)
          HStack(spacing: DesignTokens.Spacing.xxs) {
            OnAccentKeyCap("⌘")
            OnAccentKeyCap("↩")
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
      } label: {
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.wbTextOnAccent)
          .frame(width: 28, height: DesignTokens.Size.control)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(width: 28, height: DesignTokens.Size.control)
      .background(Color.wbAccent)
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
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: DesignTokens.Radius.item, bottomLeadingRadius: DesignTokens.Radius.item,
      bottomTrailingRadius: 0, topTrailingRadius: 0)
    configuration.label
      .foregroundStyle(Color.wbTextOnAccent)
      .padding(.leading, DesignTokens.Spacing.md)
      .padding(.trailing, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.control)
      .background(configuration.isPressed ? Color.wbAccentHover : Color.wbAccent)
      .clipShape(shape)
      .overlay {
        shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false)
      }
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .animation(.spring(response: 0.12, dampingFraction: 1), value: configuration.isPressed)
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
