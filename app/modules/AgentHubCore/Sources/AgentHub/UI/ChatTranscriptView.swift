//
//  ChatTranscriptView.swift
//  AgentHub
//
//  A chat layer over a session transcript: your messages on the right, the agent
//  on the left, tool steps as compact rows. Updates when the transcript file
//  changes (kqueue), not on a timer. The composer types into the real session.
//

import AppKit
import SwiftUI

/// Who receives what you type in the chat. Shown above the composer so a child
/// terminal tab or another column can never be mistaken for this session.
struct ChatSessionTarget: Equatable {
  let name: String
  let providerKind: SessionProviderKind
  /// "main session" for a card; nil for a read-only subagent window.
  var scope: String? = "main session"
}

// Native SelectableChatText provides selection without the SwiftUI overlay that
// previously caused repeated layout and freezes on opening long chats.
struct ChatTranscriptView: View {
  let transcriptPath: String?
  let providerKind: SessionProviderKind
  /// Sends a message into the session; nil makes the view read-only (subagents).
  var onSend: ((String) -> Bool)?
  /// The session this chat belongs to; names the composer and the empty states.
  var target: ChatSessionTarget? = nil
  /// Only the active card's composer may take the keyboard. Background columns
  /// keep their draft and selection but never steal focus.
  var isActiveCard = true
  /// The user focused or typed in this chat; the owner makes this card active.
  var onInteraction: (() -> Void)? = nil
  /// A line the terminal screen shows right now that no file records while it
  /// happens ("Compacting context (3m 28s)"). Nil when absent or unreadable.
  var liveTerminalStatus: String? = nil
  /// Something only the terminal shows right now (an approval prompt).
  var terminalNotice: String? = nil
  /// The terminal is focused on another session (a child tab); the chat stays with `target`.
  var terminalFocusNotice: String? = nil
  var onShowTerminal: (() -> Void)? = nil
  /// The tool call waiting for approval, when known (Claude reports it).
  var pendingApproval: (tool: String, detail: String?)? = nil
  /// Approves in the terminal (selects the first option); returns false if it couldn't.
  var onApprove: (() -> Bool)? = nil

  @State private var loader: ChatTranscriptLoader
  @State private var draft = ""
  @State private var sendFailed = false
  /// Sends the transcript has not confirmed yet; per card, so per session.
  @State private var outbox = ChatOutbox()
  /// How many of the newest groups are shown; older ones load on request. Opening
  /// a session scrolls to the bottom, which lays out every row above it.
  @State private var visibleGroupLimit = Self.pageSize

  static let pageSize = 60

  /// Width of the chat column: messages and composer share it.
  static let contentWidth: CGFloat = 820

  init(
    transcriptPath: String?,
    providerKind: SessionProviderKind,
    reader: any ChatTranscriptReading,
    onSend: ((String) -> Bool)?,
    target: ChatSessionTarget? = nil,
    isActiveCard: Bool = true,
    onInteraction: (() -> Void)? = nil,
    liveTerminalStatus: String? = nil,
    terminalNotice: String? = nil,
    terminalFocusNotice: String? = nil,
    onShowTerminal: (() -> Void)? = nil,
    pendingApproval: (tool: String, detail: String?)? = nil,
    onApprove: (() -> Bool)? = nil
  ) {
    self.transcriptPath = transcriptPath
    self.providerKind = providerKind
    self.onSend = onSend
    self.target = target
    self.isActiveCard = isActiveCard
    self.onInteraction = onInteraction
    self.liveTerminalStatus = liveTerminalStatus
    self.terminalNotice = terminalNotice
    self.terminalFocusNotice = terminalFocusNotice
    self.onShowTerminal = onShowTerminal
    self.pendingApproval = pendingApproval
    self.onApprove = onApprove
    _loader = State(initialValue: ChatTranscriptLoader(reader: reader))
  }

  private var items: [ChatTranscriptItem] { loader.items }

  private var targetName: String { target?.name ?? "the agent" }

