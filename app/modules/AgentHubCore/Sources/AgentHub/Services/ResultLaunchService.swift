import AppKit
import Foundation

protocol ResultHealthChecking: Sendable {
  func isReachable(_ url: URL) async -> Bool
}

actor ResultHealthService: ResultHealthChecking {
  func isReachable(_ url: URL) async -> Bool {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    components.fragment = nil
    guard let networkURL = components.url else { return false }
    var request = URLRequest(url: networkURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
    request.httpMethod = "HEAD"
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard !Task.isCancelled, let http = response as? HTTPURLResponse,
        response.url == networkURL else { return false }
      return (200..<400).contains(http.statusCode)
    } catch { return false }
  }
}

@MainActor
protocol ResultServerStarting {
  func start(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws
  func validate(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) throws
  func restart(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws
}

extension ResultServerStarting {
  func validate(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) throws {}
  func restart(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    throw ResultRecipeError.notOwned
  }
}

@MainActor
struct ResultServerStarter: ResultServerStarting {
  func validate(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) throws {
    let identity = try recipeIdentity(recipe, worktreePath: worktreePath)
    try DevServerManager.shared.validateRecipe(for: key, identity: identity)
  }

  func start(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    try await launch(recipe: recipe, key: key, worktreePath: worktreePath, restart: false)
  }

  func restart(recipe: ProjectLaunchRecipe, key: String, worktreePath: String) async throws {
    try await launch(recipe: recipe, key: key, worktreePath: worktreePath, restart: true)
  }

  private func recipeIdentity(_ recipe: ProjectLaunchRecipe, worktreePath: String) throws -> ResultServerRecipeIdentity {
    let path = try recipe.workingPath(in: worktreePath)
    guard !recipe.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ResultLaunchError.unreachable }
    let destination = try ProjectLaunchRecipe.destinationURL(recipe.destination, projectPath: path)
    guard !destination.isFileURL, let host = destination.host,
      ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else {
      throw ResultLaunchError.unsupportedDestination
    }
    return ResultServerRecipeIdentity(projectPath: path, executable: recipe.executable,
      arguments: recipe.arguments, port: destination.port ?? (destination.scheme == "https" ? 443 : 80))
  }

  private func launch(recipe: ProjectLaunchRecipe, key: String, worktreePath: String, restart: Bool) async throws {
    let identity = try recipeIdentity(recipe, worktreePath: worktreePath)
    try await DevServerManager.shared.startRecipe(for: key, projectPath: identity.projectPath,
      executable: identity.executable, arguments: identity.arguments, port: identity.port, restart: restart)
    let state: DevServerState = DevServerManager.shared.state(for: key)
    if case .failed(let error) = state {
      throw NSError(domain: "ResultLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
    }
  }
}


@MainActor
protocol ResultDestinationOpening {
  func open(_ url: URL) -> Bool
}

@MainActor
struct ResultDestinationOpener: ResultDestinationOpening {
  func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Only inputs that change the launched process belong in this identity; a URL route does not.
struct ResultServerRecipeIdentity: Equatable, Sendable {
  let projectPath: String
  let executable: String
  let arguments: [String]
  let port: Int

  init(projectPath: String, executable: String, arguments: [String], port: Int) {
    self.projectPath = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().standardizedFileURL.path
    self.executable = executable
    self.arguments = arguments
    self.port = port
  }
}

enum ResultServerRecipeAction: Equatable { case start, reuse, restart }
enum ResultRecipeError: LocalizedError {
  case changed, notOwned
  var errorDescription: String? {
    switch self {
    case .changed: return "The saved launch settings changed. Restart the Workbench server to use them."
    case .notOwned: return "Workbench cannot restart this server. Stop or update it in the terminal, then try again."
    }
  }
}
