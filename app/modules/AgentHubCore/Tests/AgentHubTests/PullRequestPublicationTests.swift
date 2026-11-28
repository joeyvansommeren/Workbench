import AgentHubGitDiff
import AgentHubGitHub
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Reviewed pull request publication")
struct PullRequestPublicationTests {
  @Test("Both providers prepare the same exact GitHub handoff",
        arguments: [SessionProviderKind.claude, .codex])
  func preparesReviewedDraftHandoff(provider: SessionProviderKind) async throws {
    let fixture = try PublicationFixture(provider: provider)
    let plan = try await fixture.prepare()
    #expect(plan.files == ["Read Me.md", "Sources/main.swift"])
    #expect(!plan.needsPush)
    let result = try await fixture.service.publish(plan)
    #expect(result.destination == PublicationFixture.handoff)
    #expect(try await fixture.service.publish(plan).destination == result.destination)
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
    let reads = await fixture.remote.refReads
    model.invalidate()
    await model.publish()
    #expect(!model.canPublish)
    #expect(await fixture.remote.refReads == reads)
  }

  @Test("A handoff survives relaunch with the same durable identity")
  func uncertainOutcome() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    #expect(try await fixture.service.publish(plan).destination == PublicationFixture.handoff)
    let reopened = try SessionMetadataStore(path: fixture.path)
    let freshService = PullRequestPublicationService(git: fixture.git, remote: fixture.remote, store: reopened)
    #expect(try await freshService.prepare(fixture.context).destination == PublicationFixture.handoff)
    #expect(try await freshService.publish(plan).destination == PublicationFixture.handoff)
    let saved = try #require(try await reopened.pullRequestPublication(for: plan.key))
    #expect(saved.phase == .handedOff)
    fixture.git.failCheckout(with: .dirty)
    #expect(try await freshService.prepare(fixture.context) == .pending(saved.id))
    await fixture.remote.setRequest(PublicationFixture.request)
    #expect(try await freshService.prepare(fixture.context) == .existing(PublicationFixture.request))
    #expect(try await reopened.pullRequestPublication(for: plan.key)?.phase == .verified)
  }

  @Test("An unsuccessful GitHub read offers a fresh review after restart")
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
  }

  @Test("A changed handoff needs fresh review")
  func explicitNewReviewAfterHandoff() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    let handoff = try #require(try await fixture.service.publish(plan).handoff)
    fixture.git.setHead("new-local-head")
    #expect(try await fixture.service.prepare(fixture.context) == .pending(handoff.record.id))
    let result = try await fixture.service.reviewCurrentCommits(fixture.context, expectedID: handoff.record.id)
    guard case .review(let refreshed) = result else {
      Issue.record("Expected a new review")
      return
    }
    #expect(refreshed.checkout.head == "new-local-head")
    #expect(refreshed.needsPush)
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
    #expect(await fixture.remote.lookedUpRepositories == [PublicationFixture.repository])
    #expect(await fixture.remote.refReads.isEmpty)
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
    let confirmation = try await fixture.service.confirmRepository(context, name: "owner/project")
    guard case .review(let plan) = confirmation.preparation else {
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
  }

  @Test("Authentication errors keep the action unavailable and preserve the branch")
  func missingAuthentication() async throws {
    let fixture = try PublicationFixture()
    await fixture.remote.setAuthenticated(false)
    await #expect(throws: PullRequestPublicationError.gitHubUnavailable) {
      try await fixture.service.prepare(fixture.context)
    }
  }

  @Test("Publication accepts only a single credential-free GitHub.com repository URL")
  func validateOrigin() {
    #expect(ReviewedPullRequestGit.safeRemote("git@github.com:owner/project.git")?.repository == "project")
    #expect(ReviewedPullRequestGit.safeRemote("https://github.com/owner/project")?.owner == "owner")
    #expect(ReviewedPullRequestGit.safeRemote("https://token@github.com/owner/project") == nil)
    #expect(ReviewedPullRequestGit.safeRemote("https://github.com/owner/project/other") == nil)
    #expect(ReviewedPullRequestGit.safeRemote("ssh://git@github.com/owner/project.git")
      == GitHubRepositoryIdentity(owner: "owner", repository: "project"))
    for url in [
      "ssh://git@other.example/owner/project", "ssh://user@github.com/owner/project",
      "ssh://git:password@github.com/owner/project", "ssh://git@github.com:2222/owner/project",
      "ssh://git@github.com/owner/project/extra", "ssh://git@github.com/owner/project?option",
      "ssh://git@github.com/owner/project#fragment",
    ] {
      #expect(ReviewedPullRequestGit.safeRemote(url) == nil)
    }
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

