import AgentHubGitDiff
import AgentHubGitHub
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Reviewed pull request publication")
struct PullRequestPublicationTests {
  @Test("Both providers prepare the same exact push and GitHub handoff",
        arguments: [SessionProviderKind.claude, .codex])
  func preparesReviewedDraftHandoff(provider: SessionProviderKind) async throws {
    let fixture = try PublicationFixture(provider: provider)
    let plan = try await fixture.prepare()
    #expect(plan.files == ["Read Me.md", "Sources/main.swift"])
    #expect(plan.needsPush)
    let result = try await fixture.service.publish(plan)
    #expect(result.destination == PublicationFixture.handoff)
    #expect(fixture.git.pushes == [plan.checkout.head])
    #expect(try await fixture.service.publish(plan).destination == result.destination)
    #expect(fixture.git.pushes.count == 1)
  }

  @MainActor
  @Test("A contextual create action stays read-only until the user approves its current review")
  func reviewBeforeApproval() async throws {
    let fixture = try PublicationFixture()
    let session = CLISession(id: fixture.context.sessionID, projectPath: fixture.context.projectPath,
                             branchName: fixture.context.branch)
    let origin = SessionLaunchOrigin(
      source: .linear, accountID: "fixture", sourceID: "issue", key: "FIX-1", title: "Review scope",
      publicationRepository: PublicationFixture.repository)
    let model = CreatePullRequestAction(
      session: session, provider: fixture.context.provider, title: "Fixture", origin: origin,
      service: fixture.service, observation: nil,
      target: .currentBranch(projectPath: session.projectPath, branchName: session.branchName))
    #expect(!model.canPublish)
    await model.publish()
    #expect(await fixture.remote.lookedUpRepositories.isEmpty)
    await model.prepare()
    #expect(model.canPublish)
    #expect(model.title == "FIX-1 Review scope")
    #expect(fixture.git.pushes.isEmpty)
    model.invalidate()
    await model.publish()
    #expect(!model.canPublish)
    #expect(fixture.git.pushes.isEmpty)
  }

