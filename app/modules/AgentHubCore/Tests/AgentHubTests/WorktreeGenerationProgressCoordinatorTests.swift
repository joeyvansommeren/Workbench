import AgentHubCLIKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("WorktreeGenerationProgressCoordinator")
struct WorktreeGenerationProgressCoordinatorTests {

  @Test("Side-panel completion fires sound and notification once")
  func sidePanelCompletionFires() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = makeCoordinator(sound: sound, notifier: notif, clock: clock)

    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { onProgress in
      await onProgress(.updatingFiles(current: 1, total: 2))
      await onProgress(.completed(path: "/tmp/repo/.worktrees/x"))
    }

    _ = try await clock.nextSleep(for: .milliseconds(750))
    clock.advance(by: .milliseconds(1100))
    try await notif.delivered.wait()
    try await sound.delivered.wait()

    #expect(notif.calls == [["feature/x"]])
    #expect(sound.count == 1)
  }

  @Test("Side-panel and MCP completions fire once with both branches")
  func mixedCompletionFiresOnce() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let watcher = MockProgressWatcher()
    let send = watcher.sendAndWait
    let coord = makeCoordinator(sound: sound, notifier: notif, clock: clock)
    coord.startObservingMCP(watcher: watcher)

    // Keep an MCP op in-flight so the side-panel completion can't fire early.
    await send(snapshot("mcp-1", "mcp/work", .updatingFiles(current: 1, total: 10), at: 1))
    // The mock delivery barrier confirms the queued MainActor subscriber ran.

    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { onProgress in
      await onProgress(.completed(path: "/tmp/repo/.worktrees/x"))
    }
    _ = try await clock.nextSleep(for: .seconds(3))
    clock.advance(by: .milliseconds(200))
    #expect(notif.calls.isEmpty)

    await send(snapshot("mcp-1", "mcp/work", .completed(path: "/tmp/repo/.worktrees/mcp"), at: 2))
    _ = try await clock.nextSleep(for: .milliseconds(750))
    clock.advance(by: .milliseconds(1100))
    try await notif.delivered.wait()
    try await sound.delivered.wait()

    #expect(sound.count == 1)
    #expect(notif.calls.count == 1)
    #expect(Set(notif.calls.first ?? []) == ["feature/x", "mcp/work"])
  }

  @Test("Launch-flow progress is tracked and fires once on completion")
  func launchProgressFires() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = makeCoordinator(sound: sound, notifier: notif, clock: clock)

    coord.reportLaunchProgress(operationID: "L1", branchName: "add-logging", repoName: "repo", providerKind: .claude, progress: .updatingFiles(current: 1, total: 4))
    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 1)

    coord.reportLaunchProgress(operationID: "L1", branchName: "add-logging", repoName: "repo", providerKind: .claude, progress: .completed(path: "/tmp/repo/.worktrees/add-logging"))
    _ = try await clock.nextSleep(for: .milliseconds(750))
    clock.advance(by: .milliseconds(1100))
    try await notif.delivered.wait()
    try await sound.delivered.wait()

    #expect(sound.count == 1)
    #expect(notif.calls == [["add-logging"]])
  }

  @Test("Terminal MCP progress does not regress to preparing")
  func terminalMCPProgressDoesNotRegressToPreparing() async {
    let (clock, watcher) = (ManualTaskClock(), MockProgressWatcher())
    defer { clock.close() }
    let coord = makeCoordinator(sound: MockSound(), notifier: MockNotifier(), clock: clock)
    coord.startObservingMCP(watcher: watcher)

    await watcher.sendAndWait(snapshot("mcp-1", "mcp-opt-in", .completed(path: "/tmp/mcp-opt-in"), at: 1))
    #expect(coord.operations.first?.progress == .completed(path: "/tmp/mcp-opt-in"))
    await watcher.sendAndWait(snapshot("mcp-1", "mcp-opt-in", .preparing(message: "Preparing worktree..."), at: 2))

    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 0)
    #expect(coord.operations.first?.progress == .completed(path: "/tmp/mcp-opt-in"))
  }

  @Test("Branch naming shows a transient row that never announces ready")
  func namingDoesNotFireReady() async {
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .preparingContext(message: "Preparing"))
    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 1)
    #expect(coord.operations.first?.isNaming == true)

    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .completed(message: "ready", source: .ai, branchNames: ["feature/x"]))
    try? await Task.sleep(for: .milliseconds(900))

    // Naming on its own must never play the sound or post the notification.
    #expect(sound.count == 0)
    #expect(notif.calls.isEmpty)
  }

  @Test("Naming + creation announces a single ready worktree, not two")
  func namingPlusCreationCountsOnce() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = makeCoordinator(sound: sound, notifier: notif, clock: clock)

    // The transient naming step followed by the real creation, same worktree.
    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .preparingContext(message: "Preparing"))
    coord.reportNamingProgress(operationID: "N1", repoName: "repo", providerKind: .claude, progress: .completed(message: "ready", source: .ai, branchNames: ["feature/x"]))
    coord.reportLaunchProgress(operationID: "C1", branchName: "feature/x", repoName: "repo", providerKind: .claude, progress: .updatingFiles(current: 1, total: 4))
    coord.reportLaunchProgress(operationID: "C1", branchName: "feature/x", repoName: "repo", providerKind: .claude, progress: .completed(path: "/tmp/x"))
    _ = try await clock.nextSleep(for: .milliseconds(750))
    clock.advance(by: .milliseconds(1100))
    try await notif.delivered.wait()
    try await sound.delivered.wait()

    #expect(sound.count == 1)
    #expect(notif.calls == [["feature/x"]])
  }

  @Test("Failure does not fire ready and keeps the entry visible")
  func failureDoesNotFire() async {
    let sound = MockSound()
    let notif = MockNotifier()
    let coord = WorktreeGenerationProgressCoordinator(soundService: sound, notificationService: notif)

    struct Boom: Error {}
    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { _ in
      throw Boom()
    }

    try? await Task.sleep(for: .milliseconds(1100))

    #expect(sound.count == 0)
    #expect(notif.calls.isEmpty)
    #expect(coord.operations.count == 1)
    #expect(coord.hasFailures)
  }

  @Test("dismissAllFailed clears failed operations")
  func dismissAllFailedClears() async {
    let coord = WorktreeGenerationProgressCoordinator(soundService: MockSound(), notificationService: MockNotifier())

    struct Boom: Error {}
    coord.beginSidePanelOperation(branchName: "feature/x", repoName: "repo", providerKind: .claude) { _ in
      throw Boom()
    }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(coord.hasFailures)
    #expect(coord.operations.count == 1)

    coord.dismissAllFailed()
    #expect(coord.operations.isEmpty)
    #expect(!coord.hasFailures)
  }

  @Test("Sequential MCP completions fire once, not per-worktree (debounce)")
  func sequentialMCPFiresOnce() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let watcher = MockProgressWatcher()
    let send = watcher.sendAndWait
    let coord = makeCoordinator(sound: sound, notifier: notif, clock: clock)
    coord.startObservingMCP(watcher: watcher)

    await send(snapshot("op-1", "b1", .updatingFiles(current: 1, total: 10), at: 1))
    // The mock delivery barrier confirms the queued MainActor subscriber ran.
    await send(snapshot("op-1", "b1", .completed(path: "/tmp/1"), at: 2))
    let firstDebounce = try await clock.nextSleep(for: .milliseconds(750))
    clock.advance(by: .milliseconds(40))
    // The first completion stays inside the debounce window before op-2 starts.
    await send(snapshot("op-2", "b2", .updatingFiles(current: 1, total: 10), at: 3))
    // The mock delivery barrier confirms the queued MainActor subscriber ran.
    await send(snapshot("op-2", "b2", .completed(path: "/tmp/2"), at: 4))
    _ = try await clock.nextSleep(for: .milliseconds(750), after: firstDebounce.id)
    clock.advance(by: .milliseconds(710))
    try await clock.waitForCompletion(of: firstDebounce)
    #expect(notif.calls.isEmpty)
    #expect(sound.count == 0)
    clock.advance(by: .milliseconds(39))
    #expect(notif.calls.isEmpty)
    clock.advance(by: .milliseconds(1))
    try await notif.delivered.wait()
    try await sound.delivered.wait()
    clock.advance(by: .milliseconds(1100))

    #expect(sound.count == 1)
    #expect(notif.calls.count == 1)
    #expect(Set(notif.calls.first ?? []) == ["b1", "b2"])
  }

  @Test("Dismiss removes the operation and discards its MCP snapshot")
  func dismissRemovesAndDiscards() async {
    let watcher = MockProgressWatcher()
    let coord = WorktreeGenerationProgressCoordinator(soundService: MockSound(), notificationService: MockNotifier())
    coord.startObservingMCP(watcher: watcher)

    watcher.send(snapshot("op-1", "b1", .failed(error: "nope"), at: 1))
    await settle()
    #expect(coord.operations.count == 1)

    coord.dismiss(id: "op-1")
    await settle()

    #expect(coord.operations.isEmpty)
    #expect(watcher.discarded == ["op-1"])
  }

  @Test("A stuck in-flight MCP op clears after the staleness timeout without announcing")
  func stuckMCPOperationClearsAfterStaleness() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    UserDefaults.standard.set(true, forKey: AgentHubDefaults.notificationSoundsEnabled)
    let sound = MockSound()
    let notif = MockNotifier()
    let watcher = MockProgressWatcher()
    let send = watcher.sendAndWait
    let coord = WorktreeGenerationProgressCoordinator(
      soundService: sound,
      notificationService: notif,
      mcpStalenessTimeout: .milliseconds(50),
      sleep: { try await clock.sleep(for: $0) }
    )
    coord.startObservingMCP(watcher: watcher)

    // A creation that only ever reports `.preparing` (e.g. git ran silently and
    // the CLI was interrupted before a terminal snapshot) must not linger.
    await send(snapshot("stuck-op", "feature/stuck", .preparing(message: "Preparing worktree..."), at: 1))
    // The mock delivery barrier confirms the queued MainActor subscriber ran.
    #expect(coord.operations.count == 1)
    #expect(coord.inFlightCount == 1)

    _ = try await clock.nextSleep(for: .milliseconds(50))
    clock.advance(by: .milliseconds(160))
    try await watcher.discardDelivered.wait()

    #expect(coord.operations.isEmpty)
    #expect(watcher.discarded == ["stuck-op"])
    // Silent clear — never announce a completion we can't confirm.
    #expect(sound.count == 0)
    #expect(notif.calls.isEmpty)
  }

  @Test("Completion cancels the staleness timeout so the row isn't force-dropped")
  func completingMCPOperationSurvivesStaleness() async throws {
    let clock = ManualTaskClock()
    defer { clock.close() }
    let watcher = MockProgressWatcher()
    let coord = WorktreeGenerationProgressCoordinator(soundService: MockSound(), notificationService: MockNotifier(),
      mcpStalenessTimeout: .milliseconds(50)) { try await clock.sleep(for: $0) }
    coord.startObservingMCP(watcher: watcher)

    await watcher.sendAndWait(snapshot("op-ok", "b-ok", .preparing(message: "Preparing worktree..."), at: 1))
    let pendingStaleness = try await clock.nextSleep(for: .milliseconds(50))
    await watcher.sendAndWait(snapshot("op-ok", "b-ok", .completed(path: "/tmp/ok"), at: 2))
    // Before time advances, only cancellation can finish the armed 50 ms sleep.
    try await clock.waitForCompletion(of: pendingStaleness)
    _ = try await (clock.nextSleep(for: .seconds(3)), clock.nextSleep(for: .milliseconds(750)))
    #expect(coord.operations.first?.progress == .completed(path: "/tmp/ok"))

    // Past staleness, but within the success-clear and ready-debounce windows.
    clock.advance(by: .milliseconds(160))
    #expect(coord.operations.count == 1)
    #expect(coord.operations.first?.progress == .completed(path: "/tmp/ok"))
    #expect(watcher.discarded.isEmpty)

  }

  // MARK: - Helpers

  private func snapshot(
    _ id: String,
    _ branch: String,
    _ progress: WorktreeCreationProgress,
    at seconds: TimeInterval
  ) -> WorktreeProgressSnapshot {
    WorktreeProgressSnapshot(
      operationID: id,
      branchName: branch,
      repositoryPath: "/tmp/repo",
      provider: .codex,
      progress: progress,
      updatedAt: Date(timeIntervalSince1970: seconds)
    )
  }

  private func settle() async {
    try? await Task.sleep(for: .milliseconds(40))
  }
}

