import Foundation
import Testing

@testable import AgentHubCore

/// The coordinator is main-actor only, like production (its sources deliver on
/// the main queue), so every test runs on the main actor and waits for
/// conditions instead of sleeping fixed amounts.
@MainActor
@Suite("Transcript file watcher")
struct TranscriptFileWatcherTests {
  private final class Counter {
    var count = 0
  }

  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("watcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func wait(seconds: Double = 3, until condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  private func append(_ text: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }

  @Test("A missing file is picked up once it is created, then followed for writes")
  func missingFileThenCreated() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    let changes = Counter()
    let watcher = TranscriptFileWatchCoordinator()
    watcher.onChange = { changes.count += 1 }

    watcher.watch(file.path)
    #expect(watcher.isWaitingForFile)
    #expect(watcher.waitingDirectory == directory.path)

    try "{}\n".write(to: file, atomically: false, encoding: .utf8)
    #expect(await wait { changes.count >= 1 && !watcher.isWaitingForFile })

    let before = changes.count
    try append("{}\n", to: file)
    #expect(await wait { changes.count > before })
    watcher.stop()
  }

  @Test("A missing nested directory is watched from the nearest ancestor and descended")
  func missingNestedDirectory() async throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("projects/-Users-me-repo", isDirectory: true)
    let file = project.appendingPathComponent("session.jsonl")
    let changes = Counter()
    let watcher = TranscriptFileWatchCoordinator()
    watcher.onChange = { changes.count += 1 }

    watcher.watch(file.path)
    #expect(watcher.isWaitingForFile)
    #expect(watcher.waitingDirectory == root.path)

    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    #expect(await wait { watcher.waitingDirectory == project.path })
    #expect(changes.count == 0)  // a directory alone is not a transcript change

    try "{}\n".write(to: file, atomically: false, encoding: .utf8)
    #expect(await wait { changes.count >= 1 && !watcher.isWaitingForFile })
    watcher.stop()
  }

  @Test("An atomic replace is reported and the new file is followed for appends")
  func atomicReplaceThenAppend() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    try "AAA\n".write(to: file, atomically: false, encoding: .utf8)
    let changes = Counter()
    let watcher = TranscriptFileWatchCoordinator()
    watcher.onChange = { changes.count += 1 }
    watcher.watch(file.path)
    #expect(!watcher.isWaitingForFile)

    try "BBB\n".write(to: file, atomically: true, encoding: .utf8)  // rename over the old inode
    #expect(await wait { changes.count >= 1 })
    #expect(await wait { !watcher.isWaitingForFile })

    let before = changes.count
    try append("CCC\n", to: file)
    #expect(await wait { changes.count > before })

    let beforeSecond = changes.count
    try append("DDD\n", to: file)
    #expect(await wait { changes.count > beforeSecond })
    watcher.stop()
  }

  @Test("A deleted file drops back to the directory and comes back when recreated")
  func deleteThenRecreate() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("session.jsonl")
    try "AAA\n".write(to: file, atomically: false, encoding: .utf8)
    let changes = Counter()
    let watcher = TranscriptFileWatchCoordinator()
    watcher.onChange = { changes.count += 1 }
    watcher.watch(file.path)

    try FileManager.default.removeItem(at: file)
    #expect(await wait { watcher.isWaitingForFile })

    try "NEW\n".write(to: file, atomically: false, encoding: .utf8)
    #expect(await wait { !watcher.isWaitingForFile })
    let before = changes.count
    try append("MORE\n", to: file)
    #expect(await wait { changes.count > before })
    watcher.stop()
  }

  @Test("Quick path switches A, B, A ignore events from the stale source")
  func stalePathSwitch() async throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = directory.appendingPathComponent("a.jsonl")
    let b = directory.appendingPathComponent("b.jsonl")
    try "".write(to: a, atomically: false, encoding: .utf8)
    try "".write(to: b, atomically: false, encoding: .utf8)
    let changes = Counter()
    let watcher = TranscriptFileWatchCoordinator()
    watcher.onChange = { changes.count += 1 }

    watcher.watch(a.path)
    watcher.watch(b.path)
    #expect(watcher.watchedPath == b.path)
    try append("x", to: a)  // only the stale A source would see this
    try? await Task.sleep(for: .milliseconds(150))
    #expect(changes.count == 0)

    watcher.watch(a.path)
    try append("y", to: a)
    #expect(await wait { changes.count >= 1 })
    watcher.watch(nil)
    #expect(watcher.watchedPath == nil)
    #expect(!watcher.isWaitingForFile)
  }
  @Test("A replaced directory is followed even when its path stays the same")
  func replacedDirectory() async throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.jsonl")
    let watcher = TranscriptFileWatchCoordinator()
    defer { watcher.stop() }
    let changes = Counter()
    watcher.onChange = { changes.count += 1 }
    watcher.watch(file.path)
    try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("old"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Let the rename event re-arm before creating the transcript.
    try await Task.sleep(for: .milliseconds(150))
    try "{}\n".write(to: file, atomically: false, encoding: .utf8)
    #expect(await wait { changes.count > 0 && !watcher.isWaitingForFile })
  }

}
