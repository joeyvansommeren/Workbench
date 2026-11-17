import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("WorktreeLaunchRequestMonitor")
struct WorktreeLaunchRequestMonitorTests {
  @Test("Monitor handles queued request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporaryMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let request = WorktreeLaunchRequest(
      id: "request-1",
      provider: .claude,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    )
    try queue.enqueue(request)

    let recorder = WorktreeLaunchRequestRecorder()
    let monitor = WorktreeLaunchRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) }
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
    let directory = try temporaryMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeLaunchRequest(
      id: "request-1",
      provider: .codex,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    ))

    let monitor = WorktreeLaunchRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) }
    )
    await monitor.start { _ in
      throw WorktreeLaunchRequestHandlingError.emptyPrompt
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

  @Test("Public defaults deliver a queued request to the handler")
  func publicDefaultsDeliverQueuedRequest() async throws {
    let directory = try temporaryMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let request = WorktreeLaunchRequest(
      id: "request-1",
      provider: .claude,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    )
    try queue.enqueue(request)

    let recorder = WorktreeLaunchRequestRecorder()
    let received = TestCallbackReceipt()
    let monitor = WorktreeLaunchRequestMonitor(queue: queue)
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

private actor WorktreeLaunchRequestRecorder {
  private var recordedRequests: [WorktreeLaunchRequest] = []

  func record(_ request: WorktreeLaunchRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [WorktreeLaunchRequest] {
    recordedRequests
  }
}

private func temporaryMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-launch-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