  @Test("A handoff survives relaunch and cannot issue another push")
  func uncertainOutcome() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    #expect(try await fixture.service.publish(plan).destination == PublicationFixture.handoff)
    let reopened = try SessionMetadataStore(path: fixture.path)
    let freshService = PullRequestPublicationService(git: fixture.git, remote: fixture.remote, store: reopened)
    #expect(try await freshService.prepare(fixture.context).destination == PublicationFixture.handoff)
    #expect(try await freshService.publish(plan).destination == PublicationFixture.handoff)
    #expect(fixture.git.pushes.count == 1)
    fixture.git.failCheckout(with: .dirty)
    #expect(try await freshService.prepare(fixture.context) == .pending)
    await fixture.remote.setRequest(PublicationFixture.request)
    #expect(try await freshService.prepare(fixture.context) == .existing(PublicationFixture.request))
    #expect(try await reopened.pullRequestPublication(for: plan.key)?.phase == .verified)
  }

  @Test("An unsuccessful remote read after pushing offers a fresh review after restart")
  func unsuccessfulReadCanBePreparedAgain() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    await fixture.remote.failLookup(after: 1)
    await #expect(throws: PullRequestPublicationError.gitHubUnavailable) {
      try await fixture.service.publish(plan)
    }
    #expect(try await fixture.store.pullRequestPublication(for: plan.key) == nil)
    let reopened = try SessionMetadataStore(path: fixture.path)
    let freshService = PullRequestPublicationService(git: fixture.git, remote: fixture.remote, store: reopened)
    await fixture.remote.failLookup(after: nil)
    guard case .review(let refreshed) = try await freshService.prepare(fixture.context) else {
      Issue.record("An explicit new review should be offered")
      return
    }
    #expect(!refreshed.needsPush)
    #expect(fixture.git.pushes.count == 1)
  }

  @Test("A changed handoff needs fresh review and does not push again")
  func explicitNewReviewAfterHandoff() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    _ = try await fixture.service.publish(plan)
    fixture.git.setHead("new-local-head")
    #expect(try await fixture.service.prepare(fixture.context) == .pending)
    guard case .review(let refreshed) = try await fixture.service.reviewCurrentCommits(fixture.context) else {
      Issue.record("Expected a new review")
      return
    }
    #expect(refreshed.checkout.head == "new-local-head")
    #expect(fixture.git.pushes == [plan.checkout.head])
    #expect(try await fixture.store.pullRequestPublication(for: plan.key) == nil)
  }

  @Test("A different source or base commit cannot confirm the handoff",
        arguments: [true, false])
  func differentCommitCannotConfirm(changedHead: Bool) async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    _ = try await fixture.service.publish(plan)
    let request = GitHubPublishedPullRequest(
      number: 4, url: PublicationFixture.request.url, head: changedHead ? "different" : "reviewed",
      branch: "feature", base: "main", baseOID: changedHead ? "base-commit" : "different-base")
    await fixture.remote.setRequest(request)
    guard case .mismatched(let observed, let record) = try await fixture.service.prepare(fixture.context) else {
      Issue.record("Expected a mismatch instead of confirming the handoff")
      return
    }
    #expect(observed == request)
    #expect(record.baseOID == plan.refs.base)
    #expect(record.head == plan.checkout.head)
    #expect(try await fixture.store.pullRequestPublication(for: plan.key)?.phase == .handedOff)
  }

  @Test("A retargeted origin cannot replace the repository recorded at launch")
  func retargetedOrigin() async throws {
    let fixture = try PublicationFixture()
    fixture.git.setRemote(.init(owner: "other", repository: "project"))
    await #expect(throws: PullRequestPublicationError.wrongRepository) {
      try await fixture.service.prepare(fixture.context)
    }
    #expect(fixture.git.pushes.isEmpty)
    #expect(await fixture.remote.lookedUpRepositories == [PublicationFixture.repository])
  }

  @Test("A manual session requires an independently entered repository before contacting GitHub")
  func missingLaunchIdentity() async throws {
    let fixture = try PublicationFixture()
    let context = PullRequestContext(
      sessionID: "legacy", provider: .claude, projectPath: fixture.context.projectPath,
      branch: "feature", repository: nil)
    #expect(try await fixture.service.prepare(context) == .chooseRepository(PublicationFixture.repository))
    await #expect(throws: PullRequestPublicationError.unconfirmedRepository) {
      try await fixture.service.confirmRepository(context, name: "other/project")
    }
    #expect(await fixture.remote.lookedUpRepositories.isEmpty)
    #expect(fixture.git.pushes.isEmpty)
    guard case .review(let plan) = try await fixture.service.confirmRepository(context, name: "owner/project") else {
      Issue.record("Expected a reviewed manual repository")
      return
    }
    #expect(plan.context.repository == PublicationFixture.repository)
    #expect(try await fixture.service.publish(plan).destination == PublicationFixture.handoff)
    let reopened = try SessionMetadataStore(path: fixture.path)
    let freshService = PullRequestPublicationService(git: fixture.git, remote: fixture.remote, store: reopened)
    #expect(try await freshService.prepare(context).destination == PublicationFixture.handoff)
  }

  @Test("A branch move after recording the handoff stops the GitHub destination")
  func revalidatesAfterJournalTransition() async throws {
    let fixture = try PublicationFixture()
    let store = JournalTransitionFixture(store: fixture.store, git: fixture.git)
    let service = PullRequestPublicationService(git: fixture.git, remote: fixture.remote, store: store)
    guard case .review(let plan) = try await service.prepare(fixture.context) else {
      Issue.record("Expected a scoped review")
      return
    }
    await #expect(throws: PullRequestPublicationError.staleReview) {
      try await service.publish(plan)
    }
    #expect(try await fixture.store.pullRequestPublication(for: plan.key) == nil)
  }

  @Test("A fresh review cannot reuse approval for a changed diff, current branch, or dirty checkout",
        arguments: [PullRequestPublicationError.dirty, .wrongBranch, .staleReview])
  func staleReview(error: PullRequestPublicationError) async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    if error == .staleReview {
      fixture.git.setHead("new-local-head")
    } else {
      fixture.git.failCheckout(with: error)
    }
    await #expect(throws: error) {
      try await fixture.service.publish(plan)
    }
    #expect(fixture.git.pushes.isEmpty)
  }

  @Test("Another session for this branch sees the durable handoff")
  func sharedBranchClaim() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    _ = try await fixture.service.publish(plan)
    let other = PullRequestContext(
      sessionID: "other", provider: .codex, projectPath: fixture.context.projectPath,
      branch: "feature", repository: PublicationFixture.repository)
    #expect(try await fixture.service.prepare(other).destination == PublicationFixture.handoff)
    #expect(fixture.git.pushes.count == 1)
  }

  @Test("Authentication errors keep the action unavailable and preserve the branch")
  func missingAuthentication() async throws {
    let fixture = try PublicationFixture()
    await fixture.remote.setAuthenticated(false)
    await #expect(throws: PullRequestPublicationError.gitHubUnavailable) {
      try await fixture.service.prepare(fixture.context)
    }
    #expect(fixture.git.pushes.isEmpty)
  }

  @Test("Publication accepts only a single credential-free GitHub.com repository URL")
  func validateOrigin() {
    #expect(ReviewedPullRequestGit.safeRemote("git@github.com:owner/project.git")?.repository == "project")
    #expect(ReviewedPullRequestGit.safeRemote("https://github.com/owner/project")?.owner == "owner")
    #expect(ReviewedPullRequestGit.safeRemote("https://token@github.com/owner/project") == nil)
    #expect(ReviewedPullRequestGit.safeRemote("https://github.com/owner/project/other") == nil)
    #expect(ReviewedPullRequestGit.safeRemote("ssh://other.example/owner/project") == nil)
  }

  @Test("Migration v26 preserves v25 session metadata and the Linear queue transition journal")
  func migrationPreservesBaseline() async throws {
    let fixture = try PublicationFixture()
    let path = fixture.path + ".baseline"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let baseline = try DatabaseQueue(path: path)
    let versions = SessionMetadataStore.migrationIdentifiers
    #expect(Array(versions.suffix(2)) == [
      SessionMetadataStore.MigrationID.createLinearQueueTransitions,
      SessionMetadataStore.MigrationID.addPullRequestPublications])
    try fixture.store.migrator.migrate(
      baseline, upTo: SessionMetadataStore.MigrationID.createLinearQueueTransitions)
    let original = try await baseline.write { database in
      try database.execute(sql: """
        INSERT INTO session_metadata (sessionId, customName, isPinned, createdAt, updatedAt)
        VALUES ('keep', 'Original name', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """)
      try database.execute(sql: """
        INSERT INTO linear_queue_transitions (operationID, workspaceID, userID, issueID, payload, active)
        VALUES ('pending', x'01', x'02', x'03', x'0405', 1)
        """)
      return try preservedRows(database)
    }
    let upgraded = try SessionMetadataStore(path: path)
    let actual = try await baseline.read { database in
      #expect(try database.tableExists("pull_request_publications"))
      return try preservedRows(database)
    }
    #expect(actual.sessions == original.sessions)
    #expect(actual.transitions == original.transitions)
    let plan = try await fixture.prepare()
    let record = PullRequestPublicationRecord(
      id: UUID(), key: plan.key, base: plan.baseBranch, baseOID: plan.refs.base, head: plan.checkout.head,
      sessionID: plan.context.sessionID, provider: plan.context.provider.rawValue, phase: .handedOff)
    #expect(try await upgraded.beginPullRequestPublication(record))
    #expect(try await upgraded.pullRequestPublication(for: plan.key) == record)
  }

  @Test("Sidebar and header derive a create or commit action from the same facts")
  func suggestions() {
    let path = "/tmp/pr-fixture"
    let complete = SessionProgressPresentation(
      state: nil, terminalExitedAt: .distantPast, projectPath: path)
    let target = GitHubPRObservationTarget.session(projectPath: path, branchName: "feature", linkedPullRequests: [])
    let observation = GitHubPRObservationSnapshot(
      target: target, pullRequest: nil, checks: [], state: .ready, lastRefreshedAt: .now)
    let committed = LocalDiffSummary(fileCount: 3, additions: 4, deletions: 2, hasUncommittedChanges: false)
    let dirty = LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0, hasUncommittedChanges: true)
    #expect(SessionPublicationSuggestion.make(
      progress: complete, diff: committed, snapshot: observation, projectPath: path,
      branch: "feature") == .create)
    #expect(SessionPublicationSuggestion.make(
      progress: complete, diff: committed, snapshot: observation, projectPath: path,
      branch: "feature", hasPublicationRepository: false) == nil)
    #expect(SessionPublicationSuggestion.make(
      progress: complete, diff: committed, snapshot: observation, projectPath: path,
      branch: "feature", awaitsGitHub: true) == .checkPublication)
    #expect(SessionPublicationSuggestion.make(
      progress: complete, diff: dirty, snapshot: observation, projectPath: path,
      branch: "feature") == .reviewCommit)
    #expect(SessionPublicationSuggestion.make(
      progress: complete, diff: committed, snapshot: observation, projectPath: "/other",
      branch: "feature") == nil)
  }

  @Test("An observed PR offers a distinct action for checks, feedback, or opening")
  func existingPullRequestSuggestions() throws {
    let path = "/tmp/pr-fixture"
    let progress = SessionProgressPresentation(state: nil, terminalExitedAt: .distantPast, projectPath: path)
    let target = GitHubPRObservationTarget.currentBranch(projectPath: path, branchName: "feature")
    let request = try JSONDecoder().decode(GitHubPullRequest.self, from: Data("""
      {
        "number": 4, "title": "Fixture", "state": "OPEN", "url": "https://github.com/owner/project/pull/4",
        "headRefName": "feature", "baseRefName": "main", "isDraft": true, "additions": 2, "deletions": 1,
        "changedFiles": 1, "reviewDecision": "CHANGES_REQUESTED"
      }
      """.utf8))
    let failure = try JSONDecoder().decode(GitHubCheckRun.self, from: Data("""
      {"name": "Unit tests", "status": "COMPLETED", "conclusion": "FAILURE"}
      """.utf8))
    let blocker = GitHubPRObservationSnapshot(
      target: target, pullRequest: request, checks: [failure], state: .ready, lastRefreshedAt: .now)
    let feedback = GitHubPRObservationSnapshot(
      target: target, pullRequest: request, checks: [], state: .ready, lastRefreshedAt: .now)
    #expect(SessionPublicationSuggestion.make(
      progress: progress, diff: nil, snapshot: blocker, projectPath: path, branch: "feature") == .checks)
    #expect(SessionPublicationSuggestion.make(
      progress: progress, diff: nil, snapshot: feedback, projectPath: path, branch: "feature") == .feedback)
    #expect(SessionPublicationSuggestion.checks.browserURL(for: request)?.absoluteString
      == "https://github.com/owner/project/pull/4/checks")
    #expect(SessionPublicationSuggestion.open.browserURL(for: request)?.absoluteString == request.url)
    #expect(SessionPublicationSuggestion.feedback.browserURL(for: request) == nil)
  }

}

