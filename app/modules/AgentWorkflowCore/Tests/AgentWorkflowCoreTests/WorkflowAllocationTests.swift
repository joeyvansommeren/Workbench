import Foundation
import GRDB
import Testing

@testable import AgentWorkflowCore

@Suite("Durable workflow allocation")
struct WorkflowAllocationTests {
  @Test(
    "Allocation and exact replay survive fresh store instances without duplicate rows or events")
  func replayAfterRestart() async throws {
    let fixture = try AllocationFixture()
    let request = try fixture.request()
    let store = try AgentWorkflowStore(path: fixture.path)
    let first = try await store.ensureWorkflowAllocation(request)
    #expect(first.receipt.request == request)
    #expect(first.ticketRun.id == request.ticketRunID)
    #expect(first.branchRun.id == request.branchRunID)
    #expect(first.branchRun.ticketRunID == request.ticketRunID)
    #expect(first.ticketRun.ticketKey == "TASK-1")
    #expect(first.branchRun.status == .queued)

    for _ in 0..<10 {
      let reopened: any WorkflowAllocationStoring = try AgentWorkflowStore(path: fixture.path)
      #expect(try await reopened.ensureWorkflowAllocation(request) == first)
    }
    #expect(try fixture.rowCounts() == [1, 1, 2, 1])
    let events = try await store.events(ticketRunID: request.ticketRunID)
    #expect(
      Set(events.map(\.id)) == Set([request.ticketCreatedEventID, request.branchCreatedEventID]))
  }

  @Test("Every changed immutable request field conflicts under an existing operation")
  func changedRequestConflicts() async throws {
    let fixture = try AllocationFixture()
    let store = try AgentWorkflowStore(path: fixture.path)
    _ = try await store.ensureWorkflowAllocation(fixture.request())
    let before = try fixture.snapshot()
    let changes: [(inout AllocationInput) -> Void] = [
      { $0.runID = allocationID(102) }, { $0.itemID = allocationID(103) },
      { $0.trackerID = "jira" }, { $0.accountID = "other-account" },
      { $0.scopeID = "other-workspace" }, { $0.issueID = "other-issue" },
      { $0.ticketRunID = allocationID(104) }, { $0.branchRunID = allocationID(105) },
      { $0.ticketCreatedEventID = allocationID(106) },
      { $0.branchCreatedEventID = allocationID(107) }, { $0.ticketKey = "TASK-1" },
      { $0.repositoryPath = "/other/example" }, { $0.worktreePath = "/other/example-task-1" },
      { $0.branchName = "other-branch" }, { $0.baseBranch = "other-base" },
      { $0.baseCommitID = "other-base-commit" }, { $0.coordinatorProvider = .claude },
      { $0.implementerProvider = .claude }, { $0.reviewerProvider = .codex },
      { $0.createdAt = $0.createdAt.addingTimeInterval(0.000_001) },
    ]
    for change in changes {
      var input = AllocationInput()
      change(&input)
      let changed = try input.request()
      await #expect(throws: WorkflowAllocationError.operationConflict(changed.operationID)) {
        _ = try await store.ensureWorkflowAllocation(changed)
      }
      #expect(try fixture.snapshot() == before)
    }
  }

  @Test("Replaying creation preserves later workflow edits, sessions, tests, reviews and approvals")
  func preserveLaterWorkflowState() async throws {
    let fixture = try AllocationFixture()
    let request = try fixture.request()
    let store = try AgentWorkflowStore(path: fixture.path)
    let first = try await store.ensureWorkflowAllocation(request)
    _ = try await store.apply(.startImplementation, to: request.branchRunID)
    _ = try await store.apply(.beginTesting, to: request.branchRunID)
    _ = try await store.apply(.testsPassed(diffHash: "tested-change"), to: request.branchRunID)
    _ = try await store.apply(.beginReview, to: request.branchRunID)
    _ = try await store.apply(.reviewCompleted(.approved), to: request.branchRunID)
    let approval = try await store.requestApproval(
      branchRunID: request.branchRunID, action: .commit)
    _ = try await store.decideApproval(id: approval.id, approved: true)
    try fixture.write { db in
      try db.execute(
        sql: """
          UPDATE ticket_runs SET summary = ?, coordinatorSessionID = ?, status = ?, updatedAt = ?
          WHERE id = ?
          """,
        arguments: [
          "A later title", "coordinator-session", "awaitingHumanInput",
          Date(timeIntervalSince1970: 2_000), request.ticketRunID.uuidString,
        ])
      try db.execute(
        sql: """
          UPDATE branch_runs SET implementerSessionID = ?, reviewerSessionID = ?, updatedAt = ?
          WHERE id = ?
          """,
        arguments: [
          "implementer-session", "reviewer-session", Date(timeIntervalSince1970: 2_001),
          request.branchRunID.uuidString,
        ])
    }
    let before = try fixture.snapshot()
    let reopened = try AgentWorkflowStore(path: fixture.path)
    let replay = try await reopened.ensureWorkflowAllocation(request)
    #expect(replay.receipt == first.receipt)
    #expect(replay.ticketRun.summary == "A later title")
    #expect(replay.ticketRun.coordinator.sessionID == "coordinator-session")
    #expect(replay.ticketRun.status == .awaitingHumanInput)
    #expect(replay.branchRun.implementer.sessionID == "implementer-session")
    #expect(replay.branchRun.reviewer.sessionID == "reviewer-session")
    #expect(replay.branchRun.status == .awaitingApproval)
    #expect(replay.branchRun.reviewCycle == 1)
    #expect(replay.branchRun.currentDiffHash == "tested-change")
    #expect(
      try await reopened.approvalRequests(branchRunID: request.branchRunID).first?.status
        == .approved)
    #expect(try fixture.snapshot() == before)
  }

  @Test("Existing IDs cannot be adopted even when their legacy values match the request")
  func rejectLegacyIdentityAdoption() async throws {
    let fixture = try AllocationFixture()
    let store = try AgentWorkflowStore(path: fixture.path)
    let ticket = try await store.createTicketRun(ticketKey: "task-1", coordinatorProvider: .codex)
    let branch = try await store.createBranchRun(
      ticketRunID: ticket.id, repositoryPath: "/repos/example",
      worktreePath: "/repos/example-task-1", branchName: "task-1", baseBranch: "main",
      implementerProvider: .codex, reviewerProvider: .claude)
    let events = try await store.events(ticketRunID: ticket.id)
    let before = try fixture.snapshot()
    let collisions: [(String, (inout AllocationInput) -> Void)] = [
      ("ticketRunID", { $0.ticketRunID = ticket.id }),
      ("branchRunID", { $0.branchRunID = branch.id }),
      ("ticketCreatedEventID", { $0.ticketCreatedEventID = events[0].id }),
      ("branchCreatedEventID", { $0.branchCreatedEventID = events[0].id }),
    ]
    for (field, change) in collisions {
      var input = AllocationInput()
      change(&input)
      await #expect(throws: WorkflowAllocationError.identityCollision(field)) {
        _ = try await store.ensureWorkflowAllocation(input.request())
      }
      #expect(try fixture.snapshot() == before)
    }
  }

  @Test("A new operation cannot take another allocation's workflow or event IDs")
  func rejectAllocatedIdentityAdoption() async throws {
    let fixture = try AllocationFixture()
    let store = try AgentWorkflowStore(path: fixture.path)
    _ = try await store.ensureWorkflowAllocation(fixture.request())
    let before = try fixture.snapshot()
    var input = AllocationInput()
    input.operationID = allocationID(101)
    await #expect(throws: WorkflowAllocationError.identityCollision("ticketRunID")) {
      _ = try await store.ensureWorkflowAllocation(input.request())
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test("Controlled SQLite failures roll back ticket, branch, both events and receipt together")
  func transactionRollback() async throws {
    for (table, timing, condition) in [
      ("branch_runs", "BEFORE", ""),
      ("workflow_events", "BEFORE", "WHEN NEW.kind = 'branch.created'"),
      ("workflow_allocation_receipts", "BEFORE", ""),
      ("workflow_allocation_receipts", "AFTER", ""),
    ] {
      let fixture = try AllocationFixture()
      let store = try AgentWorkflowStore(path: fixture.path)
      try fixture.write { db in
        try db.execute(
          sql: """
            CREATE TRIGGER abort_allocation \(timing) INSERT ON \(table) \(condition)
            BEGIN SELECT RAISE(ABORT, 'controlled allocation fault'); END;
            """)
      }
      let before = try fixture.snapshot()
      await #expect(throws: DatabaseError.self) {
        _ = try await store.ensureWorkflowAllocation(fixture.request())
      }
      #expect(try fixture.snapshot() == before)
      #expect(try fixture.rowCounts() == [0, 0, 0, 0])
      try fixture.write { db in try db.execute(sql: "DROP TRIGGER abort_allocation") }
      let reopened = try AgentWorkflowStore(path: fixture.path)
      _ = try await reopened.ensureWorkflowAllocation(fixture.request())
      #expect(try fixture.rowCounts() == [1, 1, 2, 1])
    }
  }

  @Test("Dangling receipt or altered immutable records fail without reconstructing missing data")
  func corruptReceipt() async throws {
    for sql in [
      "DELETE FROM branch_runs",
      "DELETE FROM workflow_events WHERE kind = 'ticket.created'",
      "UPDATE branch_runs SET baseBranch = 'other-base'",
      "UPDATE workflow_events SET message = 'other-branch' WHERE kind = 'branch.created'",
      "UPDATE workflow_allocation_receipts SET ticketRunID = 'invalid-id'",
    ] {
      let fixture = try AllocationFixture()
      let request = try fixture.request()
      _ = try await AgentWorkflowStore(path: fixture.path).ensureWorkflowAllocation(request)
      var configuration = Configuration()
      configuration.foreignKeysEnabled = false
      let tamper = try DatabaseQueue(path: fixture.path, configuration: configuration)
      try await tamper.write { db in try db.execute(sql: sql) }
      try tamper.close()
      let before = try fixture.snapshot()
      let reopened = try AgentWorkflowStore(path: fixture.path)
      await #expect(throws: WorkflowAllocationError.corruptReceipt(request.operationID)) {
        _ = try await reopened.ensureWorkflowAllocation(request)
      }
      #expect(try fixture.snapshot() == before)
    }
  }

  @Test("Opaque byte identities, delimiter boundaries and unknown providers survive replay")
  func byteExactIdentity() async throws {
    let fixture = try AllocationFixture()
    var original = AllocationInput()
    original.accountID = "caf\u{00e9}/one"
    original.scopeID = "two"
    original.issueID = "issu\u{00e9}"
    original.coordinatorProvider = AgentProviderID(rawValue: "future-provider")
    let request = try original.request()
    let store = try AgentWorkflowStore(path: fixture.path)
    let first = try await store.ensureWorkflowAllocation(request)
    #expect(first.ticketRun.coordinator.provider.rawValue == "future-provider")
    let changes: [(inout AllocationInput) -> Void] = [
      { $0.accountID = "cafe\u{0301}/one" },
      { $0.issueID = "issue\u{0301}" },
      {
        $0.accountID = "caf\u{00e9}"
        $0.scopeID = "one/two"
      },
      { $0.issueID = "ISSUE-1" },
    ]
    for change in changes {
      var changed = original
      change(&changed)
      #expect(try changed.request() != request)
      await #expect(throws: WorkflowAllocationError.operationConflict(request.operationID)) {
        _ = try await store.ensureWorkflowAllocation(changed.request())
      }
    }
    let reopened = try AgentWorkflowStore(path: fixture.path)
    #expect(
      try await reopened.ensureWorkflowAllocation(original.request()).receipt == first.receipt)
    #expect(try fixture.rowCounts() == [1, 1, 2, 1])
  }

  @Test("Allocation migration preserves the complete actual v1 workflow baseline")
  func migrationPreservesBaseline() async throws {
    let fixture = try AllocationFixture()
    let baseline = try DatabaseQueue(path: fixture.path)
    try AgentWorkflowStore.migrator.migrate(baseline, upTo: "v1_create_workflow_tables")
    try await baseline.write { db in try seedWorkflowBaseline(in: db) }
    try baseline.close()
    let before = try fixture.snapshot(includeReceipts: false)
    let store = try AgentWorkflowStore(path: fixture.path)
    #expect(try fixture.snapshot(includeReceipts: false) == before)
    #expect(try fixture.rowCounts() == [1, 1, 2, 0])
    #expect(try await store.ticketRuns().first?.summary == "Existing summary")
    #expect(try await store.branchRun(id: allocationID(205))?.reviewCycle == 1)
    #expect(
      try await store.approvalRequests(branchRunID: allocationID(205)).first?.status == .approved)
    _ = try await store.ensureWorkflowAllocation(fixture.request())
    #expect(try fixture.rowCounts() == [2, 2, 4, 1])
  }

  @Test("Requests reject empty required identities, duplicate event IDs and invalid time")
  func requestValidation() throws {
    let changes: [(String, (inout AllocationInput) -> Void)] = [
      ("ticketKey", { $0.ticketKey = " \n" }),
      ("repositoryPath", { $0.repositoryPath = "" }), ("worktreePath", { $0.worktreePath = "" }),
      ("branchName", { $0.branchName = "" }), ("baseBranch", { $0.baseBranch = "" }),
      ("baseCommitID", { $0.baseCommitID = "" }),
      ("coordinatorProvider", { $0.coordinatorProvider = AgentProviderID(rawValue: "") }),
      ("implementerProvider", { $0.implementerProvider = AgentProviderID(rawValue: "") }),
      ("reviewerProvider", { $0.reviewerProvider = AgentProviderID(rawValue: "") }),
      ("createdAt", { $0.createdAt = Date(timeIntervalSinceReferenceDate: .infinity) }),
    ]
    for (field, change) in changes {
      var input = AllocationInput()
      change(&input)
      #expect(throws: WorkflowAllocationError.invalidField(field)) { try input.request() }
    }
    var duplicate = AllocationInput()
    duplicate.branchCreatedEventID = duplicate.ticketCreatedEventID
    #expect(throws: WorkflowAllocationError.duplicateCreationEventIDs) { try duplicate.request() }
  }
}

