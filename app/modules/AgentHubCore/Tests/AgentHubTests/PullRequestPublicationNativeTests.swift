import AgentHubGitHub
import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Publication action native layout", .serialized)
struct PullRequestPublicationNativeTests {
  @Test("The session header hosts the publication action at compact and regular widths")
  func captureHeader() async throws {
    for width in [260.0, 560.0, 800.0] {
      for scheme in [ColorScheme.light, .dark] {
        let header = SessionHeaderView(
          presentation: .init(
            id: "fixture", title: "Restore Wiśniewska-Kowalczyk’s workspace after an interrupted build",
            providerKind: .codex, repositoryName: "native-fixture", repositoryPath: "/fixture",
            branchName: "codex/a-long-feature-branch-name", status: .responseReady, isPending: false),
          progress: .init(state: .init(status: .responseReady), projectPath: "/fixture"),
          onProgressAction: {}, publicationSuggestion: .create, onPublicationAction: {},
          contextFraction: 0.43, availableContentModes: [.terminal, .editor, .diffs],
          contentMode: .constant(.terminal), showsResult: false, onToggleResult: {},
          isSidePanelVisible: true, onToggleSidePanel: {}, actionsMenu: { _ in EmptyView() }
        )
        let content = header
          .frame(width: width, alignment: .leading)
          .environment(\.colorScheme, scheme)
          .background(Color.wbSurfaceRaised)
        let window = BackgroundTestWindow(
          contentRect: CGRect(x: 0, y: 0, width: width, height: 150),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: 150)
        defer {
          window.orderOut(nil)
          window.contentView = nil
          window.close()
        }
        window.presentForTesting()
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rect = CGRect(x: 0, y: 0, width: width, height: host.bounds.height)
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: image)
        let output = try #require(image.representation(using: .png, properties: [:]))
        let appearance = scheme == .light ? "light" : "dark"
        try output.write(to: URL(fileURLWithPath: "/private/tmp/tes321-pinned-header-\(Int(width))-\(appearance).png"))
        #expect(image.pixelsWide >= Int(width))
      }
    }
  }

  @Test("The native review sheet presents full commit IDs in both themes")
  func captureReviewSheet() async throws {
    for scheme in [ColorScheme.light, .dark] {
      let review = makeReview(service: ReviewFixtureService())
      await review.prepare()
      #expect(review.phase == .reviewing)
      let content = PullRequestReviewSheet(model: review)
        .environment(\.colorScheme, scheme)
        .background(Color.wbSurfaceRaised)
      let frame = CGRect(x: 0, y: 0, width: 540, height: 500)
      let window = BackgroundTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: content)
      window.contentView = host
      host.frame = frame
      defer {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
      window.presentForTesting()
      await Task.yield()
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let output = try #require(image.representation(using: .png, properties: [:]))
      let appearance = scheme == .light ? "light" : "dark"
      try output.write(to: URL(fileURLWithPath: "/private/tmp/tes321-pinned-review-\(appearance).png"))
      #expect(image.pixelsWide >= Int(frame.width))
    }
  }

  @Test("Rechecking and publishing show progress while the reviewed scope is retained")
  func progressWithReviewedScope() async {
    let service = ReviewFixtureService()
    let review = makeReview(service: service)
    let sheet = PullRequestReviewSheet(model: review)
    await review.prepare()
    #expect(sheet.progressMessage == nil)

    await confirmation("Checks show progress") { checking in
      service.onPrepare = {
        #expect(review.phase == .checking)
        #expect(review.plan != nil)
        #expect(sheet.progressMessage == "Checking the branch on GitHub…")
        checking()
      }
      await review.check()
      service.onPrepare = nil
    }

    await confirmation("Publishing shows progress") { publishing in
      service.onPublish = {
        #expect(review.phase == .publishing)
        #expect(review.plan != nil)
        #expect(sheet.progressMessage == "Checking the reviewed commits…")
        publishing()
      }
      await review.publish()
      service.onPublish = nil
    }
    #expect(sheet.progressMessage == nil)
  }

  @Test("The review sheet only uses ready checks for the verified PR head")
  func checksMatchVerifiedHead() throws {
    let url = try #require(URL(string: "https://github.com/fixture/workbench/pull/4"))
    let request = GitHubPublishedPullRequest(
      number: 4, url: url, head: "verified", branch: "feature", base: "main", baseOID: "base")

    func snapshot(head: String?, state: GitHubPRObservationState = .ready) -> GitHubPRObservationSnapshot {
      let observed = GitHubPullRequest(
        number: request.number, title: "Fixture", body: nil, state: "OPEN", url: url.absoluteString,
        headRefName: request.branch, headRefOid: head, baseRefName: request.base, author: nil,
        createdAt: nil, updatedAt: nil, isDraft: true, mergeable: nil, additions: 0,
        deletions: 0, changedFiles: 0, reviewDecision: nil, statusCheckRollup: nil,
        labels: nil, reviewRequests: nil, comments: nil)
      return GitHubPRObservationSnapshot(
        target: .currentBranch(projectPath: "/fixture", branchName: request.branch), pullRequest: observed,
        checks: [], state: state, lastRefreshedAt: Date(timeIntervalSince1970: 1))
    }

    let matching = snapshot(head: request.head)
    #expect(PullRequestReviewSheet.currentChecks(matching, for: request) == matching.ciSummary)
    #expect(PullRequestReviewSheet.currentChecks(snapshot(head: "previous"), for: request) == nil)
    #expect(PullRequestReviewSheet.currentChecks(snapshot(head: nil), for: request) == nil)
    #expect(PullRequestReviewSheet.currentChecks(snapshot(head: request.head, state: .error("Offline")), for: request) == nil)
  }

  private func makeReview(service: ReviewFixtureService) -> CreatePullRequestAction {
    let repository = GitHubRepositoryIdentity(owner: "fixture", repository: "workbench")
    let origin = SessionLaunchOrigin(
      source: .linear, accountID: "fixture-account", sourceID: "fixture-ticket",
      key: "FIX-42", title: "Review the branch and commits before opening GitHub", publicationRepository: repository)
    let session = CLISession(
      id: "fixture", projectPath: "/fixture", branchName: "codex/fixture-publication")
    return CreatePullRequestAction(
      session: session, provider: .codex, title: "Fixture", origin: origin,
      service: service, observation: nil,
      target: .currentBranch(projectPath: session.projectPath, branchName: session.branchName))
  }
}

