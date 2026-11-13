//
//  ApprovalResponseTracker.swift
//  AgentHub
//
//  What the banner and the tree pill show after a click. A keystroke has no
//  reply, so progress lasts until the session's state moves on (the next
//  sidecar or JSONL update changes the signature). If nothing moves within the
//  timeout, the UI restores and points to the terminal.
//

import Foundation
import Observation

/// Identifies one pending request at one moment. Any sidecar or JSONL update
/// that matters changes the tool use id or the last activity time.
public struct ApprovalSignature: Equatable, Sendable {
  public let toolUseId: String?
  public let lastActivityAt: Date?

  public init(toolUseId: String?, lastActivityAt: Date?) {
    self.toolUseId = toolUseId
    self.lastActivityAt = lastActivityAt
  }

  public init(state: SessionMonitorState?) {
    self.init(toolUseId: state?.pendingToolUse?.toolUseId, lastActivityAt: state?.lastActivityAt)
  }
}

public enum ApprovalResponsePhase: Equatable, Sendable {
  /// A key went to the terminal; waiting for the session to move on.
  case sending(ApprovalDecision)
  /// The app could not answer, or nothing changed in time.
  case answerInTerminal
}

@MainActor
@Observable
public final class ApprovalResponseTracker {
  private struct Entry {
    let phase: ApprovalResponsePhase
    let signature: ApprovalSignature
    let token: UUID
  }

  private var entries: [String: Entry] = [:]
  @ObservationIgnored private var timeoutTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private let timeout: Duration

  public static let defaultTimeout: Duration = .seconds(3)

  public init(timeout: Duration = ApprovalResponseTracker.defaultTimeout) {
    self.timeout = timeout
  }

  /// The phase for the request the session shows now, or nil once the state
  /// has moved past the request the user answered.
  public func phase(for sessionId: String, current: ApprovalSignature) -> ApprovalResponsePhase? {
    guard let entry = entries[sessionId], entry.signature == current else { return nil }
    return entry.phase
  }

  /// Records the outcome of a click on the request with `signature`.
  public func record(
    _ outcome: ApprovalResponseOutcome,
    decision: ApprovalDecision,
    sessionId: String,
    signature: ApprovalSignature
  ) {
    timeoutTasks.removeValue(forKey: sessionId)?.cancel()
    let token = UUID()
    switch outcome {
    case .sent:
      entries[sessionId] = Entry(phase: .sending(decision), signature: signature, token: token)
      let timeout = timeout
      timeoutTasks[sessionId] = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.expire(sessionId: sessionId, token: token)
      }
    case .answerInTerminal:
      entries[sessionId] = Entry(phase: .answerInTerminal, signature: signature, token: token)
    }
  }

  private func expire(sessionId: String, token: UUID) {
    timeoutTasks.removeValue(forKey: sessionId)
    guard let entry = entries[sessionId], entry.token == token else { return }
    entries[sessionId] = Entry(phase: .answerInTerminal, signature: entry.signature, token: token)
  }
}
