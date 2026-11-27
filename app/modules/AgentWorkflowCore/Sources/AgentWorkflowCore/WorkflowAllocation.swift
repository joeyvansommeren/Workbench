import Foundation

/// Allocation only. Implementations must not launch agents or perform Git/tracker actions.
public protocol WorkflowAllocationStoring: Sendable {
  func ensureWorkflowAllocation(_ request: WorkflowAllocationRequest) async throws
    -> WorkflowAllocation
}

/// Immutable creation input. The caller verifies source access, repository mapping and base commit.
/// Provider IDs can be stored without asserting that a supported launch adapter exists.
public struct WorkflowAllocationRequest: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let runID: UUID
  public let itemID: UUID
  public let issue: OrchestratorIssueIdentity
  public let ticketRunID: UUID
  public let branchRunID: UUID
  public let ticketCreatedEventID: UUID
  public let branchCreatedEventID: UUID
  public let ticketKey: String
  public let repositoryPath: String
  public let worktreePath: String
  public let branchName: String
  public let baseBranch: String
  public let baseCommitID: String
  public let coordinatorProvider: AgentProviderID
  public let implementerProvider: AgentProviderID
  public let reviewerProvider: AgentProviderID
  public let createdAt: Date

  public init(
    operationID: UUID, runID: UUID, itemID: UUID, issue: OrchestratorIssueIdentity,
    ticketRunID: UUID, branchRunID: UUID, ticketCreatedEventID: UUID, branchCreatedEventID: UUID,
    ticketKey: String, repositoryPath: String, worktreePath: String, branchName: String,
    baseBranch: String, baseCommitID: String, coordinatorProvider: AgentProviderID,
    implementerProvider: AgentProviderID, reviewerProvider: AgentProviderID, createdAt: Date
  ) throws {
    for (field, value) in [
      ("ticketKey", ticketKey), ("repositoryPath", repositoryPath), ("worktreePath", worktreePath),
      ("branchName", branchName), ("baseBranch", baseBranch), ("baseCommitID", baseCommitID),
      ("coordinatorProvider", coordinatorProvider.rawValue),
      ("implementerProvider", implementerProvider.rawValue),
      ("reviewerProvider", reviewerProvider.rawValue),
    ] {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.utf8.contains(0)
      else {
        throw WorkflowAllocationError.invalidField(field)
      }
    }
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WorkflowAllocationError.invalidField("createdAt")
    }
    guard ticketCreatedEventID != branchCreatedEventID else {
      throw WorkflowAllocationError.duplicateCreationEventIDs
    }
    self.operationID = operationID
    self.runID = runID
    self.itemID = itemID
    self.issue = issue
    self.ticketRunID = ticketRunID
    self.branchRunID = branchRunID
    self.ticketCreatedEventID = ticketCreatedEventID
    self.branchCreatedEventID = branchCreatedEventID
    self.ticketKey = ticketKey
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branchName = branchName
    self.baseBranch = baseBranch
    self.baseCommitID = baseCommitID
    self.coordinatorProvider = coordinatorProvider
    self.implementerProvider = implementerProvider
    self.reviewerProvider = reviewerProvider
    self.createdAt = createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      operationID: values.decode(UUID.self, forKey: .operationID),
      runID: values.decode(UUID.self, forKey: .runID),
      itemID: values.decode(UUID.self, forKey: .itemID),
      issue: values.decode(OrchestratorIssueIdentity.self, forKey: .issue),
      ticketRunID: values.decode(UUID.self, forKey: .ticketRunID),
      branchRunID: values.decode(UUID.self, forKey: .branchRunID),
      ticketCreatedEventID: values.decode(UUID.self, forKey: .ticketCreatedEventID),
      branchCreatedEventID: values.decode(UUID.self, forKey: .branchCreatedEventID),
      ticketKey: values.decode(String.self, forKey: .ticketKey),
      repositoryPath: values.decode(String.self, forKey: .repositoryPath),
      worktreePath: values.decode(String.self, forKey: .worktreePath),
      branchName: values.decode(String.self, forKey: .branchName),
      baseBranch: values.decode(String.self, forKey: .baseBranch),
      baseCommitID: values.decode(String.self, forKey: .baseCommitID),
      coordinatorProvider: values.decode(AgentProviderID.self, forKey: .coordinatorProvider),
      implementerProvider: values.decode(AgentProviderID.self, forKey: .implementerProvider),
      reviewerProvider: values.decode(AgentProviderID.self, forKey: .reviewerProvider),
      createdAt: values.decode(Date.self, forKey: .createdAt))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identityBytes == rhs.identityBytes
  }

  /// Length framing preserves opaque UTF-8 values and field boundaries across restarts.
  /// These are identity/routing fields only, never prompts, descriptions or credentials.
  internal var identityBytes: Data {
    var result = Data()
    for value in [
      "WorkflowAllocationRequest:1", operationID.uuidString, runID.uuidString, itemID.uuidString,
      issue.source.trackerID, issue.source.accountID, issue.source.scopeID, issue.issueID,
      ticketRunID.uuidString, branchRunID.uuidString, ticketCreatedEventID.uuidString,
      branchCreatedEventID.uuidString, ticketKey, repositoryPath, worktreePath, branchName,
      baseBranch, baseCommitID, coordinatorProvider.rawValue, implementerProvider.rawValue,
      reviewerProvider.rawValue,
    ] {
      let bytes = Data(value.utf8)
      var length = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
      result.append(bytes)
    }
    var time = createdAt.timeIntervalSinceReferenceDate.bitPattern.bigEndian
    withUnsafeBytes(of: &time) { result.append(contentsOf: $0) }
    return result
  }
}

/// The owning store issues this receipt only after validating the durable allocation.
public struct WorkflowAllocationReceipt: Equatable, Sendable {
  public let request: WorkflowAllocationRequest
}

/// Current workflow values are separate from the immutable creation receipt.
public struct WorkflowAllocation: Equatable, Sendable {
  public let receipt: WorkflowAllocationReceipt
  public let ticketRun: TicketRun
  public let branchRun: BranchRun
}

public enum WorkflowAllocationError: Error, Equatable, Sendable {
  case invalidField(String)
  case duplicateCreationEventIDs
  case operationConflict(UUID)
  case operationOwnedByAnotherAllocation(UUID)
  case identityCollision(String)
  case corruptReceipt(UUID)
}
