import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("WorktreeDeletionRequestMonitor")
struct WorktreeDeletionRequestMonitorTests {
  @Test("Monitor handles queued deletion request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporaryDeletionMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let request = WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      removeFromDisk: false
    )
    try queue.enqueue(request)

    let recorder = WorktreeDeletionRequestRecorder()
    let monitor = WorktreeDeletionRequestMonitor(
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

  @Test("Monitor marks failed deletion request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporaryDeletionMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let clock = ManualTaskClock()
    defer { clock.close() }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature"
    ))

    let monitor = WorktreeDeletionRequestMonitor(
      queue: queue,
      pollInterval: .milliseconds(20),
      sleep: { try await clock.sleep(for: $0) }
    )
    await monitor.start { _ in
      throw WorktreeDeletionRequestHandlingError.deletionFailed("failed")
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
    let directory = try temporaryDeletionMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let request = WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      removeFromDisk: false
    )
    try queue.enqueue(request)

    let recorder = WorktreeDeletionRequestRecorder()
    let received = TestCallbackReceipt()
    let monitor = WorktreeDeletionRequestMonitor(queue: queue)
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

private actor WorktreeDeletionRequestRecorder {
  private var recordedRequests: [WorktreeDeletionRequest] = []

  func record(_ request: WorktreeDeletionRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [WorktreeDeletionRequest] {
    recordedRequests
  }
}

private func temporaryDeletionMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-deletion-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
