import Foundation
import Darwin
import Testing
@testable import AgentHubCore

struct ResultSourceServiceTests {
  @Test func stableContentAndEachChangeWithoutMovingHEAD() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    let service = ResultSourceService()
    let head = try fixture.git("rev-parse", "HEAD")
    let original = await service.inspect(projectPath: fixture.root.path)
    #expect(original.identity != nil)
    #expect(await service.inspect(projectPath: fixture.root.path) == original)
    try fixture.write("tracked", "changed\n")
    let tracked = await service.inspect(projectPath: fixture.root.path)
    #expect(tracked.identity != original.identity)
    try fixture.git("add", "tracked")
    let staged = await service.inspect(projectPath: fixture.root.path)
    #expect(staged.identity != tracked.identity)
    try fixture.write("new", "first")
    let untracked = await service.inspect(projectPath: fixture.root.path)
    try fixture.write("new", "other") // Same byte count and same porcelain status.
    let edited = await service.inspect(projectPath: fixture.root.path)
    #expect(edited.identity != nil && edited.identity != untracked.identity)
    #expect(try fixture.git("rev-parse", "HEAD") == head)
  }

  @Test func stagedBytesAreCapturedEvenWhenWorkingBytesAndStatusStayTheSame() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    let service = ResultSourceService()
    try fixture.write("tracked", "stage-one\n")
    try fixture.git("add", "tracked")
    try fixture.write("tracked", "working\n")
    let first = await service.inspect(projectPath: fixture.root.path)
    let status = try fixture.git("status", "--porcelain=v1")
    try fixture.write("tracked", "stage-two\n")
    try fixture.git("add", "tracked")
    try fixture.write("tracked", "working\n")
    let second = await service.inspect(projectPath: fixture.root.path)
    #expect(try fixture.git("status", "--porcelain=v1") == status)
    #expect(first.identity != nil && second.identity != nil && first.identity != second.identity)
  }

  @Test func configuredExternalAndTextconvDiffCannotReplaceContentEvidence() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    try fixture.write(".gitattributes", "tracked diff=constant\n")
    try fixture.git("add", ".gitattributes")
    try fixture.git("commit", "-qm", "attributes")
    try fixture.git("config", "diff.external", "/usr/bin/true")
    try fixture.git("config", "diff.constant.command", "/usr/bin/true")
    try fixture.git("config", "diff.constant.textconv", "/usr/bin/true")
    let service = ResultSourceService()
    try fixture.write("tracked", "first change\n")
    let first = await service.inspect(projectPath: fixture.root.path)
    try fixture.write("tracked", "other change\n")
    let second = await service.inspect(projectPath: fixture.root.path)
    #expect(first.identity != nil && second.identity != nil && first.identity != second.identity)
  }

  @Test func binaryUntrackedContentsCannotCollideAtEntryBoundaries() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    let service = ResultSourceService()
    try Data([120]).write(to: fixture.root.appendingPathComponent("a"))
    try Data([98, 0, 121]).write(to: fixture.root.appendingPathComponent("b"))
    let first = await service.inspect(projectPath: fixture.root.path)
    try Data([120, 98, 0]).write(to: fixture.root.appendingPathComponent("a"))
    try Data([121]).write(to: fixture.root.appendingPathComponent("b"))
    let second = await service.inspect(projectPath: fixture.root.path)
    #expect(first.identity != nil && second.identity != nil && first.identity != second.identity)
  }

  @Test func linkedWorktreeRetainsCanonicalRepositoryAndOwnRoot() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    let linked = fixture.container.appendingPathComponent("linked")
    try fixture.git("worktree", "add", "-b", "fixture-linked", linked.path)
    let nested = linked.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let snapshot = await ResultSourceService().inspect(projectPath: nested.path)
    #expect(try snapshot.worktreePath == canonicalPath(linked.path))
    #expect(try snapshot.repositoryPath == canonicalPath(fixture.root.path))
    #expect(snapshot.identity != nil)
  }

  @Test func unsupportedDirectorySymlinkAndOversizedUntrackedAreUnknown() async throws {
    let fixture = try SourceGitFixture()
    defer { fixture.remove() }
    let service = ResultSourceService()
    #expect(await service.inspect(projectPath: fixture.container.path).identity == nil)
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root.appendingPathComponent("tracked"))
    #expect(await service.inspect(projectPath: fixture.root.path).identity == nil)
    try FileManager.default.removeItem(at: link)
    try Data(repeating: 65, count: 16 * 1024 * 1024 + 1).write(to: fixture.root.appendingPathComponent("large"))
    #expect(await service.inspect(projectPath: fixture.root.path).identity == nil)
  }
}

private struct SourceGitFixture {
  let container: URL
  let root: URL
  init() throws {
    container = FileManager.default.temporaryDirectory.appendingPathComponent("ResultSourceTests-\(UUID())").resolvingSymlinksInPath()
    root = container.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git("init")
    try git("config", "user.name", "Fixture")
    try git("config", "user.email", "fixture@example.invalid")
    try git("config", "core.hooksPath", "/dev/null")
    try git("config", "commit.gpgsign", "false")
    try write("tracked", "base\n")
    try git("add", "tracked")
    try git("commit", "-qm", "fixture")
  }
  func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(name))
  }
  @discardableResult func git(_ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    // Fixtures must not inherit user hooks, aliases or repository selection.
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": container.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    return String(decoding: data, as: UTF8.self)
  }
  func remove() { try? FileManager.default.removeItem(at: container) }
}

private func canonicalPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else { throw CocoaError(.fileReadUnknown) }
  defer { free(resolved) }
  return String(cString: resolved)
}
