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
    let clock = ManualTaskClock()
    defer { clock.close() }
    let tracker = makeTracker(timeout: .milliseconds(500), clock: clock)
    let polls = TestCallbackReceipt()
    var menuVisible = true
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) {
      polls.record()
      return menuVisible
    }
    let firstPoll = try await clock.nextSleep(for: .milliseconds(10))
    clock.advance(by: .milliseconds(40))
    _ = try await clock.nextSleep(for: .milliseconds(10), after: firstPoll.id)
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))

    menuVisible = false
    clock.advance(by: .milliseconds(10))
    try await polls.wait(for: 2)
    #expect(tracker.phase(for: "s1", request: request) == .answered(.approveOnce))
    // A long-running approved tool keeps the request pending: still answered.
    clock.advance(by: .milliseconds(600))
    #expect(tracker.phase(for: "s1", request: request) == .answered(.approveOnce))
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("No screen text: the timeout shows 'check the terminal', never the buttons again")
  func noScreenTimesOutToCheckTerminal() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    let tracker = makeTracker(timeout: .milliseconds(30), clock: clock)
    let polls = TestCallbackReceipt()
    tracker.record(.sent, decision: .deny, sessionId: "s1", request: request) {
      polls.record()
      return nil
    }
    _ = try await clock.nextSleep(for: .milliseconds(10))
    clock.advance(by: .milliseconds(30))
    try await polls.wait()
    #expect(tracker.phase(for: "s1", request: request) == .checkTerminal)
    #expect(tracker.hasAnswered(sessionId: "s1", request: request))
  }

  @Test("Menu still up at the timeout: check the terminal, still answered")
  func menuStillUpTimesOutToCheckTerminal() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    let tracker = makeTracker(timeout: .milliseconds(30), clock: clock)
    let polls = TestCallbackReceipt()
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) {
      polls.record()
      return true
    }
    _ = try await clock.nextSleep(for: .milliseconds(10))
    clock.advance(by: .milliseconds(30))
    try await polls.wait()
    #expect(tracker.phase(for: "s1", request: request) == .checkTerminal)
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
    let firstClock = ManualTaskClock()
    defer { firstClock.close() }
    let first = makeTracker(timeout: .milliseconds(30), clock: firstClock)
    // Two clicks on two requests in a row; the first watcher must not settle the second.
    let older = ApprovalRequestKey(toolUseId: "toolu_0", timestamp: nil)
    first.record(.sent, decision: .approveOnce, sessionId: "s1", request: older) { true }
    let olderPoll = try await firstClock.nextSleep(for: .milliseconds(10))
    first.record(.answerInTerminal(.menuNotVisible), decision: .approveOnce, sessionId: "s1", request: request)
    firstClock.advance(by: .milliseconds(80))
    try await firstClock.waitForCompletion(of: olderPoll)
    #expect(first.phase(for: "s1", request: request) == .answerInTerminal)

    // The old deadline passes while the second click is still in flight.
    let clock = ManualTaskClock()
    defer { clock.close() }
    let tracker = makeTracker(timeout: .milliseconds(150), clock: clock)
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) { true }
    let initialPoll = try await clock.nextSleep(for: .milliseconds(10))
    clock.advance(by: .milliseconds(100))
    let olderPendingPoll = try await clock.nextSleep(for: .milliseconds(10), after: initialPoll.id)
    let newerPolls = TestCallbackReceipt()
    tracker.record(.sent, decision: .approveOnce, sessionId: "s1", request: request) {
      newerPolls.record()
      return true
    }
    let newerPendingPoll = try await clock.nextSleep(for: .milliseconds(10), after: olderPendingPoll.id)
    clock.advance(by: .milliseconds(100))
    _ = try await clock.nextSleep(for: .milliseconds(10), after: newerPendingPoll.id)
    #expect(tracker.phase(for: "s1", request: request) == .sending(.approveOnce))
    clock.advance(by: .milliseconds(60))
    try await newerPolls.wait(for: 2)
    #expect(tracker.phase(for: "s1", request: request) == .checkTerminal)
  }

  private func makeTracker(timeout: Duration, clock: ManualTaskClock) -> ApprovalResponseTracker {
    ApprovalResponseTracker(
      timeout: timeout,
      pollInterval: .milliseconds(10),
      now: { clock.now },
      sleep: { try await clock.sleep(for: $0) }
    )
  }
}