@Suite("Reviewed publication recovery")
struct PullRequestPublicationRecoveryTests {
  @Test("An unpushed head requires a fresh read and approval after the manual push")
  func manualPushBeforeHandoff() async throws {
    let fixture = try PublicationFixture()
    await fixture.remote.setHead(nil)
    let unpushed = try await fixture.prepare()
    #expect(unpushed.needsPush)
    await #expect(throws: PullRequestPublicationError.pushRequired) {
      try await fixture.service.publish(unpushed)
    }
    #expect(try await fixture.store.pullRequestPublication(for: unpushed.key) == nil)
    await fixture.remote.setHead(unpushed.checkout.head)
    await #expect(throws: PullRequestPublicationError.staleReview) {
      try await fixture.service.publish(unpushed)
    }
    let reviewed = try await fixture.prepare()
    #expect(reviewed.refs.head == reviewed.checkout.head)
    #expect(try await fixture.service.publish(reviewed).destination == PublicationFixture.handoff)
    let reads = await fixture.remote.refReads
    #expect(Set(reads) == ["owner/project:main...feature"])
  }

  @Test("An old approval cannot open a handoff recorded for a new source commit")
  func staleApprovalCannotUseNewHandoff() async throws {
    let fixture = try PublicationFixture()
    let stale = try await fixture.prepare()
    fixture.git.setHead("new-review")
    await fixture.remote.setHead("new-review")
    let reviewed = try await fixture.prepare()
    #expect(try await fixture.service.publish(reviewed).destination == PublicationFixture.handoff)
    await #expect(throws: PullRequestPublicationError.staleReview) {
      try await fixture.service.publish(stale)
    }
  }

  @Test("Prior closed PRs for the same branch leave new commits available for review")
  func oldClosedRequestsDoNotBlockReview() async throws {
    let fixture = try PublicationFixture()
    await fixture.remote.setRequests([PublicationFixture.closed(number: 2, head: "old-commit")])
    let plan = try await fixture.prepare()
    #expect(plan.checkout.head == "reviewed")
    #expect(try await fixture.service.publish(plan).destination == PublicationFixture.handoff)
  }

  @Test("Recovery prefers an exact ref match over an unrelated open PR", arguments: [true, false])
  func verifiesExactHistory(isOpen: Bool) async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    _ = try await fixture.service.publish(plan)
    let exact = isOpen ? PublicationFixture.request : PublicationFixture.closed(number: 4, head: plan.checkout.head)
    let unrelated = GitHubPublishedPullRequest(
      number: 7, url: URL(string: "https://github.com/owner/project/pull/7")!,
      head: plan.checkout.head, branch: "feature", base: "different-base", baseOID: "different-base-commit")
    let history = PublicationFixture.closed(number: 6, head: "newer-history")
    await fixture.remote.setRequests([unrelated, history, exact])
    #expect(try await fixture.service.prepare(fixture.context) == .existing(exact))
    #expect(try await fixture.store.pullRequestPublication(for: plan.key)?.phase == .verified)
  }

  @Test("An open PR blocks a reused branch until closed, even when its head moved after verification")
  func retiresPriorVerifiedHandoff() async throws {
    let fixture = try PublicationFixture()
    let prior = try await fixture.prepare()
    _ = try await fixture.service.publish(prior)
    await fixture.remote.setRequest(PublicationFixture.request)
    #expect(try await fixture.service.prepare(fixture.context) == .existing(PublicationFixture.request))
    let journal = try #require(try await fixture.store.pullRequestPublication(for: prior.key))
    #expect(journal.phase == .verified)
    fixture.git.setHead("new-review")
    await fixture.remote.setHead("new-review")
    #expect(try await fixture.service.prepare(fixture.context) == .existing(PublicationFixture.request))
    await fixture.remote.setRequest(PublicationFixture.closed(number: 4, head: "changed-before-close"))
    let current = try await fixture.prepare()
    #expect(current.checkout.head == "new-review")
    #expect(try await fixture.store.pullRequestPublication(for: prior.key) == nil)
    _ = try await fixture.service.publish(current)
    #expect(try await fixture.store.pullRequestPublication(for: prior.key)?.phase == .handedOff)
    #expect(try await fixture.store.retireVerifiedPullRequestPublication(id: journal.id) == false)
  }

  @Test("The old local head can be reviewed after the verified PR closes on a later commit")
  func retiresVerifiedWithSameLocalHead() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    _ = try await fixture.service.publish(plan)
    await fixture.remote.setRequest(PublicationFixture.request)
    _ = try await fixture.service.prepare(fixture.context)
    await fixture.remote.setRequest(PublicationFixture.closed(number: 4, head: "changed-before-close"))
    await fixture.remote.setHead("changed-before-close")
    let refreshed = try await fixture.prepare()
    #expect(refreshed.checkout.head == plan.checkout.head)
    #expect(refreshed.needsPush)
    #expect(try await fixture.store.pullRequestPublication(for: plan.key) == nil)
  }

  @MainActor
  @Test("A legacy session can confirm and reopen a handoff from another session on the same branch",
        arguments: [true, false])
  func legacySessionReopensSharedHandoff(refsAlreadyMatch: Bool) async throws {
    let fixture = try PublicationFixture()
    let prepared = try await fixture.prepare()
    let original = try #require(try await fixture.service.publish(prepared).handoff)
    let session = CLISession(id: "legacy", projectPath: fixture.context.projectPath, branchName: fixture.context.branch)
    let model = CreatePullRequestAction(
      session: session, provider: .codex, title: "Legacy fixture", origin: nil, service: fixture.service,
      observation: nil, target: .currentBranch(projectPath: session.projectPath, branchName: session.branchName))
    if !refsAlreadyMatch { await fixture.remote.setHead("remote-moved") }
    await model.prepare()
    #expect(model.phase == .confirmingRepository(PublicationFixture.repository))
    model.repositoryName = "owner/project"
    await model.confirmRepository()
    #expect(model.context.repository == PublicationFixture.repository)
    if !refsAlreadyMatch {
      #expect(model.phase == .pending(original.record.id))
      await fixture.remote.setHead(prepared.checkout.head)
      await model.check()
    }
    #expect(await model.reopenHandoff() == original.destination)
  }

  @Test("A handoff must revalidate the GitHub commits before reopening")
  func reopenedHandoffChecksRefs() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    let handoff = try #require(try await fixture.service.publish(plan).handoff)
    let id = handoff.record.id
    #expect(try await fixture.service.reopenHandoff(fixture.context, expectedID: id).destination == handoff.destination)
    await fixture.remote.setHead("remote-moved")
    #expect(try await fixture.service.reopenHandoff(fixture.context, expectedID: id) == .pending(id))
    #expect(try await fixture.store.pullRequestPublication(for: plan.key)?.id == id)
  }

  @Test("A stale sheet cannot reopen or discard a replacement handoff")
  func staleSheetPreservesNewHandoff() async throws {
    let fixture = try PublicationFixture()
    let firstPlan = try await fixture.prepare()
    let first = try #require(try await fixture.service.publish(firstPlan).handoff)
    fixture.git.setHead("new-head")
    await fixture.remote.setHead("new-head")
    let result = try await fixture.service.reviewCurrentCommits(fixture.context, expectedID: first.record.id)
    guard case .review(let secondPlan) = result else {
      Issue.record("Expected to review the new commit")
      return
    }
    let second = try #require(try await fixture.service.publish(secondPlan).handoff)
    await #expect(throws: PullRequestPublicationError.staleReview) {
      try await fixture.service.reviewCurrentCommits(fixture.context, expectedID: first.record.id)
    }
    await #expect(throws: PullRequestPublicationError.staleReview) {
      try await fixture.service.reopenHandoff(fixture.context, expectedID: first.record.id)
    }
    #expect(try await fixture.store.pullRequestPublication(for: firstPlan.key) == second.record)
  }

  @Test("Reopening verifies the journal again after a suspended GitHub ref read")
  func reopensOnlyTheSameRecordAfterAwait() async throws {
    let fixture = try PublicationFixture()
    let plan = try await fixture.prepare()
    let first = try #require(try await fixture.service.publish(plan).handoff)
    let old = first.record
    let replacement = PullRequestPublicationRecord(
      id: UUID(), key: old.key, base: old.base, baseOID: old.baseOID, head: old.head,
      sessionID: old.sessionID, provider: old.provider, phase: .handedOff)
    let store = fixture.store
    await fixture.remote.onNextRefsRead {
      #expect(try await store.advancePullRequestPublication(id: old.id, from: .handedOff, to: .preparing))
      try await store.abandonPullRequestPreparation(id: old.id)
      #expect(try await store.beginPullRequestPublication(replacement))
    }
    #expect(try await fixture.service.reopenHandoff(fixture.context, expectedID: old.id) == .pending(nil))
    #expect(try await fixture.store.pullRequestPublication(for: plan.key) == replacement)
  }

}

