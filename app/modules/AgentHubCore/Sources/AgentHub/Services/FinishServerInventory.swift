import Foundation

struct FinishServerRuntimeResource: Sendable {
  let key: String
  let projectPath: String?
  let state: DevServerState
  let isExternal: Bool
}

@MainActor
protocol FinishServerInventoryProviding {
  var finishServerInventory: [FinishServerRuntimeResource] { get }
}

extension DevServerManager: FinishServerInventoryProviding {
  var finishServerInventory: [FinishServerRuntimeResource] {
    servers.map { key, state in
      FinishServerRuntimeResource(key: key, projectPath: serverProjectPaths[key],
        state: state, isExternal: isExternalServer(for: key))
    }
  }
}

enum FinishServerInventory {
  static func keys(for resource: FinishSessionResource) -> [String] {
    let parts = resource.id.split(separator: ":", maxSplits: 1).map(String.init)
    let sessionID = parts.last ?? resource.id
    var keys = [sessionID, sessionID + ":storybook", resource.path]
    if let name = parts.first, let provider = SessionProviderKind(rawValue: name) {
      keys.append(SessionResult.key(provider: provider, sessionID: sessionID) + ":result")
    }
    return keys
  }

  static func resources(
    _ inventory: [FinishServerRuntimeResource], root: String, knownKeys: Set<String>
  ) -> [FinishServerResource] {
    inventory.compactMap { server in
      guard server.state != .idle else { return nil }
      // Unscoped processes are protected even when their key is unfamiliar.
      // A known directory lets unrelated projects remain independent.
      if let path = server.projectPath {
        let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
        guard normalized == root || normalized.hasPrefix(root + "/") || knownKeys.contains(server.key) else { return nil }
      }
      return FinishServerResource(id: server.key,
        description: server.isExternal ? "External server: \(server.key)" : "Server: \(server.key)",
        blocksCleanup: true)
    }.sorted { $0.id < $1.id }
  }
}