  /// A successful submit means the text reached the terminal, nothing more.
  /// It stays "awaiting confirmation" until a queue record or a new user
  /// message in the transcript shows it, and it is what Arrow Up recalls.
  private func send(_ text: String, via onSend: (String) -> Bool) -> Bool {
    onInteraction?()
    guard onSend(text) else {
      sendFailed = true
      return false
    }
    sendFailed = false
    outbox.record(text, items: items, runtime: loader.runtime)
    return true
  }

  private func reconcileOutbox() {
    outbox.reconcile(items: items, runtime: loader.runtime)
  }

  var body: some View {
    VStack(spacing: 0) {
      if let terminalNotice, let onShowTerminal {
        approvalBanner(terminalNotice, onShowTerminal: onShowTerminal)
        Divider()
      }
      if let terminalFocusNotice, let onShowTerminal {
        ChatNoticeRow(systemImage: "arrow.triangle.branch", text: terminalFocusNotice) {
          Button("Show terminal", action: onShowTerminal)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        Divider()
      }
      if let liveTerminalStatus {
        // From the agent tab's screen, right now. Only the terminal has it.
        ChatNoticeRow(
          systemImage: liveTerminalStatus.hasPrefix("Awaiting your answer")
            ? "questionmark.bubble" : "arrow.down.right.and.arrow.up.left",
          text: liveTerminalStatus
        ) {
          if let onShowTerminal {
            Button("Show terminal", action: onShowTerminal)
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
        .accessibilityLabel("Terminal shows: \(liveTerminalStatus)")
        Divider()
      }
      if let line = ChatRuntimeText.backgroundTaskLine(loader.runtime.unfinishedBackgroundTasks) {
        ChatNoticeRow(systemImage: "terminal", text: line) { EmptyView() }
          .accessibilityLabel(line)
        Divider()
      }
      content
      if let onSend {
        Divider()
        // Same column as the messages, so the composer lines up with the chat.
        VStack(spacing: 0) {
          if !quickReplies.isEmpty {
            QuickReplyBar(replies: quickReplies) { reply in
              _ = send(reply, via: onSend)
            }
          }
          ChatComposer(
            draft: $draft, target: target, isActiveCard: isActiveCard, sendFailed: sendFailed,
            onInteraction: onInteraction,
            onRecall: {
              ChatComposerHistory.recall(
                draft: draft, lastSubmitted: outbox.lastSubmission, items: items)
            }
          ) {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if send(text, via: onSend) { draft = "" }
          }
          .id(transcriptPath)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg - DesignTokens.Spacing.md)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
      }
    }
    .task(id: transcriptPath) {
      let file = transcriptPath.map { ($0 as NSString).lastPathComponent } ?? "none"
      AppLogger.chat.notice("Chat opened: \(file, privacy: .public)")
      MainThreadStallMonitor.breadcrumb("chat opened: \(file)")
      visibleGroupLimit = Self.pageSize
      outbox.clear()  // another session's queue must never show here
      loader.load(path: transcriptPath, provider: providerKind)
    }
    .onChange(of: items) { _, _ in reconcileOutbox() }
    .onChange(of: loader.runtime) { _, _ in reconcileOutbox() }
    .onDisappear { loader.cancel() }
    // kqueue, not a timer: reload only when the file (or its folder) changes.
    .background(
      TranscriptFileWatcher(path: transcriptPath) {
        loader.load(path: transcriptPath, provider: providerKind)
      })
  }

  @ViewBuilder
  private var content: some View {
    switch loader.phase {
    case .noTranscript:
      ChatEmptyState(
        title: "Waiting for the first message",
        systemImage: "bubble.left.and.bubble.right",
        message: "The chat fills in once \(targetName) writes its first message. The terminal shows what is happening until then.",
        onShowTerminal: onShowTerminal)
    case .loading where items.isEmpty:
      VStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Loading conversation…")
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    case .missing:
      ChatEmptyState(
        title: "Transcript not found",
        systemImage: "doc.questionmark",
        message: "\(targetName) has not written this file, or it was moved. Workbench loads it when it appears. If nothing happens, try again or check the terminal.",
        detail: transcriptPath,
        onRetry: { loader.load(path: transcriptPath, provider: providerKind) },
        onShowTerminal: onShowTerminal)
    case .ready where items.isEmpty && outbox.entries.isEmpty && loader.runtime.visibleQueue.isEmpty:
      ChatEmptyState(
        title: "No messages yet",
        systemImage: "bubble.left.and.bubble.right",
        message: onSend == nil
          ? "This transcript has no messages to show."
          : "Write to \(targetName) below. The reply shows up here.",
        onShowTerminal: nil)
    default:
      messages
    }
  }

  private func approvalBanner(_ terminalNotice: String, onShowTerminal: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(pendingApproval.map { "\(targetName) asks to run \($0.tool)" } ?? terminalNotice)
          .font(.secondaryDefault.weight(.semibold))
        if let detail = pendingApproval?.detail, !detail.isEmpty {
          Text(detail)
            .font(.jetBrainsMono(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
      Spacer()
      if pendingApproval != nil, let onApprove {
        Button("Approve") { _ = onApprove() }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .controlSize(.small)
          .help("Allow once: picks the first option in \(targetName)'s terminal prompt")
          .accessibilityLabel("Approve \(pendingApproval?.tool ?? "tool") in \(targetName)")
      }
      Button("Show terminal", action: onShowTerminal)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.12))
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        // VStack, not LazyVStack: a lazy stack with rows of varying height plus
        // scrolling to the bottom kept re-measuring and froze the app. At most
        // `pageSize` groups are built, so an eager stack stays cheap.
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
          let groups = groupedItems
          if groups.count > visibleGroupLimit {
            Button("Show earlier messages (\(groups.count - visibleGroupLimit))") {
              visibleGroupLimit += Self.pageSize
            }
            .buttonStyle(.borderless)
            .font(.secondaryDefault)
            .frame(maxWidth: .infinity)
          }
          ForEach(groups.suffix(visibleGroupLimit)) { group in
            ChatGroupView(group: group, providerKind: providerKind)
              .id(group.id)
          }
          // Evidence first: what Claude Code's own queue records say is waiting
          // behind the running turn (typed here or in the terminal).
          ForEach(loader.runtime.visibleQueue) { queued in
            QueuedBubble(
              text: queued.text, systemImage: "clock",
              label: "Queued by the CLI · sends after the current step", onDismiss: nil)
            .id("queue-\(queued.id)")
          }
          // Then what this card handed to the terminal with no evidence yet.
          ForEach(outbox.entriesAwaitingConfirmation(runtime: loader.runtime)) { entry in
            QueuedBubble(
              text: entry.text, systemImage: "questionmark.circle",
              label: "Handed to the terminal · awaiting confirmation", onDismiss: { outbox.dismiss(entry.id) })
            .id("outbox-\(entry.id)")
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: Self.contentWidth)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: items.count) { oldCount, newCount in
        // Follow new messages; the first load starts at the bottom via the anchor.
        guard oldCount > 0, newCount > oldCount else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .onChange(of: outbox.entries.count + loader.runtime.visibleQueue.count) { oldCount, newCount in
        guard newCount > oldCount else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
      }
    }
  }

  /// Consecutive tool steps collapse into one group so the chat stays readable.
  /// Background-task notices feed the status line, not the message list.
  private var groupedItems: [ChatGroup] {
    var groups: [ChatGroup] = []
    for item in items {
      if case .notice(let notice) = item.kind, !notice.isCompaction { continue }
      if case .tool = item.kind, case .tools(let tools)? = groups.last?.content {
        groups[groups.count - 1] = ChatGroup(id: groups[groups.count - 1].id, content: .tools(tools + [item]))
      } else if case .tool = item.kind {
        groups.append(ChatGroup(id: item.id, content: .tools([item])))
      } else {
        groups.append(ChatGroup(id: item.id, content: .message(item)))
      }
    }
    return groups
  }

  /// One-tap answers when the agent's last message asks something.
  private var quickReplies: [QuickReply] {
    guard case .assistant(let text)? = items.last?.kind else { return [] }
    return QuickReply.replies(for: text)
  }

}

/// An empty or waiting chat: a title, one line that says what happens next, and
/// the way to see more (the terminal) when there is one.
private struct ChatEmptyState: View {
  let title: String
  let systemImage: String
  let message: String
  var detail: String? = nil
  var onRetry: (() -> Void)? = nil
  let onShowTerminal: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .light))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title)
        .font(.geist(size: 14, weight: .semibold))
      Text(message)
        .font(.secondaryDefault)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      if let detail {
        Text(detail)
          .font(.jetBrainsMono(size: 10))
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: 480)
      }
      HStack(spacing: 8) {
        if let onRetry {
          Button("Try again", action: onRetry)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Read the transcript file again now")
        }
        if let onShowTerminal {
          Button("Show terminal", action: onShowTerminal)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
      .padding(.top, 4)
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A quiet one-line notice above the chat with an action on the right.
private struct ChatNoticeRow<Action: View>: View {
  let systemImage: String
  let text: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .font(.secondaryDefault)
        .lineLimit(2)
      Spacer()
      action()
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.04))
  }
}

