import Darwin
import Foundation

enum FinishProcessState: Equatable, Sendable {
  case running, stopped, unknown
}

struct FinishTerminalResource: Equatable, Sendable {
  let provider: SessionProviderKind
  let key: String
  let projectPath: String?
  let processID: Int32?
  var processState: FinishProcessState
  var processIDs: [Int32]? = nil
  var confirmedExitAt: Date? = nil
  var closedAt: Date? = nil
}

struct FinishRuntimeInventory: Sendable {
  let isComplete: Bool
  let sessions: [FinishSessionResource]
  let terminals: [FinishTerminalResource]

  static let unknown = FinishRuntimeInventory(isComplete: false, sessions: [], terminals: [])

  @MainActor
  static func capture(claude: CLISessionsViewModel, codex: CLISessionsViewModel) -> FinishRuntimeInventory {
    let inventories = [claude.finishRuntimeInventory, codex.finishRuntimeInventory]
    return FinishRuntimeInventory(isComplete: inventories.allSatisfy(\.isComplete),
      sessions: inventories.flatMap(\.sessions), terminals: inventories.flatMap(\.terminals))
  }

  static func processState(for pid: Int32?) -> FinishProcessState {
    guard let pid, pid > 0 else { return .unknown }
    if kill(pid, 0) == 0 || errno == EPERM { return .running }
    return errno == ESRCH ? .stopped : .unknown
  }

  static func processState(forProcesses pids: [Int32]?) -> FinishProcessState {
    guard let pids, !pids.isEmpty else { return .unknown }
    let states = pids.map { processState(for: $0) }
    if states.contains(.running) { return .running }
    return states.allSatisfy { $0 == .stopped } ? .stopped : .unknown
  }

  static func resource(session: CLISession, provider: SessionProviderKind,
    repositories: [SelectedRepository], status: SessionStatus?, terminals: [FinishTerminalResource],
    name: String? = nil) -> FinishSessionResource {
    let evidence = terminals.filter { $0.key == session.id || $0.key == "shell:" + session.id }
    let processState: FinishProcessState
    if evidence.contains(where: { $0.processState == .running }) { processState = .running }
    else if evidence.isEmpty || evidence.contains(where: {
      $0.processState != .stopped || ($0.confirmedExitAt ?? $0.closedAt).map { session.lastActivityAt > $0 } == true
    }) { processState = .unknown }
    else { processState = .stopped }
    return FinishSessionResource(id: "\(provider.rawValue):\(session.id)", name: name ?? session.displayName,
      path: session.projectPath, branchName: session.branchName, isPending: false,
      isActive: session.isActive, status: status, processState: processState,
      repositoryPath: WorktreeModuleResolver.bestMatch(for: session.projectPath, repositories: repositories)?.repository.path,
      workflowID: AgentSessionWorkflowClassifier.ticketKey(in: [session.branchName, session.firstMessage, session.lastMessage]))
  }

  static func normalizedID(_ id: String) -> String {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return id }
    return parts[0].lowercased() + ":" + parts[1]
  }

  func terminalProtectionReasons(at root: String) -> [String] {
    terminals.compactMap { terminal in
      guard terminal.processState != .stopped else { return nil }
      guard let path = terminal.projectPath else { return "A terminal's project or process state is unknown." }
      let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
      guard normalized == root || normalized.hasPrefix(root + "/") else { return nil }
      return terminal.processState == .running ? "A managed terminal process is still running." : "A managed terminal process state is unknown."
    }
  }
}

enum WorkflowFinishRuntimePolicy {
  static func canArchive(workflowID: String, branches: [DetectedBranchWorkflow],
    inventory: FinishRuntimeInventory) -> Bool {
    guard inventory.isComplete, WorkflowFinishArchivePolicy.canArchive(branches) else { return false }
    let repositoryPaths = Set(branches.map { WorktreeModuleResolver.normalizedDirectoryPath($0.repositoryPath) })
    let assignments = branches.flatMap { $0.implementerSessions + $0.reviewerSessions }
    let knownIDs = Set(assignments.map { FinishRuntimeInventory.normalizedID($0.id) })
    let inventoryIDs = Set(inventory.sessions.map { FinishRuntimeInventory.normalizedID($0.id) })
    guard knownIDs.isSubset(of: inventoryIDs) else { return false }
    let branchNames = Set(branches.compactMap(\.branchName))
    for session in inventory.sessions {
      // Unknown associations cannot be used as evidence that a sibling is unrelated.
      guard let repositoryPath = session.repositoryPath else { return false }
      guard repositoryPaths.contains(WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)) else { continue }
      guard !session.isPending, !session.isActive, session.processState == .stopped,
        session.workflowID != nil else { return false }
      switch session.status {
      case nil, .idle?, .waitingForUser?: break
      case .thinking?, .executingTool?, .awaitingApproval?: return false
      }
      if session.workflowID == workflowID && !branchNames.contains(session.branchName ?? "") { return false }
    }
    for terminal in inventory.terminals where terminal.processState != .stopped {
      guard let path = terminal.projectPath else { return false }
      let normalized = WorktreeModuleResolver.normalizedDirectoryPath(path)
      let belongs = inventory.sessions.contains { session in
        guard let repo = session.repositoryPath else { return true }
        return repositoryPaths.contains(WorktreeModuleResolver.normalizedDirectoryPath(repo))
          && (normalized == session.path || normalized.hasPrefix(session.path + "/")
            || session.path.hasPrefix(normalized + "/"))
      }
      if belongs || repositoryPaths.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) { return false }
    }
    return true
  }
}
