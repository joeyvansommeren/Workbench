import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Approval response tracker")
struct ApprovalResponseTrackerTests {
  private let request = ApprovalRequestKey(toolUseId: "toolu_1", timestamp: nil)

  // MARK: Request key

  @Test("A real tool use id identifies the request; a missing one adds the timestamp")
  func requestKey() {
    let first = Date(timeIntervalSince1970: 100)
    let second = Date(timeIntervalSince1970: 200)
    let real = ApprovalRequestKey(pending: PendingToolUse(toolName: "Bash", toolUseId: "toolu_1", timestamp: first))
    let realLater = ApprovalRequestKey(pending: PendingToolUse(toolName: "Bash", toolUseId: "toolu_1", timestamp: second))
    #expect(real == realLater)  // JSONL and hook timestamps differ for one call

    for id in ["", "hook-s1"] {
      let a = ApprovalRequestKey(pending: PendingToolUse(toolName: "Bash", toolUseId: id, timestamp: first))
      let b = ApprovalRequestKey(pending: PendingToolUse(toolName: "Bash", toolUseId: id, timestamp: second))
      #expect(a != b)
    }
    #expect(ApprovalRequestKey(state: nil) == nil)
  }

  // MARK: Phases

  @Test("Sent: the request counts as answered at once and the phase is tied to it")
  func sentIsAnswered() {
    let tracker = ApprovalResponseTracker(timeout: .seconds(60))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))

    let next = ApprovalRequestKey(toolUseId: "toolu_2", timestamp: nil)
    #expect(tracker.phase(for: "s1", request: next) == nil)
    #expect(!tracker.hasAnswered(sessionId: "s1", request: next))
    #expect(tracker.phase(for: "s1", request: nil) == nil)
    #expect(tracker.phase(for: "other", request: request) == nil)
  }

  @Test("Screen text: the menu going away settles as answered, not a terminal hint")
  func menuGoneSettlesAnswered() async throws {
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(500), pollInterval: .milliseconds(10))
    var menuVisible = true
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { menuVisible }
    try await Task.sleep(for: .milliseconds(40))
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))

    menuVisible = false
    try await waitFor { tracker.phase(for: "s1", request: request) == .answered(.approveOnce) }
    // A long-running approved tool keeps the request pending: still answered.
    try await Task.sleep(for: .milliseconds(600))
    #expect(tracker.phase(for: "s1", request: request) == .answered(.approveOnce))
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("No screen text: the timeout shows 'check the terminal', never the buttons again")
  func noScreenTimesOutToCheckTerminal() async throws {
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(30), pollInterval: .milliseconds(10))
    tracker.record(.sent, decision: .deny, sessionId: "s1", request: request) { nil }
    try await waitFor { tracker.phase(for: "s1", request: request) == .checkTerminal }
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("Menu still up at the timeout: check the terminal, still answered")
  func menuStillUpTimesOutToCheckTerminal() async throws {
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(30), pollInterval: .milliseconds(10))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    try await waitFor { tracker.phase(for: "s1", request: request) == .checkTerminal }
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("A refusal points to the terminal and allows a retry")
  func refusal() {
    let tracker = ApprovalResponseTracker()
    tracker.record(.answerInTerminal(.menuNotVisible), decision: .approveOnce, sessionId: "s1", request: request)
    #expect(tracker.phase(for: "s1", request: request) == .answerInTerminal)
    #expect(!tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("An already-answered refusal keeps the phase of the answer that went out")
  func alreadyAnsweredKeepsPhase() {
    let tracker = ApprovalResponseTracker(timeout: .seconds(60))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    tracker.record(.answerInTerminal(.alreadyAnswered), decision: .deny, sessionId: "s1", request: request)
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))
  }

  @Test("A newer click cancels the older click's timeout")
  func newerClickWins() async throws {
    let first = ApprovalResponseTracker(timeout: .milliseconds(30), pollInterval: .milliseconds(10))
    // Two clicks on two requests in a row; the first one's watcher must not
    // settle the second.
    let older = ApprovalRequestKey(toolUseId: "toolu_0", timestamp: nil)
    first.record(.sent, decision: .approveOnce, sessionId: "s1", request: older) { true }
    first.record(.answerInTerminal(.menuNotVisible), decision: .approveOnce, sessionId: "s1", request: request)
    try await Task.sleep(for: .milliseconds(80))
    #expect(first.phase(for: "s1", request: request) == .answerInTerminal)

    // Same request recorded twice: the first watcher's deadline passes while
    // the second is still in flight, and must not flip it.
    let tracker = ApprovalResponseTracker(timeout: .milliseconds(150), pollInterval: .milliseconds(10))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    try await Task.sleep(for: .milliseconds(100))
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    try await Task.sleep(for: .milliseconds(100))  // past the first deadline (150 ms)
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))
    try await waitFor { tracker.phase(for: "s1", request: request) == .checkTerminal }
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<150 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }
}