private extension PullRequestPreparation {
  var destination: URL? {
    if case .handoff(let handoff) = self { return handoff.destination }
    return nil
  }
}

private func preservedRows(_ database: Database) throws -> (sessions: [Row], transitions: [Row]) {
  (try Row.fetchAll(database, sql: "SELECT * FROM session_metadata"),
   try Row.fetchAll(database, sql: "SELECT * FROM linear_queue_transitions"))
}

private struct PublicationFixture {
  static let repository = GitHubRepositoryIdentity(owner: "owner", repository: "project")
  static let handoff = URL(string: "https://github.com/owner/project/compare/main...feature?expand=1")!
  static let request = GitHubPublishedPullRequest(
    number: 4, url: URL(string: "https://github.com/owner/project/pull/4")!,
    head: "reviewed", branch: "feature", base: "main", baseOID: "base-commit")
  let git = PublicationGitFixture()
  let remote = PublicationRemoteFixture()
  let context: PullRequestContext
  let path: String
  let store: SessionMetadataStore
  let service: PullRequestPublicationService
  private let temporary: PublicationTemporaryDirectory

  init(provider: SessionProviderKind = .claude) throws {
    temporary = try PublicationTemporaryDirectory()
    path = temporary.url.appendingPathComponent("publication.sqlite").path
    store = try SessionMetadataStore(path: path)
    context = .init(sessionID: "session", provider: provider, projectPath: "/tmp/pr-fixture", branch: "feature",
                    repository: Self.repository)
    service = PullRequestPublicationService(git: git, remote: remote, store: store)
  }

