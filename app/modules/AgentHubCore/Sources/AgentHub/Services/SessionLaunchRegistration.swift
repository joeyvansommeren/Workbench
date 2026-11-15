import Foundation

@MainActor
protocol SessionLaunchWorktreeRegistering {
  func registerCreatedWorktree(name: String, path: String, parentRepositoryPath: String) async -> WorktreeBranch
}

extension CLISessionsViewModel: SessionLaunchWorktreeRegistering {}

@MainActor
enum SessionLaunchRegistration {
  /// Registration persists ownership and can suspend without throwing cancellation.
  /// Cancellation must be checked again before any terminal can be created.
  static func register(
    using registrar: any SessionLaunchWorktreeRegistering,
    name: String, path: String, parentRepositoryPath: String
  ) async throws -> WorktreeBranch {
    try Task.checkCancellation()
    let worktree = await registrar.registerCreatedWorktree(name: name, path: path,
      parentRepositoryPath: parentRepositoryPath)
    try Task.checkCancellation()
    return worktree
  }
}