@MainActor
private final class ReviewFixtureService: PullRequestPublicationServiceProtocol {
  var onPrepare: (() -> Void)?
  var onPublish: (() -> Void)?

  func prepare(_ context: PullRequestContext) async throws -> PullRequestPreparation {
    onPrepare?()
    let repository = GitHubRepositoryIdentity(owner: "fixture", repository: "workbench")
    let checkout = PullRequestCheckout(
      root: context.projectPath, remote: repository,
      branch: "codex/fixture-publication", head: String(repeating: "a", count: 40))
    let refs = GitHubPublicationRefs(base: String(repeating: "b", count: 40), head: checkout.head)
    return .review(.init(context: context, checkout: checkout, baseBranch: "main", refs: refs,
                         files: ["Sources/Reviewed change.swift", "Tests/Cases with long folder names/Approval.swift"]))
  }

  func confirmRepository(_ context: PullRequestContext, name: String) async throws
    -> (context: PullRequestContext, preparation: PullRequestPreparation)
  {
    (context, try await prepare(context))
  }

  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation {
    onPublish?()
    return .pending(nil)
  }

  func reopenHandoff(_ context: PullRequestContext, expectedID: UUID) async throws -> PullRequestPreparation {
    .pending(expectedID)
  }

  func reviewCurrentCommits(_ context: PullRequestContext, expectedID: UUID) async throws -> PullRequestPreparation {
    try await prepare(context)
  }
}
