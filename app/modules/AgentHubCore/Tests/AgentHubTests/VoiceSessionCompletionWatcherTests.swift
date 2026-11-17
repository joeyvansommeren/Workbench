import Foundation
import Testing
@testable import AgentHubCore

@MainActor
private final class CompletionWatcherExecutor: VoiceAgentToolExecuting {
  private let stream: AsyncStream<SessionStatus>
  private let continuation: AsyncStream<SessionStatus>.Continuation
  var currentStatus: SessionStatus?
  var onStatusRead: ((String?) -> Void)?

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func yield(_ status: SessionStatus) {
    currentStatus = status
    continuation.yield(status)
  }

  func listSessions() -> VoiceSessionsSummary {
    .init(sessions: [], targetSessionId: nil)
  }

  func sessionStatus(
    sessionId: String,
    activityLimit: Int
  ) -> VoiceSessionStatusDetail? {
    let observedStatus = currentStatus
    defer { onStatusRead?(observedStatus?.displayName) }
    guard let currentStatus = observedStatus else { return nil }
    return .init(
      sessionId: sessionId,
      provider: .claude,
      name: "Test",
      status: currentStatus.displayName,
      currentTool: nil,
      contextUsagePercent: nil,
      pendingApproval: nil,
      recentActivities: []
    )
  }

  func sessionHistory(
    sessionId: String?,
    turnLimit: Int
  ) async -> VoiceSessionHistory? {
    nil
  }

  func sendPrompt(
    sessionId: String,
    prompt: String
  ) -> VoicePromptDeliveryResult {
    .init(status: "accepted", sessionId: sessionId, usedExistingTerminal: true)
  }

  func focusSession(sessionId: String) -> Bool {
    true
  }

  func launchSession(
    worktreePath: String,
    provider: SessionProviderKind,
    prompt: String?
  ) -> VoiceLaunchResult {
    .init(
      status: "accepted",
      provider: provider,
      worktreePath: worktreePath,
      pendingSessionId: nil
    )
  }

  func listWorktrees() -> VoiceWorktreeInventory {
    .init(repositories: [])
  }

  func createWorktreeTasks(
    repositoryPath: String?,
    tasks: [VoiceWorktreeTaskSpec]
  ) async -> VoiceWorktreeTaskBatchResult {
    .init(
      status: "accepted",
      message: nil,
      repositoryPath: repositoryPath ?? "",
      launched: [],
      failures: []
    )
  }

  func pendingApproval(sessionId: String) -> VoicePendingApproval? {
    nil
  }

  func respondToApproval(
    sessionId: String,
    approve: Bool
  ) -> VoiceApprovalResponseResult {
    .init(
      status: "accepted",
      sessionId: sessionId,
      decision: approve ? "approve" : "deny"
    )
  }

  func completionStream(sessionId: String) -> AsyncStream<SessionStatus> {
    stream
  }

  var latestResponseText: String?

  func latestResponse(sessionId: String?) async -> VoiceLatestResponse? {
    guard let latestResponseText, let sessionId else { return nil }
    return .init(
      sessionId: sessionId,
      provider: .claude,
      name: "Test",
      text: latestResponseText
    )
  }
}