private extension PullRequestPreparation {
  var handoff: PullRequestHandoff? {
    if case .handoff(let handoff) = self { return handoff }
    return nil
  }

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
  static func closed(number: Int, head: String) -> GitHubPublishedPullRequest {
    .init(number: number, url: URL(string: "https://github.com/owner/project/pull/\(number)")!,
          head: head, branch: "feature", base: "main", baseOID: "base-commit", isOpen: false)
  }

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
  private var remote = PublicationFixture.repository
  private var error: PullRequestPublicationError?

  func setRemote(_ value: GitHubRepositoryIdentity) { lock.withLock { remote = value } }
  func setHead(_ value: String) { lock.withLock { localHead = value } }
  func failCheckout(with error: PullRequestPublicationError) { lock.withLock { self.error = error } }

  func origin(_ context: PullRequestContext) throws -> GitHubRepositoryIdentity {
    lock.withLock { remote }
  }

  func checkout(_ context: PullRequestContext) throws -> PullRequestCheckout {
    try lock.withLock {
      if let error { throw error }
      return .init(root: context.projectPath, remote: remote, branch: "feature", head: localHead)
    }
  }
  func files(_ checkout: PullRequestCheckout, base: String) -> [String] {
    ["Read Me.md", "Sources/main.swift"]
  }

}

