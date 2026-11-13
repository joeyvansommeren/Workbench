//
//  ApprovalResponder.swift
//  AgentHub
//
//  Answers a pending Claude permission prompt from the app. There is no
//  programmatic channel (the hook only observes), so the answer is a keystroke
//  into the session's own agent tab. It fails closed: when the app cannot
//  confirm that Claude's permission menu is the thing waiting for a key, it
//  sends nothing and the user answers in the terminal.
//

import Foundation

// MARK: - Decision and outcome

public enum ApprovalDecision: String, Equatable, Sendable {
  /// "1. Yes": allow this one call.
  case approveOnce
  /// "2. Yes, and don't ask again…": only sent when the screen shows that option.
  case approveAlways
  /// Escape: "No, and tell Claude what to do differently". The option number
  /// for "No" is not stable across tools, Escape is.
  case deny

  public var isApproval: Bool { self != .deny }

  /// The breadcrumb verb (`approval: approve|deny <tool>`).
  var breadcrumbVerb: String { isApproval ? "approve" : "deny" }
}

public enum ApprovalRefusal: Equatable, Sendable {
  /// Only Claude has a readable permission prompt.
  case unsupportedProvider
  case nothingPending
  /// AskUserQuestion and friends: a question, not a permission menu.
  case interactiveInput
  /// The agent tab is not mounted, or the backend has no agent tab to type into.
  case terminalUnavailable
  /// The screen tail does not show Claude's permission menu (or option 2 for
  /// "Always allow").
  case menuNotVisible
  /// The backend can't read text and the sidecar has no open `pending` line.
  case noOpenSidecarRequest
}

public enum ApprovalResponseOutcome: Equatable, Sendable {
  case sent
  case answerInTerminal(ApprovalRefusal)
}

// MARK: - Claude's permission menu

/// Recognises Claude Code's permission menu in the agent tab's last rows.
/// The wording lives here and in `ClaudePermissionMenuFixtures` (tests); if
/// Claude Code rewords the menu, detection fails closed and the tests show it.
public enum ClaudePermissionMenu {
  static let questionMarker = "Do you want to"
  static let allowOnceMarker = "1. Yes"
  static let allowAlwaysMarker = "2. Yes"
  /// Enough rows for a long command block above the menu.
  public static let tailRows = 40

  /// True when the tail shows the question followed by the "1. Yes" option.
  /// With `requiresAllowAlways`, option 2 must also start with "Yes": some
  /// prompts only offer Yes / No, and "2" would then be No.
  public static func isVisible(in rows: [String], requiresAllowAlways: Bool = false) -> Bool {
    let lines = rows.map(stripDecoration)
    guard let question = lines.lastIndex(where: { $0.contains(questionMarker) }) else { return false }
    let options = lines[(question + 1)...]
    guard options.contains(where: { $0.hasPrefix(allowOnceMarker) }) else { return false }
    guard requiresAllowAlways else { return true }
    return options.contains(where: { $0.hasPrefix(allowAlwaysMarker) })
  }

  /// Drops box borders, the selection caret and padding: "│ ❯ 1. Yes │" → "1. Yes".
  private static func stripDecoration(_ row: String) -> String {
    let decoration = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|❯›>▶╭╮╰╯─"))
    return row.trimmingCharacters(in: decoration)
  }
}

// MARK: - Sidecar

/// Whether the hook sidecar still holds an open permission request. The proof
/// the menu is up when the backend can't read the screen (Ghostty).
@MainActor
public protocol ApprovalSidecarReading {
  func hasOpenRequest(sessionId: String) -> Bool
}

public enum ApprovalSidecarState {
  /// True when the last `pending` / `resolved` / `denied` line is `pending`.
  /// `observed` lines are tool/mode bookkeeping and do not close a request.
  public static func hasOpenRequest(lines: [Substring]) -> Bool {
    for line in lines.reversed() {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let event = object["event"] as? String
      else { continue }
      switch event {
      case "pending": return true
      case "resolved", "denied": return false
      default: continue
      }
    }
    return false
  }
}

/// Reads the tail of `approvals/{sessionId}.jsonl`. Bounded, so a long session's
/// sidecar costs the same as a short one.
public struct FileApprovalSidecarReader: ApprovalSidecarReading {
  private let fileURL: (String) -> URL
  private let maxBytes: UInt64

