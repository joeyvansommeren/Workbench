import AgentHubCLIKit
import AgentWorkflowCore
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Workbench orchestration launch adapter")
struct WorkbenchOrchestratorWorkerTests {
  @Test("Missing exact approval blocks before creating or starting anything")
  func approvalDenied() async throws {
    let driver = FixtureProviderDriver(provider: .codex)
    let worker = WorkbenchOrchestratorWorker(worktrees: WorktreeManagementService(),
      authorizer: FixtureAuthorizer(authorization: nil), providers: [driver])
    let launch = try makeLaunch(repositoryPath: "/not-a-real-repo", worktreePath: "/not-a-real-checkout")
    #expect(try await worker.launch(launch) == .requiresAttention(.worktreeApprovalRequired))
    #expect(await driver.starts.isEmpty)
  }

  @Test("An unavailable or ambiguous provider never falls back to an installed provider")
  func noFallback() async throws {
    let driver = FixtureProviderDriver(provider: .claude)
    let worker = WorkbenchOrchestratorWorker(worktrees: WorktreeManagementService(),
      authorizer: FixtureAuthorizer(authorization: nil), providers: [driver])
    let launch = try makeLaunch(repositoryPath: "/not-a-real-repo", worktreePath: "/not-a-real-checkout")
    #expect(try await worker.launch(launch) == .requiresAttention(.providerUnavailable))
    #expect(await driver.starts.isEmpty)
  }