private actor PublicationRemoteFixture: GitHubReviewedPublishing {
  private var requests: [GitHubPublishedPullRequest] = []
  private var head: String? = "reviewed"
  private var baseHead = "base-commit"
  private var authenticated = true
  private var allowedLookups: Int?
  private var refReadHook: (@Sendable () async throws -> Void)?
  private(set) var lookedUpRepositories: [GitHubRepositoryIdentity] = []
  private(set) var refReads: [String] = []
  func failLookup(after count: Int?) { allowedLookups = count }
  func setAuthenticated(_ value: Bool) { authenticated = value }
  func setRequest(_ value: GitHubPublishedPullRequest) { requests = [value] }
  func setRequests(_ values: [GitHubPublishedPullRequest]) { requests = values }
  func setHead(_ value: String?) { head = value }
  func setBase(_ value: String) { baseHead = value }
  func onNextRefsRead(_ hook: @escaping @Sendable () async throws -> Void) { refReadHook = hook }

  func publicationBase(in repository: GitHubRepositoryIdentity) throws -> String {
    if !authenticated { throw GitHubCLIError.notAuthenticated }
    return "main"
  }

  func publicationRefs(
    in repository: GitHubRepositoryIdentity, base: String, branch: String
  ) async throws -> GitHubPublicationRefs {
    if !authenticated { throw GitHubCLIError.notAuthenticated }
    refReads.append("\(repository.owner)/\(repository.repository):\(base)...\(branch)")
    let hook = refReadHook
    refReadHook = nil
    try await hook?()
    return .init(base: baseHead, head: head)
  }

  func publicationPullRequests(
    in repository: GitHubRepositoryIdentity, branch: String
  ) throws -> [GitHubPublishedPullRequest] {
    if !authenticated { throw GitHubCLIError.notAuthenticated }
    if let allowedLookups {
      guard allowedLookups > 0 else { throw GitHubCLIError.timeout }
      self.allowedLookups = allowedLookups - 1
    }
    lookedUpRepositories.append(repository)
    return requests
  }
}

