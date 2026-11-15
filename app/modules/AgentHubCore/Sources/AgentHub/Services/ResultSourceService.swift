import CryptoKit
import Foundation

struct ResultSourceSnapshot: Equatable, Sendable {
  let worktreePath: String
  let repositoryPath: String
  let identity: String?
}

protocol ResultSourceInspecting: Sendable {
  func inspect(projectPath: String) async -> ResultSourceSnapshot
}

/// A content signature covers tracked changes and bounded untracked files, never just HEAD.
/// Ignored build output and a running server remain unverified even when source is unchanged.
actor ResultSourceService: ResultSourceInspecting {
  func inspect(projectPath: String) async -> ResultSourceSnapshot {
    let fallback = ResultSourceSnapshot(worktreePath: projectPath, repositoryPath: projectPath, identity: nil)
    guard let rootData = git(["rev-parse", "--show-toplevel"], at: projectPath),
      let root = String(data: rootData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !root.isEmpty else { return fallback }
    var repository = root
    if let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root),
      let path = String(data: common, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      path.hasSuffix("/.git") {
      repository = URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
    let unavailable = ResultSourceSnapshot(worktreePath: root, repositoryPath: repository, identity: nil)
    guard let head = git(["rev-parse", "HEAD"], at: root),
      let changes = git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], at: root),
      let staged = git(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], at: root),
      let status = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root),
      let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], at: root) else { return unavailable }
    var digest = SHA256()
    for value in [Data(root.utf8), head, changes, staged, status] {
      digest.update(data: value)
      digest.update(data: Data([0]))
    }
    var capturedFiles: [URL: Data] = [:]
    var budget = 16 * 1024 * 1024
    for bytes in untracked.split(separator: 0).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
      guard let name = String(data: Data(bytes), encoding: .utf8) else { return unavailable }
      let url = URL(fileURLWithPath: root).appendingPathComponent(name)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true,
        let size = values.fileSize, size <= budget,
        let contents = try? Data(contentsOf: url), contents.count <= budget else { return unavailable }
      capturedFiles[url] = contents
      budget -= contents.count
      digest.update(data: Data(bytes)); digest.update(data: Data([0]))
      // Fixed-size payload hashes keep binary bytes from becoming the next entry's path.
      digest.update(data: Data(SHA256.hash(data: contents)))
    }
    // Recheck every input; this is a captured observation, not an atomic lock on the user's work.
    for (url, contents) in capturedFiles {
      guard (try? Data(contentsOf: url)) == contents else { return unavailable }
    }
    guard git(["rev-parse", "HEAD"], at: root) == head,
      git(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], at: root) == staged,
      git(["ls-files", "--others", "--exclude-standard", "-z"], at: root) == untracked,
      git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root) == status,
      git(["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"], at: root) == changes else { return unavailable }
    return ResultSourceSnapshot(worktreePath: root, repositoryPath: repository,
      identity: digest.finalize().map { String(format: "%02x", $0) }.joined())
  }

  private func git(_ arguments: [String], at path: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
      defer { timeout.cancel() }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0, data.count <= 16 * 1024 * 1024 else { return nil }
      return data
    } catch { return nil }
  }
}