struct ChatGroup: Identifiable {
  enum Content {
    case message(ChatTranscriptItem)
    case tools([ChatTranscriptItem])
  }

  let id: String
  let content: Content
}

// MARK: - ChatGroupView

private struct ChatGroupView: View {
  let group: ChatGroup
  let providerKind: SessionProviderKind

  var body: some View {
    switch group.content {
    case .message(let item):
      switch item.kind {
      case .user(let text): UserBubble(text: text)
      case .assistant(let text): AssistantMessage(text: text, providerKind: providerKind)
      case .tool: EmptyView()
      case .notice(.contextCompacted(let preTokens, let durationMs)):
        CompactionDivider(text: ChatRuntimeText.compactionLine(preTokens: preTokens, durationMs: durationMs))
      }
    case .tools(let tools):
      ToolStepsView(tools: tools)
    }
  }
}

/// Where the context was compacted: a quiet rule with the facts the record holds.
private struct CompactionDivider: View {
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
      Label(text, systemImage: "arrow.down.right.and.arrow.up.left")
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
      Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
  }
}

/// A message that is not in the conversation yet: queued by the CLI (evidence)
/// or handed to the terminal by this card (awaiting evidence).
private struct QueuedBubble: View {
  let text: String
  let systemImage: String
  let label: String
  let onDismiss: (() -> Void)?
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack {
      Spacer(minLength: 80)
      VStack(alignment: .trailing, spacing: 4) {
        SelectableChatText(text: text)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(
                Color.brandPrimary(from: runtimeTheme).opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          )
        HStack(spacing: 6) {
          Image(systemName: systemImage)
            .font(.system(size: 9))
            .accessibilityHidden(true)
          Text(label)
            .font(.secondaryCaption)
          if let onDismiss {
            Button(action: onDismiss) {
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide this marker")
            .accessibilityLabel("Dismiss unconfirmed message marker")
          }
        }
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(label): \(text)")
  }
}

private struct UserBubble: View {
  let text: String
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    HStack {
      Spacer(minLength: 80)
      SelectableChatText(text: text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.brandPrimary(from: runtimeTheme).opacity(0.18))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.brandPrimary(from: runtimeTheme).opacity(0.3), lineWidth: 1)
        )
    }
    .accessibilityLabel("You: \(text)")
  }
}