private struct AllocationFixture {
  let path: String

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-allocation-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    path = directory.appendingPathComponent("workflow.sqlite").path
  }

  func request() throws -> WorkflowAllocationRequest {
    try AllocationInput().request()
  }

  func rowCounts() throws -> [Int] {
    let queue = try DatabaseQueue(path: path)
    return try queue.read { db in
      try ["ticket_runs", "branch_runs", "workflow_events", "workflow_allocation_receipts"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")!
      }
    }
  }

  func snapshot(includeReceipts: Bool = true) throws -> [String: [Row]] {
    let queue = try DatabaseQueue(path: path)
    return try queue.read { db in
      let tables =
        ["ticket_runs", "branch_runs", "workflow_events", "approval_requests"]
        + (includeReceipts ? ["workflow_allocation_receipts"] : [])
      return try Dictionary(
        uniqueKeysWithValues: tables.map { table in
          let key = table == "workflow_allocation_receipts" ? "operationID" : "id"
          return (table, try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(key)"))
        })
    }
  }

  func write(_ body: (Database) throws -> Void) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write(body)
    try queue.close()
  }
}

private struct AllocationInput {
  var operationID = allocationID(1)
  var runID = allocationID(2)
  var itemID = allocationID(3)
  var trackerID = "linear"
  var accountID = "account"
  var scopeID = "workspace"
  var issueID = "issue-1"
  var ticketRunID = allocationID(4)
  var branchRunID = allocationID(5)
  var ticketCreatedEventID = allocationID(6)
  var branchCreatedEventID = allocationID(7)
  var ticketKey = "task-1"
  var repositoryPath = "/repos/example"
  var worktreePath = "/repos/example-task-1"
  var branchName = "task-1"
  var baseBranch = "main"
  var baseCommitID = "base-commit-1"
  var coordinatorProvider = AgentProviderID.codex
  var implementerProvider = AgentProviderID.codex
  var reviewerProvider = AgentProviderID.claude
  var createdAt = Date(timeIntervalSince1970: 1_000)

