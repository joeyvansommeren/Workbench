import Foundation

/// Approval binds this value, not the currently visible diff or terminal.
struct CommitChangeSnapshot: Identifiable, Equatable, Sendable {
  struct Entry: Identifiable, Equatable, Sendable {
    let path: String
    let originalPath: String?
    let status: String
    let mode: String
    let bytes: Data?
    let fileIdentity: String
    var id: String { path }
    var displayPath: String { path.debugDescription }
  }

  let id: UUID
  let sessionID: String
  let providerID: String
  let requestedPath: String
  let worktreePath: String
  let gitDirectory: String
  let commonDirectory: String
  let directoryIdentity: String
  let branchRef: String
  let head: String
  let index: Data
  let configuration: Data
  let entries: [Entry]
  let fingerprint: String
  var branch: String { String(branchRef.dropFirst("refs/heads/".count)) }
}

struct CommitChangesReceipt: Equatable, Sendable {
  let commitID: String
  let branch: String
  let paths: [String]
}

enum CommitChangesError: LocalizedError, Equatable {
  case unavailable(String)
  case stale
  case alreadyUsed
  case unconfirmed(commitID: String, recoveryPath: String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): return reason
    case .stale:
      return "The files or commit target changed. Close this review and review the changes again."
    case .alreadyUsed:
      return "This review has already been used. Review the current changes before another commit."
    case .unconfirmed(let commitID, let path):
      return
        "Commit \(commitID) may exist. Do not retry. Check Git history and the saved index at \(path)."
    }
  }
}
