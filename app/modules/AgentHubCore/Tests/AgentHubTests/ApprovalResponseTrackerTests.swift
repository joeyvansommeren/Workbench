import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Approval response tracker")
struct ApprovalResponseTrackerTests {
  private let signature = ApprovalSignature(toolUseId: "t1", lastActivityAt: Date(timeIntervalSince1970: 100))

  @Test("A sent answer shows progress until the session state moves on")
  func progressUntilStateChanges() {
    let tracker = ApprovalResponseTracker(timeout: .seconds(60))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", signature: signature)
    #expect(tracker.phase(for: "s1", current: signature) == .sending(.approveOnce))

    // Sidecar resolved (no pending) or JSONL moved on: progress ends.
    #expect(tracker.phase(for: "s1", current: ApprovalSignature(toolUseId: nil, lastActivityAt: signature.lastActivityAt)) == nil)
    #expect(tracker.phase(for: "s1", current: ApprovalSignature(toolUseId: "t1", lastActivityAt: Date())) == nil)
    #expect(tracker.phase(for: "other", current: signature) == nil)
  }

  @Test("With no change before the timeout, it points to the terminal")
  func timeoutPointsToTerminal() async throws {
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(30))
    tracker.record(.sent, decision: .deny, sessionId: "s1", signature: signature)
    for _ in 0..<100 where tracker.phase(for: "s1", current: signature) != .answerInTerminal {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(tracker.phase(for: "s1", current: signature) == .answerInTerminal)
  }

  @Test("A refusal points to the terminal at once")
  func refusal() {
    let tracker = ApprovalResponseTracker()
    tracker.record(.answerInTerminal(.menuNotVisible), decision: .approveOnce, sessionId: "s1", signature: signature)
    #expect(tracker.phase(for: "s1", current: signature) == .answerInTerminal)
  }

  @Test("A newer click replaces the older one and its timeout")
  func newerClickWins() async throws {
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(30))
    tracker.record(.answerInTerminal(.menuNotVisible), decision: .approveOnce, sessionId: "s1", signature: signature)
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", signature: signature)
    #expect(tracker.phase(for: "s1", current: signature) == .sending(.approveOnce))
  }
}