private struct AssistantMessage: View {
  let text: String
  let providerKind: SessionProviderKind

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(Color.brandPrimary(for: providerKind))
        .frame(width: 22, height: 22)
        .overlay(
          Text(String(providerKind.rawValue.prefix(1)))
            .font(.geist(size: 11, weight: .bold))
            .foregroundStyle(.white)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        // Not MarkdownUI: its layout made opening a long session freeze the app.
        ChatMarkdownText(text: text)
          .frame(maxWidth: .infinity, alignment: .leading)
        let blocks = ChatCodeBlocks.extract(from: text)
        if !blocks.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
              CopyChip(label: block.preview, value: block.code, monospaced: true)
            }
          }
        }
      }
      VStack {
        CopyChip(label: nil, value: text, monospaced: false)
        Spacer()
      }
      .frame(width: 40)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct ToolStepsView: View {
  let tools: [ChatTranscriptItem]
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Image(systemName: "wrench.and.screwdriver")
            .font(.system(size: 10))
          Text(summary)
            .font(.secondarySmall)
            .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isExpanded {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(tools) { tool in
            if case .tool(let name, let detail) = tool.kind {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                  .font(.geist(size: 11, weight: .semibold))
                Text(detail)
                  .font(.jetBrainsMono(size: 11))
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
        .padding(.leading, 26)
      }
    }
    .padding(.leading, 32)
  }

  /// "Ran git status" for one step, "5 steps · Bash, Read" for several.
  private var summary: String {
    if tools.count == 1, case .tool(let name, let detail) = tools[0].kind {
      return detail.isEmpty ? name : "\(name) · \(detail)"
    }
    var names: [String] = []
    for tool in tools {
      if case .tool(let name, _) = tool.kind, !names.contains(name) { names.append(name) }
    }
    return "\(tools.count) steps · " + names.prefix(4).joined(separator: ", ")
  }
}

