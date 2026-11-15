//
//  ApprovalResponseTracker.swift
//  AgentHub
//
//  What the banner and the tree pill show after a click, and the record that
//  a request was already answered. A keystroke has no reply, and an approved
//  tool still looks pending until it finishes (the hook writes `resolved` on
//  PostToolUse), so neither "the state changed" nor "3 s passed" means the
//  menu is still waiting. Once the app has sent a key for a request it never
//  sends another for that request.
//

import Foundation
import Observation

/// One permission request. Claude's tool use ids are unique; when the hook
/// had none (empty, or the watcher's `hook-<sid>` fallback) the pending
/// timestamp tells two requests apart.
public struct ApprovalRequestKey: Hashable, Sendable {
  public let toolUseId: String
  public let timestamp: Date?

  public init(toolUseId: String, timestamp: Date?) {
    self.toolUseId = toolUseId
    self.timestamp = timestamp
  }

  public init(pending: PendingToolUse) {
    let hasRealId = !pending.toolUseId.isEmpty && !pending.toolUseId.hasPrefix("hook-")
    self.init(toolUseId: pending.toolUseId, timestamp: hasRealId ? nil : pending.timestamp)
  }

  public init?(state: SessionMonitorState?) {
    guard let pending = state?.pendingToolUse else { return nil }
    self.init(pending: pending)
  }
}

public enum ApprovalResponsePhase: Equatable, Sendable {
  /// A key went to the terminal; waiting for Claude's menu to go away.
  case sending(ApprovalDecision)
  /// The menu went away: Claude took the answer. Lasts until the request ends
  /// (an approved tool may run for a long time).
  case answered(ApprovalDecision)
  /// A key was sent but the app can't confirm it landed (no screen text, or
  /// the menu was still up at the timeout). No buttons: check the terminal.
  case checkTerminal
  /// Nothing was sent: the app could not confirm the menu. Answer there, or retry.
  case answerInTerminal

  /// True once a key went out for the request: no further key may follow.
  public var isAnswered: Bool {
    switch self {
    case .sending, .answered, .checkTerminal: true
    case .answerInTerminal: false
    }
  }
}

@MainActor
@Observable
public final class ApprovalResponseTracker {
  private struct Entry {
    let phase: ApprovalResponsePhase
    let request: ApprovalRequestKey
    let token: UUID
  }

  private var entries: [String: Entry] = [:]
  @ObservationIgnored private var watchTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private let timeout: Duration
  @ObservationIgnored private let pollInterval: Duration

  public static let defaultTimeout: Duration = .seconds(3)

  public init(
    timeout: Duration = ApprovalResponseTracker.defaultTimeout,
    pollInterval: Duration = .milliseconds(200)
  ) {
    self.timeout = timeout
    self.pollInterval = pollInterval
  }

  /// The phase for the request the session shows now. Nil when there was no
  /// click on this request (or it ended and a new one is pending).
  public func phase(for sessionId: String, request: ApprovalRequestKey?) -> ApprovalResponsePhase? {
    guard let request, let entry = entries[sessionId], entry.request == request else { return nil }
    return entry.phase
  }

  /// Whether the app already sent a key for this request.
  public func hasAnswered(sessionId: String, request: ApprovalRequestKey) -> Bool {
    phase(for: sessionId, request: request)?.isAnswered ?? false
  }

  /// Records a click on `request`. After `.sent`, `menuStillVisible` is polled
  /// until the timeout: false (menu gone) → `.answered`; true or nil (can't
  /// read the screen) at the timeout → `.checkTerminal`.
  public func record(
    _ outcome: ApprovalResponseOutcome,
    decision: ApprovalDecision,
    sessionId: String,
    request: ApprovalRequestKey,
    menuStillVisible: @escaping @MainActor () -> Bool? = { nil }
  ) {
    watchTasks.removeValue(forKey: sessionId)?.cancel()
    let token = UUID()
    switch outcome {
    case .sent:
      entries[sessionId] = Entry(phase: .sending(decision), request: request, token: token)
      watchTasks[sessionId] = Task { [weak self, timeout, pollInterval] in
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
          try? await Task.sleep(for: pollInterval)
          guard !Task.isCancelled else { return }
          if menuStillVisible() == false {
            self?.settle(sessionId: sessionId, token: token, phase: .answered(decision))
            return
          }
        }
        guard !Task.isCancelled else { return }
        self?.settle(sessionId: sessionId, token: token, phase: .checkTerminal)
      }
    case .answerInTerminal(.alreadyAnswered):
      // Keep the phase of the answer that went out.
      return
    case .answerInTerminal:
      entries[sessionId] = Entry(phase: .answerInTerminal, request: request, token: token)
    }
  }

  private func settle(sessionId: String, token: UUID, phase: ApprovalResponsePhase) {
    watchTasks.removeValue(forKey: sessionId)
    guard let entry = entries[sessionId], entry.token == token else { return }
    entries[sessionId] = Entry(phase: phase, request: entry.request, token: token)
  }
}