@Suite("Reviewed publication Git transport")
struct PullRequestGitRewriteTests {
  @Test("Chained fetch and push URL rewrites cannot redirect the pinned GitHub reads",
        arguments: ["insteadOf", "pushInsteadOf"])
  func transportUsesRepositoryAPI(spelling: String) async throws {
    let directory = try PublicationTemporaryDirectory()
    let path = directory.url.path
    let fixtureGit = RecordingPublicationGitRunner()
    func git(_ arguments: [String]) throws -> String {
      let result = try fixtureGit.run(at: path, arguments: arguments, environment: [:], input: nil)
      try #require(result.status == 0)
      return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    _ = try git(["init", "--quiet", "--initial-branch=feature"])
    let author = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"]
    _ = try git(author + ["commit", "--quiet", "--allow-empty", "-m", "Base"])
    let base = try git(["rev-parse", "HEAD"])
    try Data("reviewed change".utf8).write(to: directory.url.appendingPathComponent("Change.txt"))
    _ = try git(["add", "--", "Change.txt"])
    _ = try git(author + ["commit", "--quiet", "-m", "Source"])
    let source = try git(["rev-parse", "HEAD"])
    _ = try git(["remote", "add", "origin", "synthetic:owner/project"])
    _ = try git(["config", "--add", "url.https://github.com/.insteadOf", "synthetic:"])
    _ = try git(["config", "--add", "url.https://example.invalid/.\(spelling)", "https://github.com/"])
    let first = try git(["remote", "get-url", "--push", "origin"])
    #expect(first == "https://github.com/owner/project")
    _ = try git(["remote", "add", "probe", first])
    #expect(try git(["remote", "get-url", "--push", "probe"]) == "https://example.invalid/owner/project")
    if spelling == "insteadOf" {
      #expect(try git(["ls-remote", "--get-url", "--", first]) == "https://example.invalid/owner/project")
    }

    let count = fixtureGit.commands.count
    let remote = PublicationRemoteFixture()
    await remote.setBase(base)
    await remote.setHead(source)
    let store = try SessionMetadataStore(databaseQueue: DatabaseQueue())
    let service = PullRequestPublicationService(git: ReviewedPullRequestGit(runner: fixtureGit), remote: remote, store: store)
    let context = PullRequestContext(
      sessionID: "fixture", provider: .codex, projectPath: path, branch: "feature",
      repository: PublicationFixture.repository)
    guard case .review(let plan) = try await service.prepare(context) else {
      Issue.record("Expected a review for the independently confirmed repository")
      return
    }
    #expect(plan.files == ["Change.txt"])
    #expect(try await service.publish(plan).destination == PublicationFixture.handoff)
    let appCommands = fixtureGit.commands.dropFirst(count)
    #expect(appCommands.allSatisfy { !$0.contains("push") && !$0.contains("ls-remote") })
    #expect(appCommands.contains { $0.first == "diff" && $0.contains("--ignore-submodules=none") })
    let appEnvironment = fixtureGit.environments.dropFirst(count)
    #expect(appEnvironment.allSatisfy {
      $0["GIT_ALLOW_PROTOCOL"] == "" && $0["GIT_NO_LAZY_FETCH"] == "1" && $0["GIT_NO_REPLACE_OBJECTS"] == "1"
    })
    #expect(Set(await remote.refReads) == ["owner/project:main...feature"])
  }
}

private final class RecordingPublicationGitRunner: CommitGitRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let underlying = CommitGitRunner()
  private var recorded: [(arguments: [String], environment: [String: String])] = []

  var commands: [[String]] { lock.withLock { recorded.map(\.arguments) } }
  var environments: [[String: String]] { lock.withLock { recorded.map(\.environment) } }

  func run(at path: String, arguments: [String], environment: [String: String], input: Data?) throws -> CommitGitOutput {
    lock.withLock { recorded.append((arguments, environment)) }
    var isolated = environment
    isolated["GIT_CONFIG_GLOBAL"] = "/dev/null"
    isolated["GIT_CONFIG_NOSYSTEM"] = "1"
    return try underlying.run(at: path, arguments: arguments, environment: isolated, input: input)
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
  func abandonPullRequestPreparation(id: UUID) async throws {
    try await store.abandonPullRequestPreparation(id: id)
  }

  func retireVerifiedPullRequestPublication(id: UUID) async throws -> Bool {
    try await store.retireVerifiedPullRequestPublication(id: id)
  }

}
