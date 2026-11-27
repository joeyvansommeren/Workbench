import AgentHubSessionGraph
import AgentWorkflowCore
import AgentWorkflowJiraCLI
import Foundation

public protocol AgentWorkflowRuntimeProtocol: Sendable {
  func startTicketFromJira(
    key: String,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun
  func tickets() async throws -> [TicketRun]
  func branches(ticketRunID: UUID) async throws -> [BranchRun]
}

/// Thin AgentHub integration boundary around the provider-neutral workflow store.
/// Provider launchers and UI models depend on this runtime, never on database details.
public actor AgentWorkflowRuntime: AgentWorkflowRuntimeProtocol {
  private let store: any AgentWorkflowStoreProtocol
  private let jiraReader: any JiraTicketReading
  private let queueExecutor: (any OrchestratorQueueExecuting)?

  public init(
    store: any AgentWorkflowStoreProtocol,
    jiraReader: any JiraTicketReading = ACLITicketReader(),
    queueExecutor: (any OrchestratorQueueExecuting)? = nil
  ) {
    self.store = store
    self.jiraReader = jiraReader
    self.queueExecutor = queueExecutor
  }

  /// The same store owns existing ticket workflows and orchestrated allocations.
  public init(
    store: any AgentWorkflowStoreProtocol & WorkflowAllocationStoring,
    metadata: any OrchestratorMetadataStoring,
    source: any OrchestratorDispatchSource,
    planner: any OrchestratorDispatchPreparing,
    workers: any OrchestratorWorkerLaunching,
    clock: any OrchestratorExecutionClock = SystemOrchestratorExecutionClock(),
    jiraReader: any JiraTicketReading = ACLITicketReader()
  ) {
    self.store = store
    self.jiraReader = jiraReader
    queueExecutor = OrchestratorQueueExecutor(
      metadata: metadata, workflows: store, source: source, planner: planner,
      workers: workers, clock: clock)
  }

  public init() throws {
    store = try AgentWorkflowStore()
    jiraReader = ACLITicketReader()
    queueExecutor = nil
  }

  public func startTicket(
    key: String,
    summary: String? = nil,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun {
    try await store.createTicketRun(
      ticketKey: key,
      summary: summary,
      coordinatorProvider: coordinatorProvider.workflowProviderID
    )
  }

  public func tickets() async throws -> [TicketRun] {
    try await store.ticketRuns()
  }

  public func startTicketFromJira(
    key: String,
    coordinatorProvider: SessionProviderKind
  ) async throws -> TicketRun {
    let snapshot = try await jiraReader.ticket(key: key)
    return try await startTicket(
      key: snapshot.key,
      summary: snapshot.summary,
      coordinatorProvider: coordinatorProvider
    )
  }

  public func branches(ticketRunID: UUID) async throws -> [BranchRun] {
    try await store.branchRuns(ticketRunID: ticketRunID)
  }
}

extension AgentWorkflowRuntime: OrchestratorQueueExecuting {
  public func start(runID: UUID) async throws {
    try await configuredQueue().start(runID: runID)
  }

  public func executeNext(runID: UUID) async throws -> OrchestratorDispatchOutcome {
    try await configuredQueue().executeNext(runID: runID)
  }

  public func retry(runID: UUID, itemID: UUID) async throws -> OrchestratorDispatchOutcome {
    try await configuredQueue().retry(runID: runID, itemID: itemID)
  }

  public func pause(runID: UUID) async throws {
    try await configuredQueue().pause(runID: runID)
  }

  public func stop(runID: UUID) async throws {
    try await configuredQueue().stop(runID: runID)
  }

  public func recover(runID: UUID) async throws {
    try await configuredQueue().recover(runID: runID)
  }

  public func resume(runID: UUID) async throws {
    try await configuredQueue().resume(runID: runID)
  }

  public func handOff(runID: UUID, itemID: UUID, attemptID: UUID,
    binding: OrchestratorWorkerBinding, eventID: UUID) async throws
  {
    try await configuredQueue().handOff(
      runID: runID, itemID: itemID, attemptID: attemptID, binding: binding, eventID: eventID)
  }

  private func configuredQueue() throws -> any OrchestratorQueueExecuting {
    guard let queueExecutor else { throw OrchestratorExecutionError.unavailable }
    return queueExecutor
  }
}

extension SessionProviderKind {
  fileprivate var workflowProviderID: AgentProviderID {
    switch self {
    case .codex: .codex
    case .claude: .claude
    }
  }
}