// MARK: - ChatComposer

/// Which chat composer may take the keyboard. One policy for every card so
/// background columns never pull focus when their hidden terminal starts.
enum ChatComposerFocusPolicy {
  /// True only for the active card; a column in the background keeps its
  /// draft and selection but must not become first responder on its own.
  static func shouldTakeFocus(isActiveCard: Bool) -> Bool {
    isActiveCard
  }

  /// Focusing a background composer is a user action: that card becomes active.
  static func shouldActivateCard(isActiveCard: Bool, composerFocused: Bool) -> Bool {
    composerFocused && !isActiveCard
  }
}

private struct ChatComposer: View {
  @Binding var draft: String
  let target: ChatSessionTarget?
  let isActiveCard: Bool
  let sendFailed: Bool
  let onInteraction: (() -> Void)?
  /// Arrow Up on an empty field: the previous message to edit, or nil.
  let onRecall: () -> String?
  let onSend: () -> Void

  @FocusState private var isFocused: Bool
  @Environment(\.runtimeTheme) private var runtimeTheme

  private var targetName: String { target?.name ?? "the agent" }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let target {
        // Who gets this message. Always visible, so a child terminal tab or a
        // neighbouring column can never be mistaken for the destination.
        HStack(spacing: 6) {
          Circle()
            .fill(Color.brandPrimary(for: target.providerKind))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text("To \(target.name)")
            .font(.secondarySmall.weight(.semibold))
            .lineLimit(1)
          Text([target.providerKind.rawValue, target.scope].compactMap { $0 }.joined(separator: " · "))
            .font(.secondarySmall)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "Messages go to \(target.name), \(target.providerKind.rawValue)\(target.scope.map { ", \($0)" } ?? "")")
      }
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Message \(targetName)", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.geist(size: 13))
          .lineLimit(1...8)
          .focused($isFocused)
          .onKeyPress(.return, phases: .down) { press in
            // Return sends; Shift+Return adds a line.
            if press.modifiers.contains(.shift) { return .ignored }
            onSend()
            return .handled
          }
          .onKeyPress(.upArrow, phases: .down) { press in
            // Only a plain Up in an empty field recalls. Text, modifiers, or
            // IME marked text keep the key's own meaning. Recall never sends.
            let editor = NSApp.keyWindow?.firstResponder as? NSTextView
            guard
              ChatRecallKeyPolicy.shouldRecall(
                draftIsEmpty: draft.isEmpty,
                hasModifiers: !press.modifiers.isEmpty,
                hasMarkedText: editor?.hasMarkedText() ?? false),
              let previous = onRecall()
            else { return .ignored }
            draft = previous
            return .handled
          }
          .accessibilityLabel("Message to \(targetName)")
          .accessibilityHint("Arrow Up in an empty field brings back your previous message")
        Button(action: onSend) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(
              draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.brandPrimary(from: runtimeTheme)))
        }
        .buttonStyle(.plain)
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help("Send to \(targetName) (Return). Shift+Return for a new line. Arrow Up recalls your last message.")
        .accessibilityLabel("Send to \(targetName)")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(
            isFocused ? Color.brandPrimary(from: runtimeTheme).opacity(0.6) : Color.primary.opacity(0.08),
            lineWidth: 1)
      )
      if sendFailed {
        Text("Could not reach \(targetName)'s terminal. Open Terminal once so it starts, then send again.")
          .font(.secondaryCaption)
          .foregroundStyle(.orange)
          .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .padding(DesignTokens.Spacing.md)
    // Focus once on activation; delayed retries would steal text selections.
    .task(id: isActiveCard) {
      guard ChatComposerFocusPolicy.shouldTakeFocus(isActiveCard: isActiveCard) else { return }
      // Let the newly mounted field join its window before requesting focus.
      await Task.yield()
      guard !Task.isCancelled else { return }
      isFocused = true
    }
    // Clicking into a background column's composer is how it becomes active.
    .onChange(of: isFocused) { _, focused in
      if ChatComposerFocusPolicy.shouldActivateCard(isActiveCard: isActiveCard, composerFocused: focused) {
        onInteraction?()
      }
    }
  }
}

