//
//  ChatRuntimeState.swift
//  AgentHub
//
//  Pure, testable pieces of the chat that are not messages: how transcript
//  runtime facts are worded, what this card sent that the transcript has not
//  confirmed yet, what Arrow Up recalls, and what the live terminal screen says.
//

import Foundation

// MARK: - ChatRuntimeText

/// Wording for runtime facts. Each line says only what the evidence supports.
enum ChatRuntimeText {
  /// "1 background task started, no completion seen yet · abc123" or nil.
  static func backgroundTaskLine(_ tasks: [ChatTranscriptRuntime.BackgroundTask]) -> String? {
    guard !tasks.isEmpty else { return nil }
    let noun = tasks.count == 1 ? "background task" : "background tasks"
    let ids = tasks.map(\.id).joined(separator: ", ")
    return "\(tasks.count) \(noun) started, no completion seen yet · \(ids)"
  }

  /// "Context compacted · 468K tokens before · 2m 8s" for the inline divider.
  static func compactionLine(preTokens: Int?, durationMs: Int?) -> String {
    var parts = ["Context compacted"]
    if let preTokens { parts.append("\(SessionMonitorState.formatTokenCount(preTokens)) tokens before") }
    if let durationMs {
      let seconds = max(0, durationMs / 1000)
      parts.append(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")
    }
    return parts.joined(separator: " · ")
  }
}

// MARK: - ChatOutbox

/// What this card handed to its terminal that no evidence has confirmed yet.
/// A successful submit only means the bytes reached the terminal. Evidence is
/// either a queue record or a user message that is new since the send. Lives
/// in the card's own state, so it is per session and cleared on switch.
struct ChatOutbox: Equatable {
  struct Entry: Equatable, Identifiable {
    let id: UUID
    let text: String
    let sentAt: Date
    /// User-message ids on screen when the send happened; none of them can confirm it.
    var knownUserItemIDs: Set<String>
    var knownQueueIDs: Set<String>
  }

  struct LastSubmission: Equatable {
    let text: String
    let at: Date
  }

  static let cap = 10
  /// Evidence may carry a timestamp slightly before our clock stamped the send.
  static let clockSlack: TimeInterval = 10

  private(set) var entries: [Entry] = []
  /// The last text that reached the terminal, for Arrow Up.
  private(set) var lastSubmission: LastSubmission?

  mutating func record(_ text: String, items: [ChatTranscriptItem], runtime: ChatTranscriptRuntime = ChatTranscriptRuntime(), at date: Date = Date()) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    lastSubmission = LastSubmission(text: trimmed, at: date)
    let known = Set(items.compactMap { item -> String? in
      if case .user = item.kind { return item.id }
      return nil
    })
    entries.append(Entry(id: UUID(), text: trimmed, sentAt: date, knownUserItemIDs: known, knownQueueIDs: Set(runtime.visibleQueue.map(\.id))))
    if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
  }

  /// A queue receipt hides the local echo; only a new user message confirms delivery.
  /// Keeping these stages separate prevents one queued send and its later message
  /// from acknowledging two identical submissions.
  func entriesAwaitingConfirmation(runtime: ChatTranscriptRuntime) -> [Entry] {
    var usedQueueIDs: Set<String> = []
    return entries.filter { entry in
      let notBefore = entry.sentAt.addingTimeInterval(-Self.clockSlack)
      guard let queued = runtime.visibleQueue.first(where: {
        !usedQueueIDs.contains($0.id) && !entry.knownQueueIDs.contains($0.id)
          && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == entry.text
          && ($0.enqueuedAt.map { $0 >= notBefore } ?? true)
      }) else { return true }
      usedQueueIDs.insert(queued.id)
      return false
    }
  }

