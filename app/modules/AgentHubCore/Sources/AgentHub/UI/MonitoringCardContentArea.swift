//
//  MonitoringCardContentArea.swift
//  AgentHub
//
//  The body of a session: Terminal, Chat, Files or Diffs. Moved out of
//  `MonitoringCardView` so the legacy card and the new shell's
//  `SessionDetailView` show the same content. The terminal is keyed by
//  `terminalKey` in the view model, so remounting this view (tab switch)
//  never recreates the PTY.
//

import SwiftUI

struct MonitoringCardContentArea: View {
  let session: CLISession
  let state: SessionMonitorState?
  let providerKind: SessionProviderKind
  let viewModel: CLISessionsViewModel?
  let hubProvider: AgentHubProvider?
  let terminalKey: String?
  let cliConfiguration: CLICommandConfiguration
  let initialPrompt: String?
  let initialInputText: String?
  let launchContext: String?
  let dangerouslySkipPermissions: Bool
  let permissionModePlan: Bool
  let worktreeName: String?
  /// The mode to show (already coerced to an available one).
  let mode: MonitoringCardContentMode
  @Binding var contentMode: MonitoringCardContentMode
  @Binding var selectedEditorFilePath: String?
  let editorProjectPath: String
  let editorNavigationRequest: FileExplorerNavigationRequest?
  let isPrimarySession: Bool
  let liveTerminalStatus: String?
  let onTerminalInteraction: (() -> Void)?
  let onRequestShowEditor: (() -> Void)?
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  var chatBackground = Color(nsColor: .windowBackgroundColor)

  var body: some View {
    switch mode {
    case .terminal:
      terminalContent
    case .chat:
      // The terminal stays mounted (invisible) under the chat: a new session only
      // starts once its terminal exists, and the composer types into it.
      ZStack {
        terminalContent
          .environment(\.isTerminalConcealed, true)
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        chatContent
      }
    case .editor:
      editorContent
    case .diffs:
      diffContent
    }
  }

  private var chatContent: some View {
    ChatTranscriptView(
      transcriptPath: session.sessionFilePath,
      providerKind: providerKind,
      reader: hubProvider?.chatTranscriptReader ?? ChatTranscriptReader(),
      onSend: { text in
        guard let viewModel else { return false }
        // Straight to this card's terminal first (also covers a session still
        // starting, whose id is only a placeholder that must not be monitored).
        if viewModel.sendPromptToActiveTerminal(forKey: terminalKey ?? session.id, prompt: text) {
          AppLogger.chat.notice("Chat sent to terminal \(terminalKey ?? session.id, privacy: .public)")
          return true
        }
        AppLogger.chat.notice("Chat terminal not ready for \(terminalKey ?? session.id, privacy: .public)")
        guard !session.id.hasPrefix("pending-") else { return false }
        return viewModel.sendAutomatedPrompt(to: session, prompt: text)
      },
      target: ChatSessionTarget(name: sessionDisplayName, providerKind: providerKind),
      // Only the active card's composer takes the keyboard; typing or focusing
      // the chat of another column makes that column active first.
      isActiveCard: isPrimarySession,
      onInteraction: onTerminalInteraction,
      liveTerminalStatus: liveTerminalStatus,
      terminalNotice: chatTerminalNotice,
      terminalFocusNotice: chatTerminalFocusNotice,
      onShowTerminal: { contentMode = .terminal },
      pendingApproval: state?.pendingToolUse.map { ($0.toolName, $0.input.map(ChatTranscriptReader.firstLine)) },
      onApprove: {
        // Allow once through the shared responder: agent tab only, and only
        // when Claude's permission menu is confirmed (otherwise the terminal).
        viewModel?.respondToApproval(
          sessionId: session.id, decision: .approveOnce, terminalKey: terminalKey) == .sent
      }
    )
    .background(chatBackground)
  }

  private var sessionDisplayName: String {
    viewModel?.displayName(for: session) ?? session.displayName
  }

  /// Things the chat can't show: approvals and a launch that hasn't written yet.
  private var chatTerminalNotice: String? {
    if case .awaitingApproval = state?.status {
      return "\(sessionDisplayName) is waiting for your approval in the terminal."
    }
    if session.sessionFilePath == nil {
      return "\(sessionDisplayName) is starting. Its first steps show in the terminal."
    }
    return nil
  }

  /// The terminal under the chat is on a child session tab. The chat does not
  /// follow it; it says so instead, so nothing is read or sent to the wrong agent.
  private var chatTerminalFocusNotice: String? {
    guard
      let linked = viewModel?.terminalWorkspaceSnapshots[terminalKey ?? session.id]?
        .activeLinkedSession
    else { return nil }
    return
      "The terminal is on child session \(linked.sessionId.prefix(8)) (\(linked.provider.rawValue)). This chat stays with \(sessionDisplayName)."
  }

  private var terminalContent: some View {
    MonitoringCardTerminalContent(
      terminalKey: terminalKey ?? session.id,
      sessionId: session.id,
      projectPath: session.projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      launchContext: launchContext,
      viewModel: viewModel,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      onUserInteraction: onTerminalInteraction,
      onRequestShowEditor: onRequestShowEditor,
      consumeQueuedWebPreviewContextOnSubmit: {
        viewModel?.consumeQueuedWebPreviewContextPrompt(for: session.id)
      }
    )
  }

  private var editorContent: some View {
    FileExplorerView(
      session: session,
      projectPath: editorProjectPath,
      onDismiss: { contentMode = .chat },
      isEmbedded: false,
      selectedFilePath: $selectedEditorFilePath,
      navigationRequest: editorNavigationRequest
    )
    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    .id("editor-\(session.id)")
  }

  private var diffContent: some View {
    GitDiffView(
      session: session,
      projectPath: session.projectPath,
      onDismiss: { contentMode = .chat },
      cliConfiguration: cliConfiguration,
      providerKind: providerKind,
      onInlineRequestSubmit: { prompt, sess in
        contentMode = .terminal
        if let onInlineRequestSubmit {
          onInlineRequestSubmit(prompt, sess)
        } else {
          viewModel?.showTerminalWithPrompt(for: sess, prompt: prompt)
        }
      },
      isEmbedded: false
    )
    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    .id("diffs-\(session.id)")
  }
}
