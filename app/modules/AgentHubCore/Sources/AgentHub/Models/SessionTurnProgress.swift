import Foundation

/// Turn evidence from provider records. A returned response is independent of
/// product acceptance, code changes and checks.
public struct SessionTurnProgress: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case unknown
    case working
    case responded
    case finishedWithoutResponse
    case interrupted
  }

  public private(set) var phase: Phase = .unknown
  public private(set) var startedAt: Date?
  public private(set) var lastCompletedAt: Date?

  public init() {}

  mutating func begin(at timestamp: Date?) {
    phase = .working
    startedAt = timestamp
  }

  mutating func complete(at timestamp: Date?, hasResponse: Bool) {
    phase = hasResponse ? .responded : .finishedWithoutResponse
    if let timestamp { lastCompletedAt = timestamp }
  }

  mutating func interrupt() {
    phase = .interrupted
  }

  var ended: Bool {
    phase == .responded || phase == .finishedWithoutResponse || phase == .interrupted
  }
}

extension SessionJSONLParser.ParseResult {
  /// A delayed response cannot advance the newer turn's state.
  func isObsoleteClaudeTurnEnd(_ entry: SessionJSONLParser.SessionEntry, at timestamp: Date?) -> Bool {
    guard entry.type == "assistant", entry.message?.stopReason == "end_turn",
      let timestamp, let startedAt = turnProgress.startedAt else { return false }
    return timestamp < startedAt
  }

  mutating func recordClaudeInput(_ text: String, at timestamp: Date?) {
    pendingToolUses.removeAll()
    if text == "[Request interrupted by user]" {
      turnProgress.interrupt()
    } else {
      turnProgress.begin(at: timestamp)
    }
  }

  mutating func recordClaudeStop(_ reason: String?, at timestamp: Date?, hasResponse: Bool) {
    guard reason == "end_turn" else { return }
    pendingToolUses.removeAll()
    turnProgress.complete(at: timestamp, hasResponse: hasResponse)
  }
}
