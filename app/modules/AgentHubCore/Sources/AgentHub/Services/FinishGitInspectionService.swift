import Foundation

protocol FinishGitInspecting: Sendable {
  func inspect(at path: String) async throws -> FinishGitSafety
}

/// Read-only Git facts. No fetch, config, index, ref or worktree mutation.
actor FinishGitInspectionService: FinishGitInspecting {
  private let runner: any CommitGitRunning
  init(runner: any CommitGitRunning = CommitGitRunner(timeout: 8)) { self.runner = runner }

  func inspect(at path: String) async throws -> FinishGitSafety {
    let root = try command(["rev-parse", "--show-toplevel"], at: path).trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = try command(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    let head = try command(["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try command(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
    // A concurrent checkout during the read invalidates the whole sample.
    guard head == commandValue(["rev-parse", "HEAD"], at: root),
      branch == commandValue(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
    else { throw InspectionError.changed }
    return FinishGitSafety(root: WorktreeModuleResolver.normalizedDirectoryPath(root),
      branch: branch, head: head, hasUncommittedChanges: !status.isEmpty)
  }

  private func commandValue(_ arguments: [String], at path: String) -> String? {
    try? command(arguments, at: path).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func command(_ arguments: [String], at path: String) throws -> String {
    let result = try runner.run(at: path, arguments: ["--no-optional-locks"] + arguments,
      environment: [:], input: nil)
    guard result.status == 0, let output = String(data: result.stdout, encoding: .utf8) else {
      throw InspectionError.unavailable
    }
    return output
  }

  private enum InspectionError: Error { case changed, unavailable }
}