  public init(
    fileURL: @escaping (String) -> URL = ClaudeHookPaths.approvalsURL(for:),
    maxBytes: UInt64 = 32 * 1024
  ) {
    self.fileURL = fileURL
    self.maxBytes = maxBytes
  }

  public func hasOpenRequest(sessionId: String) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: fileURL(sessionId)) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return false }
    let start = size > maxBytes ? size - maxBytes : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let data = try? handle.readToEnd(),
      let text = String(data: data, encoding: .utf8)
    else { return false }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    // A cut first line is never valid JSON; dropping it avoids a misparse.
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return ApprovalSidecarState.hasOpenRequest(lines: lines)
  }
}

// MARK: - Terminal

/// The three things the responder needs from a terminal, all aimed at the
/// agent's own tab (never an accessory or child tab).
@MainActor
public protocol ApprovalKeystrokeTarget {
  /// Nil when the backend cannot read text.
  func agentScreenTail(maxRows: Int) -> [String]?
  func typeTextToAgentSession(_ text: String) -> Bool
  func sendEscapeToAgentSession() -> Bool
}

/// Adapts any embedded terminal surface.
@MainActor
struct SurfaceApprovalKeystrokeTarget: ApprovalKeystrokeTarget {
  let surface: any EmbeddedTerminalSurface

  func agentScreenTail(maxRows: Int) -> [String]? { surface.agentScreenTail(maxRows: maxRows) }
  func typeTextToAgentSession(_ text: String) -> Bool { surface.typeTextToAgentSession(text) }
  func sendEscapeToAgentSession() -> Bool { surface.sendEscapeToAgentSession() }
}

// MARK: - Responder

/// What the responder knows about the request.
public struct ApprovalRequestContext: Equatable, Sendable {
  public let sessionId: String
  public let providerKind: SessionProviderKind
  public let pendingToolUse: PendingToolUse?

  public init(sessionId: String, providerKind: SessionProviderKind, pendingToolUse: PendingToolUse?) {
    self.sessionId = sessionId
    self.providerKind = providerKind
    self.pendingToolUse = pendingToolUse
  }
}

@MainActor
public protocol ApprovalResponding {
  func respond(
    to request: ApprovalRequestContext,
    decision: ApprovalDecision,
    terminal: (any ApprovalKeystrokeTarget)?
  ) -> ApprovalResponseOutcome
}

@MainActor
public struct TerminalKeystrokeApprovalResponder: ApprovalResponding {
  private let sidecar: any ApprovalSidecarReading

  /// Nil reads the real sidecar directory.
  public init(sidecar: (any ApprovalSidecarReading)? = nil) {
    self.sidecar = sidecar ?? FileApprovalSidecarReader()
  }

  public func respond(
    to request: ApprovalRequestContext,
    decision: ApprovalDecision,
    terminal: (any ApprovalKeystrokeTarget)?
  ) -> ApprovalResponseOutcome {
    guard request.providerKind == .claude else { return .answerInTerminal(.unsupportedProvider) }
    guard let pending = request.pendingToolUse else { return .answerInTerminal(.nothingPending) }
    guard !SessionInteractiveInputTool.matches(pending.toolName) else {
      return .answerInTerminal(.interactiveInput)
    }
    guard let terminal else { return .answerInTerminal(.terminalUnavailable) }

    // Escape outside the menu interrupts Claude's turn and a stray "1" lands in
    // the prompt, so deny is gated exactly like approve.
    if let tail = terminal.agentScreenTail(maxRows: ClaudePermissionMenu.tailRows) {
      guard
        ClaudePermissionMenu.isVisible(in: tail, requiresAllowAlways: decision == .approveAlways)
      else { return .answerInTerminal(.menuNotVisible) }
    } else {
      // Without the screen there is no way to tell whether option 2 is "Yes".
      guard decision != .approveAlways else { return .answerInTerminal(.menuNotVisible) }
      guard sidecar.hasOpenRequest(sessionId: request.sessionId) else {
        return .answerInTerminal(.noOpenSidecarRequest)
      }
    }

    let delivered: Bool
    switch decision {
    case .approveOnce: delivered = terminal.typeTextToAgentSession("1")
    case .approveAlways: delivered = terminal.typeTextToAgentSession("2")
    case .deny: delivered = terminal.sendEscapeToAgentSession()
    }
    return delivered ? .sent : .answerInTerminal(.terminalUnavailable)
  }
}
