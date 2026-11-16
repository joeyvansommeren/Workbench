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
  /// Lasting permission is reviewed in the terminal until its full scope is verified.
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
  /// "Always allow"), or the tab is scrolled back so the live rows can't be read.
  case menuNotVisible
  /// The backend can't read text and the sidecar has no open `pending` line
  /// for this tool use.
  case noOpenSidecarRequest
  /// The app already answered this request. While an approved tool runs, the
  /// request still looks pending; a second key would land in a running turn.
  case alreadyAnswered
  /// The provider has not supplied a verified target, lifetime and revocation path.
  case permissionScopeUnconfirmed
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

  /// The provider's exact offered scope, including wrapped lines. This is
  /// disclosure text only: seeing option 2 does not prove its persistence or
  /// revocation rules. It must never authorize an in-app persistent grant.
  public static func persistentOption(in rows: [String]) -> String? {
    let lines = rows.map(stripDecoration)
    guard isVisible(in: rows, requiresAllowAlways: true),
      let question = lines.lastIndex(where: { $0.contains(questionMarker) }),
      let option = lines.indices.first(where: {
        $0 > question && lines[$0].hasPrefix(allowAlwaysMarker)
      })
    else { return nil }
    var text = [lines[option]]
    for line in lines.dropFirst(option + 1) {
      if line.range(of: #"^\d+\."#, options: .regularExpression) != nil { break }
      guard !line.isEmpty else { break }
      text.append(line)
    }
    return text.joined(separator: "\n")
  }

  /// Drops box borders, the selection caret and padding: "│ ❯ 1. Yes │" → "1. Yes".
  private static func stripDecoration(_ row: String) -> String {
    let decoration = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "│┃|❯›>▶╭╮╰╯─"))
    return row.trimmingCharacters(in: decoration)
  }
}

/// Provider text defines the target verbatim. Only recognized choices get
/// lifetime/storage facts; unknown or future choices must not inherit them.
/// Provider contract: https://code.claude.com/docs/en/permissions
public struct ClaudePermissionScopeDisclosure: Equatable, Sendable {
  public let providerOption: String?
  public let duration: String
  public let storage: String
  public let revocation: String
  public let isRecognized: Bool

  public init(toolName: String, providerOption: String?) {
    self.providerOption = providerOption
    let normalized =
      providerOption?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
    let isSessionEdit =
      ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(toolName)
      && [
        "2. Yes, allow all edits during this session (shift+tab)",
        "2. Yes, allow all edits during this session",
      ].contains(normalized)
    let savedRulePrefixes = [
      "2. Yes, and don't ask again for ",
      "2. Yes, and don’t ask again for ",
      "2. Yes, and don't ask again for: ",
      "2. Yes, and don’t ask again for: ",
    ]
    let isSavedRule =
      ["Bash", "WebFetch", "WebSearch"].contains(toolName)
      && savedRulePrefixes.contains { prefix in
        normalized.hasPrefix(prefix)
          && !normalized.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).isEmpty
      }

    isRecognized = isSessionEdit || isSavedRule
    if isSessionEdit {
      duration = "Until this session ends or you change permission mode"
      storage = "Session only; not saved to a settings file"
      revocation = "In Claude's terminal, use Shift+Tab to switch to Manual mode (default)."
    } else if isSavedRule {
      duration = "Until you remove the saved rule; includes future sessions"
      storage =
        "Claude's local settings (.claude/settings.local.json). Exact location not confirmed."
      revocation = "In Claude's terminal, open /permissions and remove the matching Allow rule."
    } else {
      duration = "Not confirmed"
      storage = "Not confirmed"
      revocation = "Not confirmed. Check Claude's permission controls in the terminal."
    }
  }
}

// MARK: - Sidecar

/// The tool use id of the hook sidecar's open permission request: the proof
/// the menu is up when the backend can't read the screen (Ghostty).
@MainActor
public protocol ApprovalSidecarReading {
  func openRequestToolUseId(sessionId: String) -> String?
}