  @Test("Approved checkout uses the sibling worktree service and keeps the module launch path")
  func approvedSparseCheckout() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "orchestrator-checkout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let repository = fixtureRoot.appending(path: "project")
    let module = repository.appending(path: "modules/demo")
    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try Data("{\"name\":\"demo\"}".utf8).write(to: module.appending(path: "package.json"))
    try Data("fixture\n".utf8).write(to: repository.appending(path: "README.md"))
    _ = try git(["init", "-b", "main"], in: repository)
    _ = try git(["add", "."], in: repository)
    _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "commit", "-m", "Fixture"], in: repository)
    let commit = try git(["rev-parse", "HEAD"], in: repository)
    let repositoryPath = try git(["rev-parse", "--show-toplevel"], in: repository)
    let worktree = siblingCheckout(of: repositoryPath)
    let launch = try makeLaunch(repositoryPath: repositoryPath, worktreePath: worktree.path,
      launchPath: worktree.appending(path: "modules/demo").path, baseCommit: commit)
    let origin = SessionLaunchOrigin(source: .linear, accountID: "fixture-account",
      sourceID: "fixture-issue", key: "TEST-1", title: "Fixture")
    let driver = FixtureProviderDriver(provider: .codex)
    let adapter = WorkbenchOrchestratorWorker(worktrees: WorktreeManagementService(),
      authorizer: FixtureAuthorizer(authorization: .init(origin: origin)), providers: [driver])
    _ = try await adapter.launch(launch)
    let start = try #require(await driver.starts.first)
    #expect(start.pendingID == launch.attempt.pendingLaunchID)
    #expect(start.worktreePath == worktree.path)
    #expect(start.launchPath == launch.plan.launchPath)
    #expect(try git(["config", "--get", "core.sparseCheckout"], in: worktree) == "true")
    #expect(try git(["rev-parse", "HEAD"], in: worktree) == commit)
  }

  @Test("Retry verifies the approved base in the actual checkout", arguments: [true, false])
  func retryRequiresIntegratedBase(worktreeIncludesNewBase: Bool) async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appending(path: "orchestrator-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let repository = fixtureRoot.appending(path: "project")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try git(["init", "-b", "main"], in: repository)
    _ = try commitFixture("original", in: repository)
    let repositoryPath = try git(["rev-parse", "--show-toplevel"], in: repository)
    let worktree = siblingCheckout(of: repositoryPath)
    _ = try git(["worktree", "add", "-b", "worker/fixture", worktree.path], in: repository)
    let approvedBase = try commitFixture("accepted-prerequisite", in: repository)

    if worktreeIncludesNewBase {
      _ = try git(["merge", "--ff-only", approvedBase], in: worktree)
    }
    _ = try commitFixture("independent-work", in: worktree)

    let launch = try makeLaunch(repositoryPath: repositoryPath, worktreePath: worktree.path,
      baseCommit: approvedBase, predecessorID: UUID())
    let origin = SessionLaunchOrigin(source: .linear, accountID: "fixture-account",
      sourceID: "fixture-issue", key: "TEST-1", title: "Fixture")
    let driver = FixtureProviderDriver(provider: .codex)
    let adapter = WorkbenchOrchestratorWorker(worktrees: WorktreeManagementService(),
      authorizer: FixtureAuthorizer(authorization: .init(origin: origin, reuseOwnedWorktree: true)),
      providers: [driver])
    let result = try await adapter.launch(launch)
    if worktreeIncludesNewBase {
      #expect(result == .uncertain)
      #expect(await driver.starts.map(\.pendingID) == [launch.attempt.pendingLaunchID])
    } else {
      #expect(result == .requiresAttention(.worktreeApprovalRequired))
      #expect(await driver.starts.isEmpty)
    }
  }

  private func siblingCheckout(of repositoryPath: String) -> URL {
    // Git reports the physical repository path, including the /private prefix on macOS.
    URL(fileURLWithPath: repositoryPath).deletingLastPathComponent().appending(path: "worker")
  }

  private func commitFixture(_ name: String, in repo: URL) throws -> String {
    try Data(name.utf8).write(to: repo.appending(path: "\(name).txt"))
    _ = try git(["add", "."], in: repo)
    _ = try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "commit", "-m", name], in: repo)
    return try git(["rev-parse", "HEAD"], in: repo)
  }

  private func makeLaunch(repositoryPath: String, worktreePath: String, launchPath: String? = nil,
    baseCommit: String = String(repeating: "a", count: 40), predecessorID: UUID? = nil
  ) throws -> OrchestratorWorkerLaunch
  {
    let source = try OrchestratorSourceIdentity(trackerID: "linear",
      accountID: "fixture-account", scopeID: "fixture-workspace")
    let snapshot = OrchestratorSourceRevision(issue: try .init(source: source, issueID: "fixture-issue"),
      queueScope: .project(id: "fixture-project"), revision: "1", ticketKey: "TEST-1")
    let attempt = try OrchestratorDispatchAttempt(
      id: UUID(), operationID: UUID(), runID: UUID(), itemID: UUID(), predecessorID: predecessorID,
      pendingLaunchID: UUID(), provider: .codex, ticketRunID: UUID(), branchRunID: UUID(),
      baseCommitID: baseCommit)
    let repository = try OrchestratorRepositoryBinding(repositoryPath: repositoryPath, baseBranch: "main")
    return .init(attempt: attempt,
      plan: .init(repository: repository, worktreePath: worktreePath,
        launchPath: launchPath, branchName: "worker/fixture", baseCommitID: baseCommit),
      snapshot: snapshot)
  }

  private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = directory
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct FixtureAuthorizer: OrchestratorWorkerAuthorizing {
  let authorization: OrchestratorWorkerAuthorization?
  func authorizeWorker(_ launch: OrchestratorWorkerLaunch)
    -> OrchestratorWorkerAuthorization? { authorization }
}

private actor FixtureProviderDriver: OrchestratorProviderWorkerDriving {
  struct Start: Sendable {
    let pendingID: UUID
    let worktreePath: String
    let launchPath: String
  }

  nonisolated let provider: AgentProviderID
  private(set) var starts: [Start] = []

  init(provider: AgentProviderID) { self.provider = provider }

  func start(attempt: OrchestratorDispatchAttempt, worktree: WorktreeBranch, launchPath: String,
    authorization: OrchestratorWorkerAuthorization) -> OrchestratorWorkerObservation
  {
    starts.append(Start(pendingID: attempt.pendingLaunchID, worktreePath: worktree.path, launchPath: launchPath))
    return .uncertain
  }

  func observe(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    -> OrchestratorWorkerObservation { .uncertain }

  func cancel(attempt: OrchestratorDispatchAttempt, session: OrchestratorSessionIdentity?)
    -> OrchestratorWorkerObservation { .uncertain }

  func verifyHandoff(attempt: OrchestratorDispatchAttempt, binding: OrchestratorWorkerBinding)
    -> Bool { false }
}