  func prepare() async throws -> PullRequestPublicationPlan {
    guard case .review(let plan) = try await service.prepare(context) else {
      throw PullRequestPublicationError.emptyDiff
    }
    return plan
  }
}

private final class PublicationTemporaryDirectory {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: url) }
}

private final class PublicationGitFixture: PullRequestPublicationGit, @unchecked Sendable {
  private let lock = NSLock()
  private var localHead = "reviewed"
  private var remoteHead: String?
  private var remote = PublicationFixture.repository
  private var error: PullRequestPublicationError?
  private var pushed: [String] = []
  var pushes: [String] { lock.withLock { pushed } }

  func setRemote(_ value: GitHubRepositoryIdentity) { lock.withLock { remote = value } }
  func setHead(_ value: String) { lock.withLock { localHead = value } }
  func failCheckout(with error: PullRequestPublicationError) { lock.withLock { self.error = error } }

  func origin(_ context: PullRequestContext) throws -> GitHubRepositoryIdentity {
    lock.withLock { remote }
  }

  func checkout(_ context: PullRequestContext) throws -> PullRequestCheckout {
    try lock.withLock {
      if let error { throw error }
      return .init(root: context.projectPath, remote: remote,
                   pushURL: "git@github.com:owner/project.git", branch: "feature", head: localHead)
    }
  }
  func remoteRefs(_ checkout: PullRequestCheckout, base: String) -> PullRequestRefs {
    lock.withLock { .init(base: "base-commit", head: remoteHead) }
  }
  func files(_ checkout: PullRequestCheckout, base: String) -> [String] {
    ["Read Me.md", "Sources/main.swift"]
  }
  func push(_ checkout: PullRequestCheckout) {
    lock.withLock {
      remoteHead = checkout.head
      pushed.append(checkout.head)
    }
  }
}

