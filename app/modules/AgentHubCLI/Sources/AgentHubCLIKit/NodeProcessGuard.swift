import Darwin
import Foundation
import os

struct GuardProcess: Equatable, Sendable {
  struct Identity: Hashable, Sendable {
    let pid: Int32
    let started: UInt64
  }

  let identity: Identity
  let parent: Int32
  let name: String
  let bytes: UInt64
  var isNode: Bool { name == "node" || name == "nodejs" }
}

/// Tracks only descendants observed under this app, retaining identity after reparenting.
struct NodeProcessPolicy {
  let app: GuardProcess.Identity
  let guardian: Int32
  var maximumCount = 256
  var maximumProcessBytes: UInt64 = 4 * 1024 * 1024 * 1024
  var maximumTotalBytes: UInt64 = 16 * 1024 * 1024 * 1024
  private(set) var owned: [GuardProcess.Identity: GuardProcess.Identity] = [:]

  mutating func update(_ processes: [GuardProcess]) -> (targets: [GuardProcess], limited: Bool, reason: String) {
    let live = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity, $0) })
    owned = owned.filter { live[$0.key] != nil }
    let appAlive = live[app] != nil
    do {
      var roots = Dictionary(uniqueKeysWithValues: owned.map { ($0.key.pid, $0.value) })
      var changed = true
      while changed {
        changed = false
        for process in processes where process.identity.pid != guardian && roots[process.identity.pid] == nil {
          if appAlive && process.parent == app.pid {
            roots[process.identity.pid] = process.identity
          } else if let root = roots[process.parent] {
            roots[process.identity.pid] = root
          } else {
            continue
          }
          owned[process.identity] = roots[process.identity.pid]
          changed = true
        }
      }
    }

    var targets = Set(owned.compactMap { identity, root in
      !appAlive || live[root] == nil ? identity : nil
    })
    let nodes = processes.filter { $0.isNode && owned[$0.identity] != nil && !targets.contains($0.identity) }
    let totalBytes = nodes.reduce(UInt64(0)) { $0 + $1.bytes }
    let largestBytes = nodes.map(\.bytes).max() ?? 0
    var reasons: [String] = []
    if nodes.count > maximumCount { reasons.append("\(nodes.count) Node processes (limit \(maximumCount))") }
    if largestBytes > maximumProcessBytes {
      reasons.append("one process uses \(largestBytes / 1_048_576) MiB (limit \(maximumProcessBytes / 1_048_576) MiB)")
    }
    if totalBytes > maximumTotalBytes {
      reasons.append("\(totalBytes / 1_048_576) MiB combined (limit \(maximumTotalBytes / 1_048_576) MiB)")
    }
    for node in nodes where node.bytes > maximumProcessBytes { targets.insert(node.identity) }
    // Stop the largest consumers first; newest wins ties so established tools survive.
    let ordered = nodes.sorted {
      $0.bytes == $1.bytes ? $0.identity.started > $1.identity.started : $0.bytes > $1.bytes
    }
    var count = nodes.filter { !targets.contains($0.identity) }.count
    var total = nodes.filter { !targets.contains($0.identity) }.reduce(UInt64(0)) { $0 + $1.bytes }
    for node in ordered where !targets.contains(node.identity) {
      guard count > maximumCount || total > maximumTotalBytes else { break }
      targets.insert(node.identity)
      count -= 1
      total -= node.bytes
    }
    let limited = nodes.contains { targets.contains($0.identity) }
    // Include children even when they have moved to separate process groups.
    var changed = true
    while changed {
      changed = false
      let parents = Set(targets.map(\.pid))
      for process in processes where owned[process.identity] != nil && parents.contains(process.parent) {
        if targets.insert(process.identity).inserted { changed = true }
      }
    }
    return (processes.filter { targets.contains($0.identity) }, limited, reasons.joined(separator: "; "))
  }
}

public enum NodeProcessGuard {
  private static let logger = Logger(subsystem: "com.agenthub", category: "ProcessGuard")

  /// Runs in the bundled helper so a blocked UI or force quit cannot stop cleanup.
  public static func run(parentPID: Int32) async throws {
    guard parentPID > 1, parentPID == getppid(), let app = read(parentPID) else {
      throw POSIXError(.EINVAL)
    }
    var policy = NodeProcessPolicy(app: app.identity, guardian: getpid())
    // Leave room for the OS and other applications on smaller machines.
    policy.maximumTotalBytes = min(policy.maximumTotalBytes, ProcessInfo.processInfo.physicalMemory / 3)
    var pending: [GuardProcess.Identity: ContinuousClock.Instant] = [:]
    let clock = ContinuousClock()
    report("ready")
    while true {
      let processes = snapshot()
      guard !processes.isEmpty else { throw POSIXError(.EIO) }
      let decision = policy.update(processes)
      let fresh = decision.targets.filter { pending[$0.identity] == nil }
      if decision.limited && !fresh.isEmpty {
        let message = "Process protection stopped \(fresh.count) process(es): \(decision.reason). Affected tools may need restarting."
        logger.error("\(message, privacy: .public)")
        report(message)
      }
      for process in fresh {
        signal(process.identity, SIGTERM)
        pending[process.identity] = clock.now
      }
      for (identity, sent) in pending {
        guard read(identity.pid)?.identity == identity else {
          pending.removeValue(forKey: identity)
          continue
        }
        if clock.now - sent >= .seconds(1) {
          signal(identity, SIGKILL)
        }
      }
      if read(parentPID)?.identity != app.identity && policy.owned.isEmpty && pending.isEmpty { return }
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  private static func report(_ message: String) {
    // The app may already be gone. Never let a closed reporting pipe kill the guard.
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
  }

  static func signal(_ identity: GuardProcess.Identity, _ value: Int32) {
    guard read(identity.pid)?.identity == identity else { return }
    _ = kill(identity.pid, value)
  }

  static func snapshot() -> [GuardProcess] {
    let capacity = Int(proc_listallpids(nil, 0)) + 256
    guard capacity > 256 else { return [] }
    var pids = [Int32](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return pids.prefix(max(0, min(Int(count), capacity))).compactMap { read($0) }
  }

  static func read(_ pid: Int32) -> GuardProcess? {
    guard pid > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
          info.pbi_uid == getuid(), info.pbi_status != UInt32(SZOMB) else { return nil }
    var name = [CChar](repeating: 0, count: 1024)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    // Node can change its process title; classify the executable, not that title.
    let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0
      ? (String(cString: path) as NSString).lastPathComponent : String(cString: name)
    var usage = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
      }
    }
    return GuardProcess(
      identity: .init(pid: pid, started: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec),
      parent: Int32(info.pbi_ppid), name: executable,
      bytes: result == 0 ? usage.ri_phys_footprint : 0)
  }
}
