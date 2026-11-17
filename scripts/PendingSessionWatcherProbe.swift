import Foundation

@main
struct PendingSessionWatcherProbe {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pending-watcher-probe-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try releaseOnWatcherQueue()

    for _ in 0..<500 {
      var watcher: PendingSessionDirectoryWatcher? = PendingSessionDirectoryWatcher()
      watcher?.cancel()
      watcher = nil
    }

    for cycle in 0..<1000 {
      try await cancelAndRelease(in: root.path, cycle: cycle)
    }

    let foundDirectory = root.appendingPathComponent("found")
    try FileManager.default.createDirectory(at: foundDirectory, withIntermediateDirectories: true)
    try Data().write(to: foundDirectory.appendingPathComponent("session.jsonl"))
    var foundWatcher: PendingSessionDirectoryWatcher? = PendingSessionDirectoryWatcher()
    let found = await foundWatcher!.waitForNewJSONLFile(
      inDirectory: foundDirectory.path, excluding: [])
    guard found == .found("session.jsonl") else { throw ProbeError.unexpectedOutcome }
    foundWatcher?.cancel()
    foundWatcher = nil

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        let directory = root.appendingPathComponent("concurrent-\(index)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        group.addTask {
          for cycle in 0..<100 {
            try await cancelAndRelease(in: directory.path, cycle: cycle)
          }
        }
      }
      try await group.waitForAll()
    }
    print("PASS: release before start, repeated cancellation, found file, concurrent watchers")
  }

  static func releaseOnWatcherQueue() throws {
    var watcher: PendingSessionDirectoryWatcher? = PendingSessionDirectoryWatcher()
    weak var released = watcher
    let queue = try watcherQueue(watcher!)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0)
    defer { release.signal() }

    // Keep the queue blocked until cancel() holds the watcher's final reference.
    queue.async {
      entered.signal()
      release.wait()
    }
    guard entered.wait(timeout: .now() + 5) == .success else {
      throw ProbeError.unexpectedOutcome
    }
    watcher?.cancel()
    watcher = nil
    queue.async { drained.signal() }
    release.signal()
    guard drained.wait(timeout: .now() + 5) == .success, released == nil else {
      throw ProbeError.unexpectedOutcome
    }
  }

  static func watcherQueue(_ watcher: PendingSessionDirectoryWatcher) throws -> DispatchQueue {
    // Reflection keeps this scheduling control out of the production API.
    guard let queue = Mirror(reflecting: watcher).children.first(where: { $0.label == "queue" })?
      .value as? DispatchQueue
    else { throw ProbeError.unexpectedOutcome }
    return queue
  }

  static func cancelAndRelease(in directory: String, cycle: Int) async throws {
    var watcher: PendingSessionDirectoryWatcher? = PendingSessionDirectoryWatcher()
    let launch = watcher!
    let task = Task { await launch.waitForNewJSONLFile(inDirectory: directory, excluding: []) }
    if cycle.isMultiple(of: 2) { try await Task.sleep(for: .milliseconds(2)) }
    watcher?.cancel()
    guard await task.value == .cancelled else { throw ProbeError.unexpectedOutcome }
    watcher?.cancel()
    watcher = nil
  }

  enum ProbeError: Error { case unexpectedOutcome }
}