private actor PublicationRemoteFixture: GitHubReviewedPublishing {
  private var request: GitHubPublishedPullRequest?
  private var authenticated = true
  private var allowedLookups: Int?
  private(set) var lookedUpRepositories: [GitHubRepositoryIdentity] = []
  func failLookup(after count: Int?) { allowedLookups = count }
  func setAuthenticated(_ value: Bool) { authenticated = value }
  func setRequest(_ value: GitHubPublishedPullRequest) { request = value }

  func publicationBase(in repository: GitHubRepositoryIdentity) throws -> String {
    if !authenticated { throw GitHubCLIError.notAuthenticated }
    return "main"
  }

  func publicationPullRequest(
    in repository: GitHubRepositoryIdentity, branch: String
  ) throws -> GitHubPublishedPullRequest? {
    if !authenticated { throw GitHubCLIError.notAuthenticated }
    if let allowedLookups {
      guard allowedLookups > 0 else { throw GitHubCLIError.timeout }
      self.allowedLookups = allowedLookups - 1
    }
    lookedUpRepositories.append(repository)
    return request
  }
}

private struct JournalTransitionFixture: PullRequestPublicationStoring {
  let store: SessionMetadataStore
  let git: PublicationGitFixture
  func pullRequestPublication(for key: PullRequestPublicationKey) async throws -> PullRequestPublicationRecord? {
    try await store.pullRequestPublication(for: key)
  }
  func pullRequestPublicationRepository(for context: PullRequestContext) async throws -> GitHubRepositoryIdentity? {
    try await store.pullRequestPublicationRepository(for: context)
  }
  func beginPullRequestPublication(_ record: PullRequestPublicationRecord) async throws -> Bool {
    try await store.beginPullRequestPublication(record)
  }
  func advancePullRequestPublication(id: UUID, from: PullRequestPublicationRecord.Phase,
                                     to: PullRequestPublicationRecord.Phase) async throws -> Bool {
    let updated = try await store.advancePullRequestPublication(id: id, from: from, to: to)
    if to == .handedOff { git.setHead("changed-after-reservation") }
    return updated
  }
  func abandonPullRequestPush(id: UUID) async throws {
    try await store.abandonPullRequestPush(id: id)
  }
}
