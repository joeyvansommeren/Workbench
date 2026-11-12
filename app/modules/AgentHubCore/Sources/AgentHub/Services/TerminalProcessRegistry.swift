//
//  TerminalProcessRegistry.swift
//  AgentHub
//
//  Tracks app-spawned process identities so crash recovery can clean them up
//  without relying on UserDefaults or killing unrelated PID-reused processes.
//

import Darwin
import Foundation

struct ManagedProcessIdentity: Equatable, Sendable {
  let pid: pid_t
  let processGroupId: pid_t
  let startTimeSeconds: Int64
  let commandLine: String?
}

protocol ProcessInspecting: Sendable {
  func identity(for pid: pid_t) async -> ManagedProcessIdentity?
}

protocol ProcessTerminating: Sendable {
  func terminate(pid: pid_t, processGroupId: pid_t?) async
}

struct DarwinProcessInspector: ProcessInspecting {
  func identity(for pid: pid_t) async -> ManagedProcessIdentity? {
    guard pid > 0, kill(pid, 0) == 0 else { return nil }
    guard let bsdInfo = bsdInfo(for: pid) else { return nil }

    return ManagedProcessIdentity(
      pid: pid,
      processGroupId: pid_t(bsdInfo.pbi_pgid),
      startTimeSeconds: Int64(bsdInfo.pbi_start_tvsec),
      commandLine: commandLine(for: pid)
    )
  }

  private func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let result = withUnsafeMutableBytes(of: &info) { buffer in
      proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        buffer.baseAddress,
        Int32(buffer.count)
      )
    }

    guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else {
      return nil
    }
    return info
  }

  private func commandLine(for pid: pid_t) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "command="]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
      try task.run()
      // Read to EOF before waiting: output larger than the 64KB pipe buffer
      // otherwise deadlocks the child against waitUntilExit().
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      let command = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return command?.isEmpty == false ? command : nil
    } catch {
      return nil
    }
  }
}

struct DarwinProcessTerminator: ProcessTerminating {
  func terminate(pid: pid_t, processGroupId: pid_t?) async {
    guard pid > 0 else { return }
    let tree = ProcessTree.sendTerminate(root: pid)
    try? await Task.sleep(for: .milliseconds(300))
    ProcessTree.killSurvivors(tree, root: pid)
    try? await Task.sleep(for: .milliseconds(100))
  }
}

/// Stops a process and everything below it. Codex starts each MCP server in
/// its own process group, so killpg on the agent alone left them running.
enum ProcessTree {
  struct Identity: Equatable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
  }

  static func identity(for pid: pid_t) -> Identity? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
    return Identity(pid: pid, startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec)
  }

  /// `root` first, then every descendant, breadth first.
  static func pids(under root: pid_t) -> [pid_t] {
    var result = [root]
    var index = 0
    while index < result.count {
      result += children(of: result[index])
      index += 1
    }
    return result
  }

  private static func children(of pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 512)
    let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    return buffer.prefix(Int(count)).filter { $0 > 0 }
  }

  /// SIGTERM to the tree. Returns identities so survivors can be killed later,
  /// even after the root (and the view that owned it) is gone.
  @discardableResult
  static func sendTerminate(root: pid_t) -> [Identity] {
    guard root > 1 else { return [] }
    let tree = pids(under: root).compactMap { identity(for: $0) }
    for process in tree where identity(for: process.pid) == process {
      _ = kill(process.pid, SIGTERM)
    }
    return tree
  }

  static func killSurvivors(_ tree: [Identity], root: pid_t) {
    let alive = tree.filter { identity(for: $0.pid) == $0 }
    guard !alive.isEmpty else { return }
    AppLogger.session.warning("Process tree PID=\(root) still has \(alive.count) live processes; sending SIGKILL")
    for process in alive where identity(for: process.pid) == process {
      _ = kill(process.pid, SIGKILL)
    }
  }
}

