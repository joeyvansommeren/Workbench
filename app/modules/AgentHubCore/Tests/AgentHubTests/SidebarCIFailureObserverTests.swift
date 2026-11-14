//
//  SidebarCIFailureObserverTests.swift
//  AgentHubTests
//
//  The new interface's CI-failure notifications: which sessions are observed
//  as the monitored set changes, and that snapshots reach the shared notifier
//  with the session's context. Also the first-run empty sidebar rule.
//

import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Fakes

private actor FakeObservationService: GitHubPRObservationServiceProtocol {
  private(set) var subscribedTargets: [GitHubPRObservationTarget] = []
  private(set) var unsubscribedIDs: [UUID] = []
  private(set) var activity: [Date] = []
  private var continuations: [UUID: AsyncStream<GitHubPRObservationSnapshot>.Continuation] = [:]

  private var holdsSubscriptions = false
  private var heldSubscriptions: [CheckedContinuation<Void, Never>] = []
  private(set) var subscribeCallsStarted = 0

  /// Later `subscribe` calls wait until `releaseSubscriptions()`.
  func holdSubscriptions() { holdsSubscriptions = true }

  func releaseSubscriptions() {
    holdsSubscriptions = false
    heldSubscriptions.forEach { $0.resume() }
    heldSubscriptions = []
  }

  func subscribe(
    to target: GitHubPRObservationTarget,
    refreshOnSubscribe: Bool
  ) async -> GitHubPRObservationSubscription {
    subscribeCallsStarted += 1
    if holdsSubscriptions { await withCheckedContinuation { heldSubscriptions.append($0) } }
    subscribedTargets.append(target)
    let id = UUID()
    let (stream, continuation) = AsyncStream<GitHubPRObservationSnapshot>.makeStream()
    continuations[id] = continuation
    return GitHubPRObservationSubscription(id: id, updates: stream)
  }

  func unsubscribe(subscriptionID: UUID) async {
    unsubscribedIDs.append(subscriptionID)
    continuations[subscriptionID]?.finish()
    continuations[subscriptionID] = nil
  }

  func refresh(_ target: GitHubPRObservationTarget) async {}

  func recordActivity(for target: GitHubPRObservationTarget, at date: Date) async {
    activity.append(date)
  }

  func send(_ snapshot: GitHubPRObservationSnapshot) {
    for continuation in continuations.values { continuation.yield(snapshot) }
  }
}

@MainActor
private final class RecordingNotifier: GitHubCIFailureNotifierProtocol {
  private(set) var contexts: [GitHubCIFailureSessionContext] = []

  func evaluate(snapshot: GitHubPRObservationSnapshot, context: GitHubCIFailureSessionContext) {
    contexts.append(context)
  }
}

private func makeTarget(
  sessionID: String,
  provider: SessionProviderKind = .claude,
  branch: String? = "feature",
  activity: Date = Date(timeIntervalSince1970: 1_000)
) -> SidebarCIObservationTarget {
  SidebarCIObservationTargets.target(
    itemID: SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID),
    provider: provider,
    session: CLISession(
      id: sessionID, projectPath: "/tmp/repo", branchName: branch, lastActivityAt: activity),
    detected: [],
    associated: []
  )
}

@MainActor
private func waitUntil(_ condition: () async -> Bool) async throws {
  for _ in 0..<100 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(await condition())
}

// MARK: - Observer

@Suite("Sidebar CI-failure observer")
@MainActor
struct SidebarCIFailureObserverTests {

  private func makeObserver(
    service: FakeObservationService?,
    notifier: RecordingNotifier? = nil,
    startupDelay: Duration = .zero
  ) -> SidebarCIFailureObserver {
    SidebarCIFailureObserver(
      observationService: service,
      notifier: notifier,
      startupDelay: { _ in startupDelay }
    )
  }

