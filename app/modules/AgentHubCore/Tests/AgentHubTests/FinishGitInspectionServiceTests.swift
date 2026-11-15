import Foundation
import Testing
@testable import AgentHubCore

@Suite("Finish Git inspection")
struct FinishGitInspectionServiceTests {
  @Test("Real Git detects staged, unstaged, untracked and later committed work")
  func actualWorkingTreeSafety() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-git-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try git(["init", "-b", "feature"], directory)
    try git(["config", "user.name", "Finish test"], directory)
    try git(["config", "user.email", "finish@example.test"], directory)
    let tracked = directory.appendingPathComponent("tracked.txt")
    try "first".write(to: tracked, atomically: true, encoding: .utf8)
    try git(["add", "--", "tracked.txt"], directory)
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Initial"], directory)
    let service = FinishGitInspectionService()
    let initial = try await service.inspect(at: directory.path)
    #expect(initial.branch == "feature")
    #expect(!initial.hasUncommittedChanges)
    try "changed".write(to: tracked, atomically: true, encoding: .utf8)
    #expect(try await service.inspect(at: directory.path).hasUncommittedChanges)
    try git(["add", "--", "tracked.txt"], directory)
    #expect(try await service.inspect(at: directory.path).hasUncommittedChanges)
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Later"], directory)
    let later = try await service.inspect(at: directory.path)
    #expect(!later.hasUncommittedChanges)
    #expect(later.head != initial.head)
    try "untracked".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    #expect(try await service.inspect(at: directory.path).hasUncommittedChanges)
  }

  @Test("Git exit is independent of a surviving fsmonitor stderr writer")
  func inheritedWriterDoesNotDelayFinish() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-inherited-writer-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try git(["init", "-b", "feature"], directory)
    try git(["config", "user.name", "Finish test"], directory)
    try git(["config", "user.email", "finish@example.test"], directory)
    try "first".write(to: directory.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
    try git(["add", "--", "tracked"], directory)
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Initial"], directory)
    let hook = directory.appendingPathComponent("fsmonitor.sh")
    try "#!/bin/sh\n/bin/sleep 4 </dev/null >/dev/null &\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try git(["config", "core.fsmonitor", hook.path], directory)
    let start = Date()
    _ = try await FinishGitInspectionService().inspect(at: directory.path)
    #expect(Date().timeIntervalSince(start) < 3, "Finish must not wait for the unrelated inherited writer to exit")
  }

  @Test("Finish Git inspection respects the existing runner deadline")
  func inspectionDeadlineFailsClosed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-deadline-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try git(["init", "-b", "feature"], directory)
    try git(["config", "user.name", "Finish test"], directory)
    try git(["config", "user.email", "finish@example.test"], directory)
    try "first".write(to: directory.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
    try git(["add", "--", "tracked"], directory)
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Initial"], directory)
    let hook = directory.appendingPathComponent("fsmonitor.sh")
    try "#!/bin/sh\n/bin/sleep 10\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try git(["config", "core.fsmonitor", hook.path], directory)
    let service = FinishGitInspectionService(runner: CommitGitRunner(timeout: 0.1))
    let start = Date()
    do {
      _ = try await service.inspect(at: directory.path)
      Issue.record("Deadline must leave Git safety unavailable")
    } catch { #expect(Date().timeIntervalSince(start) < 3) }
  }

  @Test("Cancelling Finish inspection stops its disposable Git hook promptly")
  func cancelledInspectionFailsClosed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("finish-cancel-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try git(["init", "-b", "feature"], directory)
    try git(["config", "user.name", "Finish test"], directory)
    try git(["config", "user.email", "finish@example.test"], directory)
    try "first".write(to: directory.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
    try git(["add", "--", "tracked"], directory)
    try git(["-c", "commit.gpgsign=false", "commit", "-m", "Initial"], directory)
    let marker = directory.appendingPathComponent("hook-started")
    let hook = directory.appendingPathComponent("fsmonitor.sh")
    try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n/bin/sleep 10\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    try git(["config", "core.fsmonitor", hook.path], directory)
    let service = FinishGitInspectionService(runner: CommitGitRunner(timeout: 5))
    let task = Task { try await service.inspect(at: directory.path) }
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let cancelledAt = Date()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled inspection must not return safety evidence")
    } catch { #expect(Date().timeIntervalSince(cancelledAt) < 2) }
  }

  private func git(_ arguments: [String], _ directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