// MARK: - Copy

enum ChatClipboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// Fenced code blocks in a message, so each command can be copied in one click.
enum ChatCodeBlocks {
  struct Block: Equatable {
    let code: String
    var preview: String {
      let first = code.split(separator: "\n").first.map(String.init) ?? code
      return first.count > 60 ? String(first.prefix(59)) + "…" : first
    }
  }

  static func extract(from markdown: String) -> [Block] {
    var blocks: [Block] = []
    var current: [String]?
    for line in markdown.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let lines = current {
          let code = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
          if !code.isEmpty { blocks.append(Block(code: code)) }
          current = nil
        } else {
          current = []
        }
      } else if current != nil {
        current?.append(line)
      }
    }
    return blocks
  }
}

private struct CopyChip: View {
  let label: String?
  let value: String
  let monospaced: Bool
  @State private var didCopy = false

  var body: some View {
    Button {
      ChatClipboard.copy(value)
      didCopy = true
    } label: {
      HStack(spacing: 5) {
        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
          .font(.system(size: 10, weight: .semibold))
        if let label {
          Text(label)
            .font(monospaced ? .jetBrainsMono(size: 11) : .secondarySmall)
            .lineLimit(1)
        }
      }
      .foregroundStyle(didCopy ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
      .padding(.horizontal, 8)
      .frame(height: 22)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label == nil ? "Copy message" : "Copy this code")
    .accessibilityLabel(label.map { "Copy code: \($0)" } ?? "Copy message")
    .accessibilityValue(didCopy ? "Copied" : "")
    .task(id: didCopy) {
      guard didCopy else { return }
      try? await Task.sleep(for: .seconds(1.5))
      didCopy = false
    }
  }
}

// MARK: - Quick replies

struct QuickReply: Identifiable, Equatable {
  let label: String
  let message: String
  var id: String { label }