  @Test("A session removed during its startup delay never subscribes")
  func removedDuringDelayNeverSubscribes() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service, startupDelay: .seconds(60))
    observer.update(targets: [makeTarget(sessionID: "a")])
    #expect(observer.observedKeys.count == 1)

    observer.update(targets: [])
    try await Task.sleep(for: .milliseconds(100))

    #expect(observer.observedKeys.isEmpty)
    #expect(await service.subscribeCallsStarted == 0)
    #expect(await service.unsubscribedIDs.isEmpty)
  }

  @Test("stopAll during the startup delay leaves zero subscriptions")
  func stopAllDuringDelayNeverSubscribes() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service, startupDelay: .seconds(60))
    observer.update(targets: [makeTarget(sessionID: "a"), makeTarget(sessionID: "b")])

    observer.stopAll()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await service.subscribeCallsStarted == 0)
  }

  @Test("Stopped while subscribing: the late subscription is ended")
  func cancelDuringLoadUnsubscribes() async throws {
    let service = FakeObservationService()
    await service.holdSubscriptions()
    let observer = makeObserver(service: service)
    observer.update(targets: [makeTarget(sessionID: "a")])
    try await waitUntil { await service.subscribeCallsStarted == 1 }

    observer.stopAll()
    await service.releaseSubscriptions()

    try await waitUntil { await service.unsubscribedIDs.count == 1 }
    #expect(await service.subscribedTargets.count == 1)
  }

  @Test("After stopAll (shell root disappeared) the same targets observe again")
  func restartsAfterStopAll() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    let targets = [makeTarget(sessionID: "a")]
    observer.update(targets: targets)
    try await waitUntil { await service.subscribedTargets.count == 1 }

    observer.stopAll()
    observer.update(targets: targets)

    #expect(observer.observedKeys == Set(targets.map(\.observationKey)))
    try await waitUntil { await service.subscribedTargets.count == 2 }
    observer.stopAll()
  }

  @Test("Observes every monitored session, not just visible rows")
  func observesAllTargets() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    let targets = [makeTarget(sessionID: "a"), makeTarget(sessionID: "b", provider: .codex)]

    observer.update(targets: targets)

    #expect(observer.observedKeys == Set(targets.map(\.observationKey)))
    try await waitUntil { await service.subscribedTargets.count == 2 }
    observer.stopAll()
  }

  @Test("Removed sessions stop; kept sessions are not re-subscribed")
  func removedSessionsStop() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    let a = makeTarget(sessionID: "a")
    let b = makeTarget(sessionID: "b")
    observer.update(targets: [a, b])
    try await waitUntil { await service.subscribedTargets.count == 2 }

    observer.update(targets: [a])

    #expect(observer.observedKeys == [a.observationKey])
    try await waitUntil { await service.unsubscribedIDs.count == 1 }
    #expect(await service.subscribedTargets.count == 2)
    observer.stopAll()
  }

  @Test("A branch change replaces the session's subscription")
  func branchChangeResubscribes() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    observer.update(targets: [makeTarget(sessionID: "a", branch: "one")])
    try await waitUntil { await service.subscribedTargets.count == 1 }

    let moved = makeTarget(sessionID: "a", branch: "two")
    observer.update(targets: [moved])

    #expect(observer.observedKeys == [moved.observationKey])
    try await waitUntil { await service.subscribedTargets.count == 2 }
    try await waitUntil { await service.unsubscribedIDs.count == 1 }
    observer.stopAll()
  }

  @Test("New activity is recorded without a new subscription")
  func activityIsRecorded() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    observer.update(targets: [makeTarget(sessionID: "a", activity: Date(timeIntervalSince1970: 1))])
    try await waitUntil { await service.activity.count == 1 }

    observer.update(targets: [makeTarget(sessionID: "a", activity: Date(timeIntervalSince1970: 2))])

    try await waitUntil { await service.activity.last == Date(timeIntervalSince1970: 2) }
    #expect(await service.subscribedTargets.count == 1)
    observer.stopAll()
  }

  @Test("Snapshots reach the notifier with the session's context")
  func snapshotsReachNotifier() async throws {
    let service = FakeObservationService()
    let notifier = RecordingNotifier()
    let observer = makeObserver(service: service, notifier: notifier)
    let target = makeTarget(sessionID: "a", provider: .codex)
    observer.update(targets: [target])
    try await waitUntil { await service.subscribedTargets.count == 1 }

    await service.send(
      GitHubPRObservationSnapshot(
        target: .currentBranch(projectPath: "/tmp/repo", branchName: "feature"),
        pullRequest: nil,
        checks: [],
        state: .ready,
        lastRefreshedAt: .now
      ))

    try await waitUntil { notifier.contexts.count == 1 }
    #expect(notifier.contexts.first == target.context)
    observer.stopAll()
  }

  @Test("stopAll unsubscribes everything")
  func stopAllUnsubscribes() async throws {
    let service = FakeObservationService()
    let observer = makeObserver(service: service)
    observer.update(targets: [makeTarget(sessionID: "a"), makeTarget(sessionID: "b")])
    try await waitUntil { await service.subscribedTargets.count == 2 }

    observer.stopAll()

    #expect(observer.observedKeys.isEmpty)
    try await waitUntil { await service.unsubscribedIDs.count == 2 }
  }

  @Test("Without an observation service nothing is observed")
  func noServiceObservesNothing() {
    let observer = makeObserver(service: nil)
    observer.update(targets: [makeTarget(sessionID: "a")])
    #expect(observer.observedKeys.isEmpty)
  }

  @Test("Targets merge detected and associated PR links without duplicates")
  func targetMergesLinks() throws {
    let first = try #require(GitHubPullRequestURLReference(urlString: "https://github.com/o/r/pull/1"))
    let second = try #require(GitHubPullRequestURLReference(urlString: "https://github.com/o/r/pull/2"))
    let target = SidebarCIObservationTargets.target(
      itemID: "item",
      provider: .claude,
      session: CLISession(id: "a", projectPath: "/tmp/repo"),
      detected: [first],
      associated: [first, second]
    )
    #expect(target.linkedPullRequests == [first, second])
  }

  @Test("Startup stagger matches the legacy row (250 ms + 0–1.5 s)")
  func legacyStagger() {
    let delay = SidebarCIFailureObserver.legacyStartupDelay(makeTarget(sessionID: "abc"))
    #expect(delay >= .milliseconds(250))
    #expect(delay < .milliseconds(1_750))
    // One formula, shared with `CollapsibleSessionRow`.
    #expect(delay == SessionCIObservation.startupDelay(sessionID: "abc"))
    // "abc" = 97 + 98 + 99 = 294 → 250 + 294 ms, as the row computed before.
    #expect(delay == .milliseconds(544))
  }
}

// MARK: - First-run sidebar

@Suite("Sidebar first-run empty state")
struct SidebarFirstRunTests {

  @Test("Shows only when both providers loaded and nothing is tracked")
  func rule() {
    #expect(SidebarFirstRun.showsEmptyState(claudeLoaded: true, codexLoaded: true, repositoryCount: 0, sessionCount: 0))
    #expect(!SidebarFirstRun.showsEmptyState(claudeLoaded: false, codexLoaded: true, repositoryCount: 0, sessionCount: 0))
    #expect(!SidebarFirstRun.showsEmptyState(claudeLoaded: true, codexLoaded: false, repositoryCount: 0, sessionCount: 0))
    #expect(!SidebarFirstRun.showsEmptyState(claudeLoaded: true, codexLoaded: true, repositoryCount: 1, sessionCount: 0))
    #expect(!SidebarFirstRun.showsEmptyState(claudeLoaded: true, codexLoaded: true, repositoryCount: 0, sessionCount: 1))
  }
}
