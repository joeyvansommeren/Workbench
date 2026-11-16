import Foundation

struct ProjectLaunchRecipe: Codable, Equatable, Sendable {
  var repositoryPath: String
  var workingSubdirectory = ""
  var executable = ""
  var arguments: [String] = []
  var destination = ""
  var expectedState = ""
  /// Optional for compatibility with recipes saved before native targets were supported.
  var nativeTarget: String?

  func workingPath(in worktreePath: String) throws -> String {
    let root = URL(fileURLWithPath: worktreePath).standardizedFileURL.resolvingSymlinksInPath()
    guard !workingSubdirectory.hasPrefix("/") else { throw ResultLaunchError.outsideWorkspace }
    let candidate = root.appendingPathComponent(workingSubdirectory).standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
      throw ResultLaunchError.outsideWorkspace
    }
    return candidate.path
  }

  func nativeBuildURL(in worktreePath: String, destination: String) throws -> URL {
    let path = try workingPath(in: worktreePath)
    let url = try Self.destinationURL(destination, projectPath: worktreePath, relativeTo: path)
    guard url.isFileURL, url.pathExtension.lowercased() == "app" else {
      throw ResultLaunchError.unsupportedNativeTarget
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        || FileManager.default.fileExists(atPath: url.appendingPathComponent("Info.plist").path)
    else { throw ResultLaunchError.missingFile }
    return url
  }

  static func destinationURL(_ value: String, projectPath: String, relativeTo workingPath: String? = nil) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ResultLaunchError.noDestination }
    if let url = URL(string: trimmed), let scheme = url.scheme {
      guard ["http", "https"].contains(scheme.lowercased()), url.host != nil,
        url.user == nil, url.password == nil else { throw ResultLaunchError.unsupportedDestination }
      return url
    }
    let root = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
    let base = workingPath.map { URL(fileURLWithPath: $0) } ?? root
    let url = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : base.appendingPathComponent(trimmed)
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
      throw ResultLaunchError.outsideWorkspace
    }
    return resolved
  }
}

enum ResultLaunchError: LocalizedError, Equatable {
  case outsideWorkspace, noDestination, unsupportedDestination, missingFile, unreachable, stale, unavailableStore, unsupportedNativeTarget
  var errorDescription: String? {
    switch self {
    case .unsupportedNativeTarget: "Choose a built .app inside the working directory. Simulator launch is not supported here; use the Simulator action."
    case .outsideWorkspace: "Choose a path inside this session’s worktree."
    case .noDestination: "Add the exact result URL or a file path."
    case .unsupportedDestination: "Use an HTTP URL or a file inside this worktree."
    case .missingFile: "The result file is missing. Build it or edit its path."
    case .unreachable: "The result is not reachable. Start its server, retry, or edit the recipe."
    case .stale: "The source changed. Review and save the result again before accepting it."
    case .unavailableStore: "Result storage is unavailable. Restart Workbench and try again."
    }
  }
}
