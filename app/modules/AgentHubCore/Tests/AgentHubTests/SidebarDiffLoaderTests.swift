import Foundation
import Testing

@testable import AgentHubCore

@MainActor
struct SidebarDiffLoaderTests {
  @Test("A reopened sidebar refreshes an existing cache")
  func refreshAfterReopening() {
    let activity = Date(timeIntervalSince1970: 100)
    #expect(SidebarDiffLoader.shouldRefresh(previous: nil, activity: activity))
    #expect(!SidebarDiffLoader.shouldRefresh(previous: activity, activity: activity))
    #expect(
      SidebarDiffLoader.shouldRefresh(previous: activity, activity: activity.addingTimeInterval(1)))
  }

  @Test("Paths shared by providers load only once")
  func deduplicate() {
    let earlier = Date(timeIntervalSince1970: 1)
    let later = earlier.addingTimeInterval(1)
    let inputs = [
      SidebarDiffInput(path: "/a", provider: .claude, activity: earlier),
      SidebarDiffInput(path: "/a", provider: .codex, activity: later),
    ]
    #expect(SidebarDiffLoader.coalesce(inputs) == [inputs[1]])
  }

  @Test("Replacement loads share a concurrency limit")
  func replacementConcurrency() async throws {
    let gate = ReplacementGate()
    let inputs = ["/a", "/b", "/c"].map {
      SidebarDiffInput(path: $0, provider: .claude, activity: .distantPast)
    }
    let first = Task { await SidebarDiffLoader.run([inputs[0]]) { await gate.load($0.path) } }
    await gate.waitForStarted(1)
    first.cancel()
    let second = Task { await SidebarDiffLoader.run([inputs[1]]) { await gate.load($0.path) } }
    await gate.waitForStarted(2)
    second.cancel()
    let third = Task { await SidebarDiffLoader.run([inputs[2]]) { await gate.load($0.path) } }
    // Allow a replacement to acquire a slot, if the shared limit permits it.
    try await Task.sleep(for: .milliseconds(100))
    let peak = await gate.peak
    await gate.releaseAll()
    await first.value
    await second.value
    await third.value
    #expect(peak <= 2)
  }

  @Test("Cancellation stops queued paths")
  func cancellation() async {
    let gate = DiffGate()
    let inputs = [
      SidebarDiffInput(path: "/a", provider: .claude, activity: .distantPast),
      SidebarDiffInput(path: "/b", provider: .codex, activity: .distantPast),
    ]
    let task = Task {
      await SidebarDiffLoader.run(inputs) { input in await gate.load(input.path) }
    }
    await gate.waitForStart()
    task.cancel()
    await gate.release()
    await task.value
    #expect(await gate.paths == ["/a"])
  }
}

private actor DiffGate {
  private(set) var paths: [String] = []
  private var running: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  func load(_ path: String) async {
    paths.append(path)
    started?.resume()
    await withCheckedContinuation { running = $0 }
  }
  func waitForStart() async {
    if !paths.isEmpty { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() {
    running?.resume()
    running = nil
  }
}

private actor ReplacementGate {
  private var current = 0
  private(set) var peak = 0
  private var started = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var held: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func load(_ path: String) async {
    current += 1
    peak = max(peak, current)
    started += 1
    let ready = waiters.filter { $0.0 <= started }
    waiters.removeAll { $0.0 <= started }
    for (_, continuation) in ready { continuation.resume() }
    if !released { await withCheckedContinuation { held.append($0) } }
    current -= 1
  }
  func waitForStarted(_ count: Int) async {
    if started >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
  func releaseAll() {
    released = true
    for continuation in held { continuation.resume() }
    held.removeAll()
  }
}
