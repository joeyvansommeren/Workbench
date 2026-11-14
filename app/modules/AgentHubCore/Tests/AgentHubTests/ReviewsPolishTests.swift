import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Reviews polish")
struct ReviewsPolishTests {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  // MARK: - Copy

  @Test("Counted nouns agree with the count")
  func countedNouns() {
    #expect(ReviewsCopy.count(1, "session") == "1 session")
    #expect(ReviewsCopy.count(3, "session") == "3 sessions")
    #expect(ReviewsCopy.count(1, "pull request") == "1 pull request")
    #expect(ReviewsCopy.count(0, "file") == "0 files")
  }

  @Test("Bulk confirmations use plurals and the agent's product name")
  func bulkCopy() {
    let one = GitHubReviewBulkLaunch(
      pullRequests: [pullRequest("a")], provider: .codex, template: template)
    #expect(one.title == "Start 1 Codex session?")
    #expect(!one.isLarge)

    let many = GitHubReviewBulkLaunch(
      pullRequests: (0..<GitHubReviewBulkLaunch.largeLaunchThreshold).map { pullRequest("\($0)") },
      provider: .claude, template: template)
    #expect(many.isLarge)
    #expect(many.title == "Start 10 Claude Code sessions at once?")
    #expect(many.message.contains("stop them"))

    let reReviewOne = GitHubReviewBulkFollowUp(
      kind: .reReview, targets: [target("a")], skippedWithoutSession: 0)
    #expect(reReviewOne.title == "Re-review 1 pull request?")
    let reReviewTwo = GitHubReviewBulkFollowUp(
      kind: .reReview, targets: [target("a"), target("b")], skippedWithoutSession: 0)
    #expect(reReviewTwo.title == "Re-review 2 pull requests?")

    let resolveOne = GitHubReviewBulkFollowUp(
      kind: .resolveComments, targets: [target("a")], skippedWithoutSession: 1)
    #expect(resolveOne.title == "Resolve comments on your pull request?")
    #expect(resolveOne.message.hasSuffix("1 without a session is skipped."))
  }

  // MARK: - Bulk progress

  @Test("Bulk launch progress counts from 1 and stops at the total")
  func bulkProgress() {
    var progress = ReviewsBulkLaunchProgress(total: 3)
    #expect(progress.text == "Starting 1 of 3")
    #expect(!progress.isFinished)
    progress.begin()
    progress.advance()
    #expect(progress.text == "Starting 2 of 3")
    #expect(progress.started == 1)
    // A skipped pull request moves on without counting as started.
    progress.advance()
    progress.begin()
    progress.advance()
    #expect(progress.isFinished)
    progress.advance()
    #expect(progress.started == 2)
    #expect(progress.text == "Starting 3 of 3")
  }

  @Test("Stop mid-run counts the launch in flight, and it still finishes")
  func bulkStopMidRun() async {
    let runner = ReviewsBulkLaunchRunner()
    let gate = LaunchGate()
    runner.run(["a", "b", "c"], begin: { _ in true }, launch: { await gate.launch($0) })

    gate.release("a")
    await gate.waitForLaunch("b")
    #expect(runner.progress?.started == 2)
    #expect(runner.stop() == 2)
    #expect(runner.progress == nil)

    gate.release("b")
    await runner.waitUntilDone()
    // "b" ran to its end; "c" never started.
    #expect(gate.finished == ["a", "b"])
  }

  @Test("A pull request already starting is skipped and not counted")
  func bulkSkipsBusy() async {
    let runner = ReviewsBulkLaunchRunner()
    let gate = LaunchGate()
    runner.run(["a", "busy", "c"], begin: { $0 != "busy" }, launch: { await gate.launch($0) })

    gate.release("a")
    await gate.waitForLaunch("c")
    #expect(gate.launched == ["a", "c"])
    #expect(runner.progress?.started == 2)
    #expect(runner.progress?.text == "Starting 3 of 3")
    #expect(runner.stop() == 2)
    gate.release("c")
  }

  @Test("A new run supersedes the old one; the old loop leaves the new progress alone")
  func bulkSupersededRun() async {
    let runner = ReviewsBulkLaunchRunner()
    let gate = LaunchGate()
    runner.run(["old1", "old2"], begin: { _ in true }, launch: { await gate.launch($0) })
    await gate.waitForLaunch("old1")

    runner.run(["new1", "new2", "new3"], begin: { _ in true }, launch: { await gate.launch($0) })
    gate.release("old1")
    await gate.waitForLaunch("new1")
    #expect(runner.progress?.total == 3)
    #expect(runner.progress?.started == 1)
    // The old loop never reached "old2".
    #expect(!gate.launched.contains("old2"))

    gate.release("new1")
    gate.release("new2")
    gate.release("new3")
    gate.releasesEverything = true
    await runner.waitUntilDone()
    #expect(runner.progress == nil)
  }

  // MARK: - Review button

  @Test("Review with is enabled only with the agent installed, nothing starting and a prompt")
  func primaryReviewEnabled() {
    #expect(control(available: true, starting: false, templates: [template]).isPrimaryEnabled)
    #expect(!control(available: false, starting: false, templates: [template]).isPrimaryEnabled)
    #expect(!control(available: true, starting: true, templates: [template]).isPrimaryEnabled)
    #expect(!control(available: true, starting: false, templates: []).isPrimaryEnabled)
  }

