import Darwin
import Foundation

/// Captured when the terminal launches, before any asynchronous file inspection.
public struct PendingSessionProcessIdentity: Equatable, Sendable {
  public let processID: Int32
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64

  static func capture(processID: Int32, parentProcessID: Int32? = nil) -> Self? {
    guard processID > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
      parentProcessID == nil || Int32(info.pbi_ppid) == parentProcessID
    else { return nil }
    return Self(
      processID: processID, startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec)
  }
}

/// A read handle or a tool child cannot establish ownership of a launch.
public protocol PendingSessionFileOwning: Sendable {
  func ownedFiles(in candidates: Set<String>, process: PendingSessionProcessIdentity) async -> Set<
    String
  >
}

public actor PendingSessionFileOwnership: PendingSessionFileOwning {
  public init() {}

  public func ownedFiles(in candidates: Set<String>, process: PendingSessionProcessIdentity) -> Set<
    String
  > {
    guard !candidates.isEmpty,
      PendingSessionProcessIdentity.capture(processID: process.processID) == process
    else { return [] }
    let canonical = Dictionary(
      candidates.map { (normalized($0), $0) }, uniquingKeysWith: { first, _ in first })
    // The embedded launch command uses exec. Descendant handles belong to tools,
    // wrappers or child agents and cannot identify the originating interactive session.
    let matches = Set(
      writablePaths(processID: process.processID).compactMap { canonical[normalized($0)] })
    return PendingSessionProcessIdentity.capture(processID: process.processID) == process
      ? matches : []
  }

  private func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func writablePaths(processID: Int32) -> [String] {
    let byteCount = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    let stride = MemoryLayout<proc_fdinfo>.stride
    guard byteCount > 0, byteCount / Int32(stride) < 4096 else { return [] }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / stride + 16)
    let received = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(processID, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    // A truncated descriptor list cannot prove that a candidate is unique.
    guard received > 0, Int(received) < descriptors.count * stride else { return [] }
    return descriptors.prefix(Int(received) / stride).compactMap { descriptor in
      guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
      var info = vnode_fdinfowithpath()
      let size = MemoryLayout<vnode_fdinfowithpath>.size
      guard
        proc_pidfdinfo(processID, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(size))
          == size,
        info.pfi.fi_openflags & UInt32(FWRITE) != 0
      else { return nil }
      return withUnsafePointer(to: &info.pvip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
    }
  }
}