  mutating func reconcile(items: [ChatTranscriptItem], runtime: ChatTranscriptRuntime) {
    var usedItemIDs: Set<String> = []
    entries.removeAll { entry in
      let notBefore = entry.sentAt.addingTimeInterval(-Self.clockSlack)
      guard let item = items.first(where: { item in
        guard case .user(let text) = item.kind, !usedItemIDs.contains(item.id),
          !entry.knownUserItemIDs.contains(item.id)
        else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == entry.text
          && (item.timestamp.map { $0 >= notBefore } ?? true)
      }) else { return false }
      usedItemIDs.insert(item.id)
      return true
    }
    for index in entries.indices {
      entries[index].knownUserItemIDs.formUnion(usedItemIDs)
    }
  }

  mutating func dismiss(_ id: UUID) {
    entries.removeAll { $0.id == id }
  }

  /// Everything, including the recall memory: the card moved to another session.
  mutating func clear() {
    entries = []
    lastSubmission = nil
  }
}

// MARK: - ChatComposerHistory

/// Arrow Up in an empty composer brings back the previous message for editing.
enum ChatComposerHistory {
  /// Nil when there is a draft (ordinary cursor movement) or nothing to recall.
  /// The last local send wins unless the transcript has a newer user message
  /// (typed in the terminal, for instance). Assistant and tool lines never count.
  static func recall(
    draft: String, lastSubmitted: ChatOutbox.LastSubmission?, items: [ChatTranscriptItem]
  ) -> String? {
    guard draft.isEmpty else { return nil }
    let latestUser = items.last { item in
      if case .user(let text) = item.kind { return !text.isEmpty }
      return false
    }
    guard let lastSubmitted, !lastSubmitted.text.isEmpty else {
      if case .user(let text)? = latestUser?.kind { return text }
      return nil
    }
    if let latestUser, case .user(let text) = latestUser.kind,
      let at = latestUser.timestamp, at > lastSubmitted.at, text != lastSubmitted.text
    {
      return text
    }
    return lastSubmitted.text
  }
}

/// Whether an Arrow Up key press is a recall request at all.
enum ChatRecallKeyPolicy {
  /// Only a plain Up in an empty field with no IME composition in progress.
  /// Shift/Option/Command Up, text in the field, or marked text keep the key's
  /// ordinary meaning.
  static func shouldRecall(draftIsEmpty: Bool, hasModifiers: Bool, hasMarkedText: Bool) -> Bool {
    draftIsEmpty && !hasModifiers && !hasMarkedText
  }
}

// MARK: - TerminalLiveStatusDetector

/// Reads the agent tab's last screen rows for state the transcript never
/// records while it happens. Only the line that names it is used, verbatim.
enum TerminalLiveStatusDetector {
  static func status(in lines: [String]) -> String? {
    queuedQuestions(in: lines) ?? compacting(in: lines)
  }

  static func queuedQuestions(in lines: [String]) -> String? {
    let clean = lines.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "●• "))
    }
    guard let heading = clean.lastIndex(of: "Queued follow-up inputs") else { return nil }
    let footer = clean.dropFirst(heading + 1).prefix(3)
    guard footer.contains(where: { $0.contains("to answer") }),
      let countLine = footer.first(where: {
        $0.range(of: #"^\?\s+[1-9][0-9]*\s+questions?$"#, options: .regularExpression) != nil
      })
    else { return nil }
    return "Awaiting your answer · " + countLine.dropFirst().trimmingCharacters(in: .whitespaces)
      + " · Shift+Return in Terminal to answer"
  }

  /// The "Compacting context …" line as the CLI draws it, or nil.
  static func compacting(in lines: [String]) -> String? {
    for line in lines.reversed() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "●•✻✽✶✢✳⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ "))
      guard prefix.lowercased().hasPrefix("compacting context"),
        let range = trimmed.range(of: "Compacting context", options: .caseInsensitive)
      else { continue }
      let text = String(trimmed[range.lowerBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
      return text.count > 90 ? String(text.prefix(89)) + "…" : text
    }
    return nil
  }
}
