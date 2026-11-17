import Foundation
import GRDB

/// A snapshot of the source at launch. Later tracker edits never change session identity.
public struct SessionLaunchOrigin: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable { case linear, jira, pullRequest }
  public let source: Source
  public let accountID: String
  public let sourceID: String
  public let key: String
  public let title: String

  public init(source: Source, accountID: String, sourceID: String, key: String, title: String) {
    self.source = source
    self.accountID = accountID
    self.sourceID = sourceID
    self.key = key
    self.title = title
  }

  public var displayName: String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? key : "\(key) \(title)"
  }
}

/// Routing and provenance only. Prompts, terminal contents and credentials are not stored here.
struct SessionLaunchOriginRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
  static let databaseTableName = "session_launch_origins"
  let pendingID: String
  let provider: String
  var sessionID: String?
  var payload: Data

  struct Launch: Codable, Sendable {
    let origin: SessionLaunchOrigin
    let worktree: WorktreeBranch
    let launchPath: String?
    let startedAt: Date
    let expectedSessionID: String?
    let existingSessionIdentifiers: Set<String>
    var needsIdentification: Bool
    var failed: Bool
  }

  init(pending: PendingHubSession, provider: SessionProviderKind) throws {
    guard let origin = pending.origin else { throw SessionMetadataStore.LaunchOriginError.missing }
    pendingID = pending.id.uuidString
    self.provider = provider.rawValue
    sessionID = nil
    let worktree = WorktreeBranch(
      name: pending.worktree.name, path: pending.worktree.path,
      isWorktree: pending.worktree.isWorktree)
    payload = try JSONEncoder().encode(
      Launch(
        origin: origin, worktree: worktree, launchPath: pending.launchPath,
        startedAt: pending.startedAt, expectedSessionID: pending.expectedSessionID,
        existingSessionIdentifiers: pending.existingSessionIdentifiers,
        needsIdentification: pending.needsIdentification, failed: pending.isFailed))
  }

  func launch() throws -> Launch { try JSONDecoder().decode(Launch.self, from: payload) }
}

protocol SessionLaunchOriginStoring: Sendable {
  func saveLaunchOrigin(_ record: SessionLaunchOriginRecord) throws
  func launchOrigins(provider: SessionProviderKind) throws -> [SessionLaunchOriginRecord]
  func resolveLaunchOrigin(pendingID: UUID, provider: SessionProviderKind, sessionID: String) throws
  func updateLaunchOrigin(pendingID: UUID, failed: Bool, needsIdentification: Bool) throws
  func removeLaunchOrigin(pendingID: UUID) throws
}