public enum ApprovalSidecarState {
  /// The tool use id of the last `pending` line when no `resolved` / `denied`
  /// line follows it, else nil. `observed` lines are tool/mode bookkeeping and
  /// do not close a request. A missing id maps to `hook-<sessionId>`, as in
  /// `ClaudeHookSidecarWatcher`, so it compares with `PendingToolUse.toolUseId`.
  public static func openRequestToolUseId(lines: [Substring], sessionId: String) -> String? {
    for line in lines.reversed() {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let event = object["event"] as? String
      else { continue }
      switch event {
      case "pending": return object["toolUseId"] as? String ?? "hook-\(sessionId)"
      case "resolved", "denied": return nil
      default: continue
      }
    }
    return nil
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

  public func openRequestToolUseId(sessionId: String) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL(sessionId)) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let start = size > maxBytes ? size - maxBytes : 0
    guard (try? handle.seek(toOffset: start)) != nil,
      let data = try? handle.readToEnd(),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    // A cut first line is never valid JSON; dropping it avoids a misparse.
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return ApprovalSidecarState.openRequestToolUseId(lines: lines, sessionId: sessionId)
  }
}

// MARK: - Terminal

/// What the responder needs from a terminal, all aimed at the agent's own tab
/// (never an accessory or child tab).
@MainActor
public protocol ApprovalKeystrokeTarget {
  /// True when the backend can read screen text at all (SwiftTerm). On such a
  /// backend a nil tail means "not right now" (scrolled back) and the answer
  /// is refused; it never falls back to the weaker sidecar check.
  var canReadScreen: Bool { get }
  /// The live bottom rows, or nil when they can't be read.
  func agentScreenTail(maxRows: Int) -> [String]?
  func typeTextToAgentSession(_ text: String) -> Bool
  func sendEscapeToAgentSession() -> Bool
}

/// Adapts any embedded terminal surface.
@MainActor
struct SurfaceApprovalKeystrokeTarget: ApprovalKeystrokeTarget {
  let surface: any EmbeddedTerminalSurface

  var canReadScreen: Bool { surface.canReadAgentScreen }
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

/// Stateless. "This request was already answered" is checked by the view model
/// (`ApprovalResponseTracker.hasAnswered`) before it calls this.
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
    guard let pending = request.pendingToolUse else { return .answerInTerminal(.nothingPending) }
    guard pending.isApprovablePermission(providerKind: request.providerKind) else {
      return .answerInTerminal(request.providerKind == .claude ? .interactiveInput : .unsupportedProvider)
    }
    guard let terminal else { return .answerInTerminal(.terminalUnavailable) }
    // A readable option is insufficient evidence of lifetime and revocation.
    // Until the provider exposes those facts, the user must review and choose
    // lasting permissions in its own terminal. Never send a guessed "2".
    guard decision != .approveAlways else { return .answerInTerminal(.permissionScopeUnconfirmed) }

    // Escape outside the menu interrupts Claude's turn and a stray "1" lands in
    // the prompt, so deny is gated exactly like approve.
    if terminal.canReadScreen {
      guard let tail = terminal.agentScreenTail(maxRows: ClaudePermissionMenu.tailRows),
        ClaudePermissionMenu.isVisible(in: tail)
      else { return .answerInTerminal(.menuNotVisible) }
    } else {
      guard sidecar.openRequestToolUseId(sessionId: request.sessionId) == pending.toolUseId else {
        return .answerInTerminal(.noOpenSidecarRequest)
      }
    }

    let delivered: Bool
    switch decision {
    case .approveOnce: delivered = terminal.typeTextToAgentSession("1")
    case .approveAlways: return .answerInTerminal(.permissionScopeUnconfirmed)
    case .deny: delivered = terminal.sendEscapeToAgentSession()
    }
    return delivered ? .sent : .answerInTerminal(.terminalUnavailable)
  }
}
