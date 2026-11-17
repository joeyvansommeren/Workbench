import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("SessionNameRequestMonitor")
struct SessionNameRequestMonitorTests {
  @Test("Monitor handles queued request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let queue = SessionNameRequestQueue(directoryURL: directory)
    let request = SessionNameRequest(
      id: "name-1",
      createdAt: now,
      name: "Session Naming",
      sourceProvider: .codex,
      sourceSessionId: "session-1",
      sourceProcessId: 42
    )
    try queue.enqueue(request)

    let recorder = SessionNameRequestRecorder()
    let monitor = SessionNameRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) },
      now: { now }
    )
    await monitor.start { queued in
      await recorder.record(queued.request)
    }

    do {
      let completedPoll = try await clock.nextSleep(for: .milliseconds(20))
      await monitor.stop()
      try await clock.waitForCompletion(of: completedPoll)
      #expect(await recorder.requests() == [request])
      #expect(try queue.pendingRequests().isEmpty)
    } catch {
      await monitor.stop()
      clock.close()
      throw error
    }
  }

  @Test("Monitor marks failed request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let queue = SessionNameRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SessionNameRequest(
      id: "name-1",
      createdAt: now.addingTimeInterval(-11),
      name: "Session Naming",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 42
    ))

    let monitor = SessionNameRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) },
      now: { now }
    )
    await monitor.start { _ in
      throw SessionNameRequestHandlingError.sessionUnavailable
    }

    do {
      let completedPoll = try await clock.nextSleep(for: .milliseconds(20))
      await monitor.stop()
      try await clock.waitForCompletion(of: completedPoll)
      let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
      #expect(try queue.pendingRequests().isEmpty)
      #expect(FileManager.default.fileExists(atPath: failedURL.path))
    } catch {
      await monitor.stop()
      clock.close()
      throw error
    }
  }

  @Test("Monitor retries a fresh request while its session is being discovered")
  func monitorRetriesFreshUnavailableSession() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let queue = SessionNameRequestQueue(directoryURL: directory)
    try queue.enqueue(SessionNameRequest(
      id: "name-1",
      createdAt: now,
      name: "Session Naming",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 42
    ))

    let recorder = SessionNameRequestRetryRecorder()
    let monitor = SessionNameRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) },
      now: { now }
    )
    await monitor.start { _ in
      let attempt = await recorder.recordAttempt()
      if attempt == 1 {
        throw SessionNameRequestHandlingError.sessionUnavailable
      }
    }

    do {
      let firstPoll = try await clock.nextSleep(for: .milliseconds(20))
      #expect(await recorder.attemptCount() == 1)
      #expect(try queue.pendingRequests().count == 1)
      clock.advance(by: .milliseconds(20))
      let completedPoll = try await clock.nextSleep(for: .milliseconds(20), after: firstPoll.id)
      await monitor.stop()
      try await clock.waitForCompletion(of: completedPoll)
      #expect(await recorder.attemptCount() == 2)
      #expect(try queue.pendingRequests().isEmpty)
    } catch {
      await monitor.stop()
      clock.close()
      throw error
    }
  }

  @Test("Public defaults deliver a queued request to the handler")
  func publicDefaultsDeliverQueuedRequest() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let now = Date.now
    let queue = SessionNameRequestQueue(directoryURL: directory)
    let request = SessionNameRequest(
      id: "name-1",
      createdAt: now,
      name: "Session Naming",
      sourceProvider: .codex,
      sourceSessionId: "session-1",
      sourceProcessId: 42
    )
    try queue.enqueue(request)

    let recorder = SessionNameRequestRecorder()
    let received = TestCallbackReceipt()
    let monitor = SessionNameRequestMonitor(queue: queue)
    await monitor.start { queued in
      await recorder.record(queued.request)
      received.record()
    }
    do {
      try await received.wait()
      await monitor.stop()
      #expect(await recorder.requests() == [request])
    } catch {
      await monitor.stop()
      throw error
    }
  }
}

private actor SessionNameRequestRecorder {
  private var recordedRequests: [SessionNameRequest] = []

  func record(_ request: SessionNameRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [SessionNameRequest] {
    recordedRequests
  }
}

private actor SessionNameRequestRetryRecorder {
  private var attempts = 0

  func recordAttempt() -> Int {
    attempts += 1
    return attempts
  }

  func attemptCount() -> Int {
    attempts
  }
}

private func temporarySessionNameMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-session-name-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
