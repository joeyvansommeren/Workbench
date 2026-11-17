import Darwin
import Foundation
import Testing

@testable import AgentHubCore

@Suite("PendingSessionDirectoryWatcher", .serialized)
struct PendingSessionDirectoryWatcherTests {

  @Test("Resolves when a new .jsonl file appears")
  func resolvesWhenNewJSONLAppears() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])

    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("session-a.jsonl").path,
      contents: Data("{}".utf8)
    )

    #expect(await outcome == .found("session-a.jsonl"))
  }

  @Test("Ignores excluded pre-existing files and non-jsonl files")
  func ignoresExcludedAndNonJSONLFiles() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("existing.jsonl").path,
      contents: Data()
    )

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(
      inDirectory: directory.path,
      excluding: ["existing.jsonl"]
    )

    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("notes.txt").path,
      contents: Data()
    )
    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("session-b.jsonl").path,
      contents: Data()
    )

    #expect(await outcome == .found("session-b.jsonl"))
  }

  @Test("Resolves a file that appeared before the watch armed")
  func resolvesFileCreatedBeforeArming() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Simulates the race where the session file lands between the caller's
    // directory snapshot and the kqueue source arming: no further directory
    // writes will occur, so only the initial check can catch it.
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("early.jsonl").path,
      contents: Data()
    )

    let watcher = PendingSessionDirectoryWatcher()
    let outcome = await watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    #expect(outcome == .found("early.jsonl"))
  }

  @Test("cancel() resolves the wait as cancelled")
  func cancelResolvesWait() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    try await Task.sleep(for: .milliseconds(100))
    watcher.cancel()

    #expect(await outcome == .cancelled)
  }

  @Test("cancel() before the wait starts resolves immediately")
  func cancelBeforeStart() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    watcher.cancel()
    let outcome = await watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    #expect(outcome == .cancelled)
  }

  @Test("Unwatchable directory reports unableToWatch")
  func unwatchableDirectory() async {
    let watcher = PendingSessionDirectoryWatcher()
    let outcome = await watcher.waitForNewJSONLFile(
      inDirectory: "/nonexistent/agenthub-test-\(UUID().uuidString)",
      excluding: []
    )
    #expect(outcome == .unableToWatch)
  }

  /// Cancellation must release this watcher's directory descriptor, even when
  /// unrelated suites keep other descriptors open in the same process.
  @Test("Cancelled watches release their directory descriptors")
  func cancelReleasesDirectoryDescriptors() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try directoryIdentity(at: directory)
    #expect(try directoryDescriptors(at: directory, matching: identity).isEmpty)

    // Prove that the counter sees a real O_EVTONLY descriptor while its unique
    // fixture remains linked. This helper owns and closes the control once.
    try verifyDirectoryDescriptorCounter(at: directory, matching: identity)
    #expect(try directoryDescriptors(at: directory, matching: identity).isEmpty)

    var unrelatedDescriptors: [Int32] = []
    defer { unrelatedDescriptors.forEach { close($0) } }
    for _ in 0..<6 {
      let descriptor = open("/dev/null", O_RDONLY)
      try #require(descriptor >= 0)
      unrelatedDescriptors.append(descriptor)
    }
    #expect(try directoryDescriptors(at: directory, matching: identity).isEmpty)

    var observedDirectoryDescriptor = false
    for cycle in 0..<20 {
      let watcher = PendingSessionDirectoryWatcher()
      let pending = Task {
        await watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
      }
      var observationError: Error?
      do {
        if cycle.isMultiple(of: 2) {
          try await Task.sleep(for: .milliseconds(20))
          let descriptors = try directoryDescriptors(at: directory, matching: identity)
          observedDirectoryDescriptor = observedDirectoryDescriptor || !descriptors.isEmpty
        }
      } catch {
        observationError = error
      }

      // Never throw or assert while the checked continuation is still pending.
      // Awaiting the outcome also waits for the cancellation handler's close.
      watcher.cancel()
      let outcome = await pending.value
      if let observationError { throw observationError }
      #expect(outcome == .cancelled)
      #expect(try directoryDescriptors(at: directory, matching: identity).isEmpty)
    }
    #expect(observedDirectoryDescriptor)
  }

  // MARK: - Helpers

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PendingSessionDirectoryWatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private struct DirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  private func directoryIdentity(at directory: URL) throws -> DirectoryIdentity {
    var metadata = stat()
    guard stat(directory.path, &metadata) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return DirectoryIdentity(device: metadata.st_dev, inode: metadata.st_ino)
  }

  private func verifyDirectoryDescriptorCounter(
    at directory: URL,
    matching identity: DirectoryIdentity
  ) throws {
    let descriptor = open(directory.path, O_EVTONLY)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let descriptors = try directoryDescriptors(at: directory, matching: identity)
    #expect(descriptors == [descriptor])
  }

  private func directoryDescriptors(
    at directory: URL,
    matching identity: DirectoryIdentity
  ) throws -> Set<Int32> {
    // The fixture stays linked until every watcher finishes. An unlinked vnode
    // elsewhere can return ENOENT, but cannot identify this live fixture.
    guard try directoryIdentity(at: directory) == identity else {
      throw POSIXError(.ESTALE)
    }
    let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
    var matches: Set<Int32> = []
    for entry in entries {
      guard let descriptor = Int32(entry) else { continue }
      var metadata = stat()
      if fstat(descriptor, &metadata) == 0 {
        if metadata.st_dev == identity.device && metadata.st_ino == identity.inode {
          matches.insert(descriptor)
        }
      } else {
        let error = errno
        // Enumeration races with other suites closing descriptors (EBADF), and
        // macOS can return ENOENT for their already-unlinked vnode descriptors.
        guard error == EBADF || error == ENOENT else {
          throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
      }
    }
    return matches
  }
}