  /// Answers for a message that ends in a question: its numbered options (up to
  /// four) when it lists them, plus a plain yes and no.
  static func replies(for text: String) -> [QuickReply] {
    let paragraphs = text.components(separatedBy: "\n\n").filter {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let tail = paragraphs.suffix(3).joined(separator: "\n\n") as String?,
      tail.contains("?")
    else { return [] }
    var replies: [QuickReply] = []
    for line in tail.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let match = trimmed.range(of: #"^([1-9])[\.\)]\s+"#, options: .regularExpression)
      else { continue }
      let number = String(trimmed[match].prefix(1))
      let option = trimmed[match.upperBound...]
        .replacingOccurrences(of: "**", with: "")
      let short = option.count > 32 ? String(option.prefix(31)) + "…" : option
      replies.append(QuickReply(label: "\(number) · \(short)", message: number))
      if replies.count == 4 { break }
    }
    replies.append(QuickReply(label: "Yes, go ahead", message: "Yes, go ahead."))
    replies.append(QuickReply(label: "No", message: "No."))
    return replies
  }
}

private struct QuickReplyBar: View {
  let replies: [QuickReply]
  let onSelect: (String) -> Void
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(replies) { reply in
          Button(reply.label) { onSelect(reply.message) }
            .buttonStyle(.plain)
            .font(.secondaryDefault)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
              Capsule().fill(Color.brandPrimary(from: runtimeTheme).opacity(0.12)))
            .overlay(
              Capsule().strokeBorder(Color.brandPrimary(from: runtimeTheme).opacity(0.3), lineWidth: 1))
            .help("Send \"\(reply.message)\"")
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.top, DesignTokens.Spacing.sm)
    }
    .scrollIndicators(.never)
  }
}

// MARK: - ChatMarkdownText

/// Fast markdown for chat: inline styles (bold, italic, `code`, links) through
/// Foundation's parser, fenced code as monospaced blocks. Line breaks are kept.
/// A markdown table as a grid; the header row is bold, rows are divided by lines.
private struct ChatMarkdownTable: View {
  let rows: [[String]]

  private var columnCount: Int { rows.map(\.count).max() ?? 0 }

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
        GridRow(alignment: .firstTextBaseline) {
          ForEach(0..<columnCount, id: \.self) { column in
            SelectableChatText(text: column < row.count ? row[column] : "", markdown: true, bold: index == 0)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
  }
}

struct ChatMarkdownText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .prose(let prose):
          SelectableChatText(text: prose, markdown: true)
        case .code(let code):
          SelectableChatText(text: code, monospaced: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .table(let rows):
          ChatMarkdownTable(rows: rows)
        }
      }
    }
  }

  enum Segment: Equatable {
    case prose(String)
    case code(String)
    /// First row is the header.
    case table([[String]])
  }

  static func segments(of text: String) -> [Segment] {
    var segments: [Segment] = []
    var prose: [String] = []
    var code: [String]?
    var tableLines: [String] = []
    func flushProse() {
      let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { segments.append(.prose(joined)) }
      prose = []
    }
    // A run of "|" lines is a table only when its second line is the |---| divider.
    func flushTable() {
      defer { tableLines = [] }
      guard tableLines.count >= 2, isTableDivider(tableLines[1]) else {
        prose.append(contentsOf: tableLines)
        return
      }
      flushProse()
      let rows = tableLines.enumerated().filter { $0.offset != 1 }.map { tableCells($0.element) }
      segments.append(.table(rows))
    }
    for line in text.components(separatedBy: "\n") {
      if code == nil, line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
        tableLines.append(line)
        continue
      }
      flushTable()
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let lines = code {
          segments.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          flushProse()
          code = []
        }
      } else if code != nil {
        code?.append(line)
      } else {
        prose.append(line)
      }
    }
    flushTable()
    if let lines = code { segments.append(.code(lines.joined(separator: "\n"))) }
    flushProse()
    return segments
  }

  static func tableCells(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    // ponytail: escaped pipes (\|) inside a cell still split; handle if agents use them.
    return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  static func isTableDivider(_ line: String) -> Bool {
    let cells = tableCells(line)
    return !cells.isEmpty
      && cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") }
  }

  /// Inline markdown with line breaks preserved; headings shown as bold lines.
  static func inline(_ prose: String) -> AttributedString {
    let normalized = prose.components(separatedBy: "\n").map { line -> String in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { return line }
      let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      return title.isEmpty ? line : "**\(title)**"
    }.joined(separator: "\n")
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(prose)
  }
}