  // MARK: - Link cache

  @Test("The link cache recomputes only when the key changes")
  func linkCacheKey() {
    let cache = ReviewsSessionLinkCache()
    var computed = 0
    let compute: () -> [String: [GitHubReviewSessionLink]] = {
      computed += 1
      return ["pr": [link("s1", status: .idle)]]
    }
    _ = cache.links(key: 1, compute: compute)
    _ = cache.links(key: 1, compute: compute)
    #expect(computed == 1)
    _ = cache.links(key: 2, compute: compute)
    #expect(computed == 2)
  }

  @Test("Cached links get the current status; pending links keep none")
  func linkCacheStatuses() {
    let links = ["pr": [link("s1", status: .idle), link("pending", status: nil, isPending: true)]]
    let updated = ReviewsSessionLinkCache.applyingStatuses(
      links, statuses: [.claude: ["s1": .thinking, "pending": .thinking]])
    #expect(updated["pr"]?[0].status == .thinking)
    #expect(updated["pr"]?[0].displayName == "s1")
    #expect(updated["pr"]?[1].status == nil)

    // A session with no status any more loses the old one.
    let cleared = ReviewsSessionLinkCache.applyingStatuses(links, statuses: [:])
    #expect(cleared["pr"]?[0].status == nil)
  }

  @Test("Two sessions on one pull request: working in the older one rebuilds the links, so the linker can make it primary")
  func linkKeyFollowsActivity() {
    func key(_ sessions: [CLISession]) -> Int {
      var hasher = Hasher()
      for session in sessions { ReviewSessionSupport.combineSessionKey(session, into: &hasher) }
      return hasher.finalize()
    }
    func session(_ id: String, _ activity: TimeInterval) -> CLISession {
      CLISession(
        id: id, projectPath: "/tmp/xfa-dashboard", branchName: "main",
        lastActivityAt: now.addingTimeInterval(activity))
    }
    let before = key([session("first", -600), session("second", -120)])
    // The user works in "first" a few minutes later.
    let after = key([session("first", 0), session("second", -120)])
    #expect(before != after)
    // Updates within the same minute keep the cached links.
    let minuteStart = Double(ReviewSessionSupport.activityMinute(now) * 60) - now.timeIntervalSince1970
    #expect(
      key([session("first", minuteStart), session("second", -120)])
        == key([session("first", minuteStart + 30), session("second", -120)]))
  }

  // MARK: - Layout

  @Test("The Reviews bar matches the shared list head")
  func barHeight() {
    #expect(ReviewsLayout.barHeight == 56)
  }

  // MARK: - Helpers

  private var template: GitHubPromptTemplate {
    GitHubPromptTemplate(id: "t", name: "Review", prompt: "Review", builtInKind: nil)
  }

  private func control(
    available: Bool, starting: Bool, templates: [GitHubPromptTemplate]
  ) -> PullRequestReviewControl {
    PullRequestReviewControl(
      agent: .claude, templates: templates, isStarting: starting,
      isAgentAvailable: { _ in available }, onSelectAgent: { _ in }, onReview: { _, _ in },
      onWriteOwnMessage: { _ in })
  }

  private func pullRequest(_ id: String) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: id, number: 1, title: "Pull request \(id)",
      url: "https://github.com/xfa/xfa-dashboard/pull/1", repositoryName: "xfa-dashboard",
      repositoryNameWithOwner: "xfa/xfa-dashboard", authorLogin: "someone",
      updatedAt: now, isDraft: false, state: "open", projectStatus: nil, projectPriority: nil)
  }

  private func target(_ id: String) -> GitHubReviewBulkFollowUp.Target {
    GitHubReviewBulkFollowUp.Target(pullRequest: pullRequest(id), link: link(id, status: .idle))
  }

  private func link(
    _ name: String, status: SessionStatus?, isPending: Bool = false
  ) -> GitHubReviewSessionLink {
    GitHubReviewSessionLink(
      provider: .claude,
      session: CLISession(
        id: name, projectPath: "/tmp/xfa-dashboard", branchName: "main", lastActivityAt: now,
        firstMessage: nil),
      itemID: "claude-\(name)", isPending: isPending, displayName: name, status: status)
  }
}

/// Holds each launch until the test releases it.
@MainActor
private final class LaunchGate {
  private(set) var launched: [String] = []
  private(set) var finished: [String] = []
  private var holds: [String: CheckedContinuation<Void, Never>] = [:]
  private var released: Set<String> = []
  var releasesEverything = false

  func launch(_ item: String) async {
    launched.append(item)
    if !releasesEverything, !released.contains(item) {
      await withCheckedContinuation { holds[item] = $0 }
    }
    finished.append(item)
  }

  func release(_ item: String) {
    released.insert(item)
    holds.removeValue(forKey: item)?.resume()
  }

  func waitForLaunch(_ item: String) async {
    while !launched.contains(item) { await Task.yield() }
  }
}