@MainActor
struct VoiceSessionCompletionWatcherTests {
  @Test
  func armsOnWorkingStatusAndDebouncesCompletion() async throws {
    let executor = CompletionWatcherExecutor()
    let clock = ManualTaskClock()
    let delivered = TestCallbackReceipt()
    var updates: [String] = []
    let watcher = makeClockWatcher(executor: executor, clock: clock, onUpdate: {
      updates.append($0)
      delivered.record()
    })
    defer {
      watcher.cancelAll()
      clock.close()
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    try await waitForInitialTimers(clock)
    executor.yield(.thinking)
    executor.yield(.idle)
    _ = try await clock.nextSleep(for: .milliseconds(5))
    clock.advance(by: .milliseconds(5))
    try await delivered.wait()

    #expect(updates == ["Build finished and is ready for you."])
  }

  @Test
  func completionAnnouncementIncludesLatestResponse() async throws {
    let executor = CompletionWatcherExecutor()
    executor.latestResponseText = "All 23 tests passed."
    let clock = ManualTaskClock()
    let delivered = TestCallbackReceipt()
    var updates: [String] = []
    let watcher = makeClockWatcher(executor: executor, clock: clock, onUpdate: {
      updates.append($0)
      delivered.record()
    })
    defer {
      watcher.cancelAll()
      clock.close()
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    try await waitForInitialTimers(clock)
    executor.yield(.thinking)
    executor.yield(.idle)
    _ = try await clock.nextSleep(for: .milliseconds(5))
    clock.advance(by: .milliseconds(5))
    try await delivered.wait()

    #expect(updates.count == 1)
    let update = try #require(updates.first)
    #expect(update.contains("Build finished."))
    #expect(update.contains("All 23 tests passed."))
  }

  @Test
  func reportsActiveWatchCountAcrossTheWatchLifecycle() async throws {
    let executor = CompletionWatcherExecutor()
    let clock = ManualTaskClock()
    let delivered = TestCallbackReceipt()
    let finished = TestCallbackReceipt()
    var counts: [Int] = []
    var updates: [String] = []
    let watcher = makeClockWatcher(
      executor: executor,
      clock: clock,
      onActiveCountChanged: { count in
        counts.append(count)
        if count == 0, counts.contains(1) { finished.record() }
      },
      onUpdate: {
        updates.append($0)
        delivered.record()
      }
    )
    defer {
      watcher.cancelAll()
      clock.close()
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    #expect(counts.last == 1)

    try await waitForInitialTimers(clock)
    executor.yield(.thinking)
    executor.yield(.idle)
    _ = try await clock.nextSleep(for: .milliseconds(5))
    clock.advance(by: .milliseconds(5))
    try await delivered.wait()
    try await finished.wait()

    #expect(updates == ["Build finished and is ready for you."])
    #expect(counts.last == 0)
  }

  @Test
  func cancelAllReportsZeroActiveWatches() async {
    let executor = CompletionWatcherExecutor()
    var counts: [Int] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .seconds(1),
      onActiveCountChanged: { counts.append($0) }
    ) { _ in }

    watcher.watch(sessionId: "session-1", name: "Build")
    #expect(counts.last == 1)

    watcher.cancelAll()
    #expect(counts.last == 0)
  }

  @Test
  func explicitWatchAnnouncesTimeoutInsteadOfEndingSilently() async throws {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .milliseconds(20)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build", announceTimeout: true)
    executor.yield(.thinking)
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build is still running — I've stopped watching it."])
  }

  @Test
  func implicitWatchStillTimesOutSilently() async throws {
    let executor = CompletionWatcherExecutor()
    let finished = TestCallbackReceipt()
    var updates: [String] = []
    var counts: [Int] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .milliseconds(20),
      onActiveCountChanged: { count in
        counts.append(count)
        if count == 0, counts.contains(1) { finished.record() }
      }
    ) {
      updates.append($0)
    }

    defer { watcher.cancelAll() }
    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.thinking)
    try await finished.wait()

    #expect(counts.last == 0)
    #expect(updates.isEmpty)
  }

  @Test
  func reportsApprovalImmediately() async throws {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .seconds(1)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.awaitingApproval(tool: "Bash"))
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build is awaiting approval for Bash."])
  }

  @Test
  func keepsWatchingWhenDebouncedStatusIsNoLongerStable() async throws {
    let executor = CompletionWatcherExecutor()
    let clock = ManualTaskClock()
    let (events, continuation) = AsyncStream<CompletionTestEvent>.makeStream()
    var iterator = events.makeAsyncIterator()
    executor.onStatusRead = { continuation.yield(.statusRead($0)) }
    var updates: [String] = []
    let watcher = makeClockWatcher(
      executor: executor,
      clock: clock,
      completionDebounce: .milliseconds(20),
      onDebounceRequested: { continuation.yield(.debounceRequested) },
      onUpdate: {
        updates.append($0)
        continuation.yield(.update)
      }
    )
    defer {
      watcher.cancelAll()
      clock.close()
      continuation.finish()
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    try await waitForInitialTimers(clock)
    executor.yield(.thinking)
    executor.yield(.idle)
    try #require(await iterator.next() == .debounceRequested)
    let firstDebounce = try await clock.nextSleep(for: .milliseconds(20))
    executor.currentStatus = .thinking
    clock.advance(by: .milliseconds(20))
    try #require(await iterator.next() == .statusRead(SessionStatus.thinking.displayName))
    #expect(updates.isEmpty)
    executor.yield(.waitingForUser)
    // An incorrect first completion emits .update instead. Fail before waiting
    // for a timer that that completed watcher would never register.
    try #require(await iterator.next() == .debounceRequested)
    _ = try await clock.nextSleep(for: .milliseconds(20), after: firstDebounce.id)
    clock.advance(by: .milliseconds(20))
    try #require(await iterator.next() == .statusRead(SessionStatus.waitingForUser.displayName))
    try #require(await iterator.next() == .update)

    #expect(updates == ["Build finished and is ready for you."])
  }

  private func makeClockWatcher(
    executor: CompletionWatcherExecutor,
    clock: ManualTaskClock,
    completionDebounce: Duration = .milliseconds(5),
    onActiveCountChanged: (@MainActor @Sendable (Int) -> Void)? = nil,
    onDebounceRequested: (@MainActor () -> Void)? = nil,
    onUpdate: @escaping @MainActor @Sendable (String) -> Void
  ) -> VoiceSessionCompletionWatcher {
    VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: completionDebounce,
      maximumDuration: .seconds(1),
      sleep: { duration in
        if duration == completionDebounce { onDebounceRequested?() }
        try await clock.sleep(for: duration)
      },
      onActiveCountChanged: onActiveCountChanged,
      onUpdate: onUpdate
    )
  }

  private func waitForInitialTimers(_ clock: ManualTaskClock) async throws {
    let first = try await clock.nextSleep(for: .seconds(1))
    _ = try await clock.nextSleep(for: .seconds(1), after: first.id)
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<200 {
      if predicate() {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}

private enum CompletionTestEvent: Equatable, Sendable {
  case debounceRequested
  case statusRead(String?)
  case update
}