public actor TerminalProcessRegistry {
  public static let shared = TerminalProcessRegistry()

  private enum CleanupScope {
    case allRegistered
    case orphanedTerminals(provider: SessionProviderKind?, activePIDs: Set<Int32>)
    case sessionTerminals(provider: SessionProviderKind, keys: Set<String>)
  }

  private let processInspector: any ProcessInspecting
  private let processTerminator: any ProcessTerminating
  private var processStore: (any ManagedProcessStoreProtocol)?
  private var didAttemptDefaultStore = false
  private var unregisterRequests: [pid_t: Date] = [:]

  init(
    store: (any ManagedProcessStoreProtocol)? = nil,
    processInspector: any ProcessInspecting = DarwinProcessInspector(),
    processTerminator: any ProcessTerminating = DarwinProcessTerminator()
  ) {
    self.processStore = store
    self.processInspector = processInspector
    self.processTerminator = processTerminator
    self.didAttemptDefaultStore = store != nil
  }

  public func configure(store: (any ManagedProcessStoreProtocol)?) {
    processStore = store
    didAttemptDefaultStore = store != nil
  }

  public func register(
    pid: pid_t,
    kind: ManagedProcessKind = .agentTerminal,
    provider: SessionProviderKind? = nil,
    terminalKey: String? = nil,
    sessionId: String? = nil,
    projectPath: String? = nil,
    expectedExecutable: String? = nil,
    requestedAt: Date = Date.now
  ) async {
    guard pid > 0 else { return }
    guard !shouldIgnoreRegistration(pid: pid, requestedAt: requestedAt) else { return }
    guard let identity = await processInspector.identity(for: pid) else {
      await deleteManagedProcess(pid: pid)
      return
    }
    guard !shouldIgnoreRegistration(pid: pid, requestedAt: requestedAt) else { return }
    guard let store = await resolvedProcessStore() else { return }

    let record = ManagedProcessRecord(
      pid: pid,
      processGroupId: ownedProcessGroupId(for: identity),
      processStartTimeSeconds: identity.startTimeSeconds,
      kind: kind,
      provider: provider?.rawValue,
      terminalKey: normalized(terminalKey),
      sessionId: normalized(sessionId),
      projectPath: normalized(projectPath),
      expectedExecutable: normalized(expectedExecutable),
      registeredAt: requestedAt,
      updatedAt: Date.now
    )

    do {
      try await store.saveManagedProcess(record)
    } catch {
      AppLogger.session.error("Failed to persist managed process PID=\(pid): \(error.localizedDescription)")
    }
  }

  public func unregister(pid: pid_t, requestedAt: Date = Date.now) async {
    guard pid > 0 else { return }
    unregisterRequests[pid] = requestedAt
    pruneOldUnregisterRequests(relativeTo: requestedAt)
    await deleteManagedProcess(pid: pid)
  }

  /// Returns live terminal PIDs still owned by AgentHub. Dev-server rows are
  /// intentionally excluded because this count backs the terminal orphan UI.
  public func getAliveRegisteredPIDs(provider: SessionProviderKind? = nil) async -> Set<Int32> {
    guard let store = await resolvedProcessStore() else { return [] }

    do {
      let rows = try await store.getManagedProcesses()
      var stalePIDs: [Int32] = []
      var alivePIDs: Set<Int32> = []

      for row in rows where row.processKind?.isTerminalProcess == true
        && matchesProvider(row, provider: provider) {
        guard let identity = await processInspector.identity(for: row.pid) else {
          stalePIDs.append(row.pid)
          continue
        }
        guard matchesStoredIdentity(row, identity: identity) else {
          stalePIDs.append(row.pid)
          continue
        }
        alivePIDs.insert(row.pid)
      }

      try await store.deleteManagedProcesses(pids: stalePIDs)
      return alivePIDs
    } catch {
      AppLogger.session.error("Failed to load managed process rows: \(error.localizedDescription)")
      return []
    }
  }

  /// Terminates every live process still matching its persisted app-spawned
  /// identity, and prunes stale rows without killing PID-reused processes.
  public func cleanupRegisteredProcesses() async {
    await cleanupManagedProcesses(scope: .allRegistered)
  }

  /// Terminates terminal rows that are live, provider-scoped, and no longer
  /// attached to active UI terminals. Dev servers and active terminal rows are
  /// intentionally left alone because this backs the menu-bar orphan action.
  public func cleanupOrphanedTerminalProcesses(
    provider: SessionProviderKind? = nil,
    activePIDs: Set<Int32>
  ) async {
    await cleanupManagedProcesses(
      scope: .orphanedTerminals(provider: provider, activePIDs: activePIDs)
    )
  }

  /// Terminates every terminal process registered for one session. Archive's
  /// safety net: a terminal that never mounted (e.g. a bulk-launched review) can
  /// outlive the UI terminal map; its registered row still identifies it.
  /// `keys` holds the session id plus any pending keys it launched under. A row
  /// matches on its session id or on its terminal key, so tabs (child agents)
  /// inside the session's terminal stop too.
  public func terminateSessionTerminalProcesses(provider: SessionProviderKind, keys: Set<String>) async {
    await cleanupManagedProcesses(scope: .sessionTerminals(provider: provider, keys: keys))
  }

  /// A pending launch got its real session id: file its rows under it, so a
  /// later archive (also after a restart) still finds them.
  public func rekey(from oldKey: String, to newKey: String) async {
    guard let store = await resolvedProcessStore() else { return }
    do {
      for var row in try await store.getManagedProcesses()
      where row.terminalKey == oldKey || row.sessionId == oldKey {
        if row.terminalKey == oldKey { row.terminalKey = newKey }
        if row.sessionId == oldKey { row.sessionId = newKey }
        row.updatedAt = Date.now
        try await store.saveManagedProcess(row)
      }
    } catch {
      AppLogger.session.error("Failed to rekey managed processes: \(error.localizedDescription)")
    }
  }

  private func cleanupManagedProcesses(scope: CleanupScope) async {
    guard let store = await resolvedProcessStore() else { return }

    do {
      let rows = try await store.getManagedProcesses()
      guard !rows.isEmpty else { return }

      var completedPIDs: [Int32] = []
      for row in rows where shouldCleanup(row, scope: scope) {
        guard row.processKind != nil else {
          completedPIDs.append(row.pid)
          continue
        }

        guard let identity = await processInspector.identity(for: row.pid) else {
          completedPIDs.append(row.pid)
          continue
        }

        guard matchesStoredIdentity(row, identity: identity) else {
          completedPIDs.append(row.pid)
          continue
        }

        await processTerminator.terminate(
          pid: row.pid,
          processGroupId: ownedProcessGroupId(for: row, identity: identity)
        )
        completedPIDs.append(row.pid)
      }

      try await store.deleteManagedProcesses(pids: completedPIDs)
    } catch {
      AppLogger.session.error("Failed to clean up managed processes: \(error.localizedDescription)")
    }
  }

  private func shouldCleanup(_ row: ManagedProcessRecord, scope: CleanupScope) -> Bool {
    switch scope {
    case .allRegistered:
      return true
    case .orphanedTerminals(let provider, let activePIDs):
      guard row.processKind?.isTerminalProcess == true else { return false }
      guard matchesProvider(row, provider: provider) else { return false }
      return !activePIDs.contains(row.pid)
    case .sessionTerminals(let provider, let keys):
      guard row.processKind?.isTerminalProcess == true else { return false }
      // Child-agent tabs can run another provider inside this session's terminal.
      if let terminalKey = row.terminalKey, keys.contains(terminalKey) { return true }
      guard matchesProvider(row, provider: provider) else { return false }
      return row.sessionId.map(keys.contains) ?? false
    }
  }

  private func resolvedProcessStore() async -> (any ManagedProcessStoreProtocol)? {
    if let processStore {
      return processStore
    }

    guard !didAttemptDefaultStore else { return nil }
    didAttemptDefaultStore = true

    do {
      let store = try SessionMetadataStore()
      processStore = store
      return store
    } catch {
      AppLogger.session.error("Failed to create managed process store: \(error.localizedDescription)")
      return nil
    }
  }

  private func deleteManagedProcess(pid: pid_t) async {
    guard let store = await resolvedProcessStore() else { return }
    do {
      try await store.deleteManagedProcess(pid: pid)
    } catch {
      AppLogger.session.error("Failed to delete managed process PID=\(pid): \(error.localizedDescription)")
    }
  }

  private func matchesStoredIdentity(
    _ row: ManagedProcessRecord,
    identity: ManagedProcessIdentity
  ) -> Bool {
    guard let storedStartTime = row.processStartTimeSeconds else {
      return false
    }
    guard storedStartTime == identity.startTimeSeconds else {
      return false
    }

    if let storedGroupId = row.processGroupId, storedGroupId > 0 {
      return storedGroupId == identity.processGroupId
    }
    return true
  }

  private func shouldIgnoreRegistration(pid: pid_t, requestedAt: Date) -> Bool {
    guard let unregisterDate = unregisterRequests[pid] else { return false }
    return requestedAt <= unregisterDate
  }

  private func pruneOldUnregisterRequests(relativeTo now: Date) {
    guard unregisterRequests.count > 128 else { return }
    unregisterRequests = unregisterRequests.filter { _, date in
      now.timeIntervalSince(date) < 60
    }
  }

  private func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private func matchesProvider(_ row: ManagedProcessRecord, provider: SessionProviderKind?) -> Bool {
    guard let provider else { return true }
    return row.provider == provider.rawValue
  }

  private func ownedProcessGroupId(for identity: ManagedProcessIdentity) -> pid_t? {
    guard identity.processGroupId > 0, identity.processGroupId == identity.pid else {
      return nil
    }
    return identity.processGroupId
  }

  private func ownedProcessGroupId(
    for row: ManagedProcessRecord,
    identity: ManagedProcessIdentity
  ) -> pid_t? {
    guard row.processGroupId == identity.processGroupId else {
      return nil
    }
    return ownedProcessGroupId(for: identity)
  }
}