  func request() throws -> WorkflowAllocationRequest {
    try WorkflowAllocationRequest(
      operationID: operationID, runID: runID, itemID: itemID,
      issue: OrchestratorIssueIdentity(
        source: OrchestratorSourceIdentity(
          trackerID: trackerID, accountID: accountID, scopeID: scopeID), issueID: issueID),
      ticketRunID: ticketRunID, branchRunID: branchRunID,
      ticketCreatedEventID: ticketCreatedEventID, branchCreatedEventID: branchCreatedEventID,
      ticketKey: ticketKey, repositoryPath: repositoryPath, worktreePath: worktreePath,
      branchName: branchName, baseBranch: baseBranch, baseCommitID: baseCommitID,
      coordinatorProvider: coordinatorProvider, implementerProvider: implementerProvider,
      reviewerProvider: reviewerProvider, createdAt: createdAt)
  }
}

private func seedWorkflowBaseline(in db: Database) throws {
  let ticket = allocationID(204).uuidString
  let branch = allocationID(205).uuidString
  let date = Date(timeIntervalSince1970: 500)
  try db.execute(
    sql: """
      INSERT INTO ticket_runs
      (id,ticketKey,summary,coordinatorProvider,coordinatorSessionID,status,createdAt,updatedAt)
      VALUES (?,?,?,?,?,?,?,?)
      """,
    arguments: [
      ticket, "LEGACY-1", "Existing summary", "codex", "coordinator", "active", date, date,
    ])
  try db.execute(
    sql: """
      INSERT INTO branch_runs
      (id,ticketRunID,repositoryPath,worktreePath,branchName,baseBranch,implementerProvider,
      implementerSessionID,reviewerProvider,reviewerSessionID,status,reviewCycle,currentDiffHash,createdAt,updatedAt)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      """,
    arguments: [
      branch, ticket, "/repos/legacy", "/repos/legacy-work", "legacy-work", "main", "codex",
      "implementer", "claude", "reviewer", "awaitingApproval", 1, "legacy-diff", date, date,
    ])
  for (id, kind) in [(allocationID(206), "ticket.created"), (allocationID(207), "review.approved")]
  {
    let eventBranch: String? = kind == "ticket.created" ? nil : branch
    try db.execute(
      sql: """
        INSERT INTO workflow_events (id,ticketRunID,branchRunID,kind,message,createdAt)
        VALUES (?,?,?,?,?,?)
        """,
      arguments: [id.uuidString, ticket, eventBranch, kind, "Existing evidence", date])
  }
  try db.execute(
    sql: """
      INSERT INTO approval_requests (id,branchRunID,action,diffHash,status,requestedAt,decidedAt)
      VALUES (?,?,?,?,?,?,?)
      """,
    arguments: [
      allocationID(208).uuidString, branch, "commit", "legacy-diff", "approved", date, date,
    ])
}

private func allocationID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))!
}
