import AgentHubGitHub
import Foundation
import GRDB
import Observation

extension SessionMetadataStore: PullRequestPublicationStoring {
  func pullRequestPublication(for key: PullRequestPublicationKey) async throws -> PullRequestPublicationRecord? {
    try await dbQueue.read { db in
      guard let row = try Row.fetchOne(
        db, sql: """
          SELECT id, baseBranch, baseOID, head, sessionID, provider, phase FROM pull_request_publications
          WHERE host = ? AND owner = ? AND repository = ? AND branch = ?
          """, arguments: [key.host, key.owner, key.repository, key.branch])
      else { return nil }
      guard let id = UUID(uuidString: row["id"]),
        let phase = PullRequestPublicationRecord.Phase(rawValue: row["phase"])
      else { throw PullRequestPublicationError.unchangedPending }
      return PullRequestPublicationRecord(
        id: id, key: key, base: row["baseBranch"], baseOID: row["baseOID"], head: row["head"],
        sessionID: row["sessionID"],
        provider: row["provider"], phase: phase)
    }
  }

  func pullRequestPublicationRepository(for context: PullRequestContext) async throws -> GitHubRepositoryIdentity? {
    guard let branch = context.branch else { return nil }
    return try await dbQueue.read { db in
      let rows = try Row.fetchAll(db, sql: """
        SELECT host, owner, repository FROM pull_request_publications
        WHERE sessionID = ? AND provider = ? AND branch = ?
        """, arguments: [context.sessionID, context.provider.rawValue, branch])
      guard rows.count <= 1 else { throw PullRequestPublicationError.unchangedPending }
      return rows.first.map { row in
        GitHubRepositoryIdentity(owner: row["owner"], repository: row["repository"], host: row["host"])
      }
    }
  }

  func beginPullRequestPublication(_ record: PullRequestPublicationRecord) async throws -> Bool {
    try await dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO pull_request_publications
            (id, host, owner, repository, branch, baseBranch, baseOID, head, sessionID, provider, phase)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(host, owner, repository, branch) DO NOTHING
          """, arguments: [
            record.id.uuidString, record.key.host, record.key.owner, record.key.repository,
            record.key.branch, record.base, record.baseOID, record.head, record.sessionID, record.provider,
            record.phase.rawValue,
          ])
      return db.changesCount == 1
    }
  }

  func advancePullRequestPublication(
    id: UUID, from: PullRequestPublicationRecord.Phase, to: PullRequestPublicationRecord.Phase
  ) async throws -> Bool {
    try await dbQueue.write { db in
      try db.execute(
        sql: "UPDATE pull_request_publications SET phase = ? WHERE id = ? AND phase = ?",
        arguments: [to.rawValue, id.uuidString, from.rawValue])
      return db.changesCount == 1
    }
  }

  func abandonPullRequestPush(id: UUID) async throws {
    try await dbQueue.write { db in
      try db.execute(
        sql: "DELETE FROM pull_request_publications WHERE id = ? AND phase = 'pushing'",
        arguments: [id.uuidString])
    }
  }
}

@MainActor
@Observable
final class PullRequestPublicationStatus {
  private struct Entry: Hashable, Sendable {
    let key: PullRequestPublicationKey
    let sessionID: String
    let provider: String
  }

  private var pending: Set<Entry> = []
  @ObservationIgnored private var task: Task<Void, Never>?

  init(store: SessionMetadataStore?) {
    guard let queue = store?.dbQueue else { return }
    task = Task { [weak self] in
      let observation = ValueObservation.tracking { db in
        try Row.fetchAll(db, sql: """
          SELECT host, owner, repository, branch, sessionID, provider
          FROM pull_request_publications WHERE phase = 'handedOff'
          """).map { row in
            Entry(key: .init(
              host: row["host"], owner: row["owner"], repository: row["repository"], branch: row["branch"]),
              sessionID: row["sessionID"], provider: row["provider"])
          }
      }
      do {
        for try await keys in observation.values(in: queue, bufferingPolicy: .bufferingNewest(1)) {
          self?.pending = Set(keys)
        }
      } catch {
        // The review sheet still performs a fresh durable read before any action.
      }
    }
  }

  deinit { task?.cancel() }

  func awaitsGitHub(
    repository: GitHubRepositoryIdentity?, branch: String?, sessionID: String, provider: SessionProviderKind
  ) -> Bool {
    guard let branch else { return false }
    if let repository {
      let key = PullRequestPublicationKey(
        host: repository.host, owner: repository.owner.lowercased(),
        repository: repository.repository.lowercased(), branch: branch)
      return pending.contains { $0.key == key }
    }
    return pending.contains {
      $0.sessionID == sessionID && $0.provider == provider.rawValue && $0.key.branch.utf8.elementsEqual(branch.utf8)
    }
  }
}
