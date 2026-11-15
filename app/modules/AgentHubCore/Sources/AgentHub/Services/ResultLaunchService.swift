import AppKit
import Foundation

protocol ResultHealthChecking: Sendable {
  func isReachable(_ url: URL) async -> Bool
}

actor ResultHealthService: ResultHealthChecking {
  private let configuration: URLSessionConfiguration

  init(configuration: URLSessionConfiguration = .ephemeral) {
    let copy = configuration.copy() as! URLSessionConfiguration
    copy.timeoutIntervalForResource = min(copy.timeoutIntervalForResource, 4)
    self.configuration = copy
  }

  func isReachable(_ url: URL) async -> Bool {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    components.fragment = nil
    guard let networkURL = components.url else { return false }
    var request = URLRequest(
      url: networkURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
    request.httpMethod = "HEAD"
    guard let response = await responseHeaders(for: request), !Task.isCancelled,
      response.url == networkURL
    else { return false }
    if (200..<400).contains(response.statusCode) { return true }
    guard response.statusCode == 405 || response.statusCode == 501 else { return false }
    request.httpMethod = "GET"
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
    guard let fallback = await responseHeaders(for: request), !Task.isCancelled,
      fallback.url == networkURL
    else { return false }
    return (200..<400).contains(fallback.statusCode)
  }

  private func responseHeaders(for request: URLRequest) async -> HTTPURLResponse? {
    let probe = ResultHealthProbe()
    return await withTaskCancellationHandler {
      await probe.response(for: request, configuration: configuration)
    } onCancel: {
      probe.cancel()
    }
  }
}

/// Stop the probe when URLSession delivers the response. CFNetwork can buffer
/// a small prefix while identifying the response's content type.
private final class ResultHealthProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<HTTPURLResponse?, Never>?
  private var session: URLSession?
  private var cancelled = false

  func response(for request: URLRequest, configuration: URLSessionConfiguration) async
    -> HTTPURLResponse?
  {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard !cancelled else {
        lock.unlock()
        continuation.resume(returning: nil)
        return
      }
      self.continuation = continuation
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      let task = session.dataTask(with: request)
      task.resume()
      lock.unlock()
    }
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let session = self.session
    lock.unlock()
    session?.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    self.session = nil
    lock.unlock()
    completionHandler(.cancel)
    session.invalidateAndCancel()
    continuation?.resume(returning: response as? HTTPURLResponse)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    finish(nil, session: session)
  }

  private func finish(_ response: HTTPURLResponse?, session: URLSession) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    self.session = nil
    lock.unlock()
    session.invalidateAndCancel()
    continuation?.resume(returning: response)
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