@MainActor
private func makeCoordinator(
  sound: MockSound,
  notifier: MockNotifier,
  clock: ManualTaskClock
) -> WorktreeGenerationProgressCoordinator {
  WorktreeGenerationProgressCoordinator(
    soundService: sound,
    notificationService: notifier,
    sleep: { try await clock.sleep(for: $0) }
  )
}

// MARK: - Mocks

private final class MockSound: WorktreeSuccessSoundServiceProtocol, @unchecked Sendable {
  let delivered = TestCallbackReceipt()
  private let lock = NSLock()
  private var _count = 0
  var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
  func playWorktreeCreatedSound() async {
    lock.lock(); _count += 1; lock.unlock()
    delivered.record()
  }
}

private final class MockNotifier: WorktreeReadyNotificationServiceProtocol, @unchecked Sendable {
  let delivered = TestCallbackReceipt()
  private let lock = NSLock()
  private var _calls: [[String]] = []
  var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
  func requestPermission() async -> Bool { true }
  func notifyReady(branchNames: [String]) {
    lock.lock(); _calls.append(branchNames); lock.unlock()
    delivered.record()
  }
}

private final class MockProgressWatcher: WorktreeProgressSidecarWatcherProtocol, @unchecked Sendable {
  let discardDelivered = TestCallbackReceipt()
  private let subject = PassthroughSubject<WorktreeProgressSnapshot, Never>()
  var updates: AnyPublisher<WorktreeProgressSnapshot, Never> { subject.eraseToAnyPublisher() }

  private let lock = NSLock()
  private var _discarded: [String] = []
  var discarded: [String] { lock.lock(); defer { lock.unlock() }; return _discarded }

  func start() async {}
  func wipeAll() async {}
  func discardSnapshot(operationID: String) async {
    lock.lock(); _discarded.append(operationID); lock.unlock()
    discardDelivered.record()
  }

  func send(_ snapshot: WorktreeProgressSnapshot) {
    subject.send(snapshot)
  }

  func sendAndWait(_ snapshot: WorktreeProgressSnapshot) async {
    subject.send(snapshot)
    // receive(on: DispatchQueue.main) enqueues before this barrier on the same queue.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}
