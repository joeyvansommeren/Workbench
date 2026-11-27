import Foundation

/// Session metadata owns the queue and allocation journal. A store records intent before
/// the workflow database creates its ticket and branch records.
public protocol OrchestratorMetadataStoring: Sendable {
  func createOrchestratorRun(_ run: OrchestratorRun) async throws
  func orchestratorRuns() async throws -> [OrchestratorRun]
  func recordOrchestratorThread(_ thread: OrchestratorThread) async throws
  func orchestratorThreads(runID: UUID) async throws -> [OrchestratorThread]
  func bindOrchestratorThread(
    id: UUID, pendingLaunchID: UUID, session: OrchestratorSessionIdentity
  ) async throws
  func closeOrchestratorThread(id: UUID, reason: OrchestratorThreadCloseReason) async throws
  func orchestratorRun(id: UUID) async throws -> OrchestratorRun?
  func orchestratorItems(runID: UUID) async throws -> [OrchestratorQueueItem]
  func applyOrchestratorEvent(_ event: OrchestratorRunEvent) async throws
    -> OrchestratorTransitionResult
  func applyOrchestratorEvent(_ event: OrchestratorItemEvent) async throws
    -> OrchestratorTransitionResult
  func reserveWorkflowAllocation(_ request: WorkflowAllocationRequest) async throws
  func pendingWorkflowAllocations() async throws -> [PendingWorkflowAllocation]
  func acknowledgedWorkflowAllocation(runID: UUID, itemID: UUID) async throws
    -> WorkflowAllocationRequest?
  func completeWorkflowAllocation(_ receipt: WorkflowAllocationReceipt) async throws
  func rejectWorkflowAllocation(_ request: WorkflowAllocationRequest) async throws
}

public enum OrchestratorMetadataError: Error, Equatable, Sendable {
  case runConflict(UUID)
  case missingRun(UUID)
  case missingItem(UUID)
  case issueAlreadyClaimed(OrchestratorIssueIdentity)
  case allocationConflict(UUID)
  case missingAllocation(UUID)
  case allocationPending(UUID)
  case allocationRejected(UUID)
  case providerPolicyMismatch(UUID)
}

public enum PendingWorkflowAllocation: Equatable, Sendable {
  case request(WorkflowAllocationRequest)
  case unreadable(operationID: UUID?)
}

public struct WorkflowAllocationRecoveryFailure: Equatable, Sendable {
  public let operationID: UUID?
  public let disposition: Disposition

  public enum Disposition: Equatable, Sendable {
    case rejected
    case pending
    case unreadable
  }
}

/// Recovery replays the same allocation identity. It never launches a process or
/// treats a partial write as proof of launch, review, or completion.
public actor OrchestratorAllocationCoordinator {
  private let metadata: any OrchestratorMetadataStoring
  private let workflows: any WorkflowAllocationStoring

  public init(metadata: any OrchestratorMetadataStoring, workflows: any WorkflowAllocationStoring) {
    self.metadata = metadata
    self.workflows = workflows
  }

  @discardableResult
  public func allocate(_ request: WorkflowAllocationRequest) async throws -> WorkflowAllocation {
    try await metadata.reserveWorkflowAllocation(request)
    let allocation: WorkflowAllocation
    do {
      allocation = try await workflows.ensureWorkflowAllocation(request)
    } catch let error as WorkflowAllocationError {
      switch error {
      case .identityCollision, .operationOwnedByAnotherAllocation:
        // The workflow transaction created no records for this request.
        try await metadata.rejectWorkflowAllocation(request)
        throw OrchestratorMetadataError.allocationRejected(request.operationID)
      default:
        throw error
      }
    }
    try await metadata.completeWorkflowAllocation(allocation.receipt)
    return allocation
  }

  @discardableResult
  public func reconcilePendingAllocations() async throws -> [WorkflowAllocationRecoveryFailure] {
    var failures: [WorkflowAllocationRecoveryFailure] = []
    for entry in try await metadata.pendingWorkflowAllocations() {
      try Task.checkCancellation()
      switch entry {
      case .request(let request):
        if let failure = try await recover(request) { failures.append(failure) }
      case .unreadable(let operationID):
        failures.append(.init(operationID: operationID, disposition: .unreadable))
      }
    }
    return failures
  }

  private func recover(_ request: WorkflowAllocationRequest) async throws
    -> WorkflowAllocationRecoveryFailure?
  {
    do {
      try await allocate(request)
      return nil
    } catch is CancellationError {
      throw CancellationError()
    } catch OrchestratorMetadataError.allocationRejected {
      return .init(operationID: request.operationID, disposition: .rejected)
    } catch {
      return .init(operationID: request.operationID, disposition: .pending)
    }
  }
}
