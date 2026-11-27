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
        try output.write(to: URL(fileURLWithPath: "/private/tmp/tes321-v25-header-\(Int(width))-\(appearance).png"))
        #expect(image.pixelsWide >= Int(width))
      }
    }
  }

  @Test("The native review sheet presents full commit IDs in both themes")
  func captureReviewSheet() async throws {
    let repository = GitHubRepositoryIdentity(owner: "fixture", repository: "workbench")
    let origin = SessionLaunchOrigin(
      source: .linear, accountID: "fixture-account", sourceID: "fixture-ticket",
      key: "FIX-42", title: "Review the branch and commits before opening GitHub", publicationRepository: repository)
    let session = CLISession(
      id: "fixture", projectPath: "/fixture", branchName: "codex/fixture-publication")
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: session.projectPath, branchName: session.branchName)
    for scheme in [ColorScheme.light, .dark] {
      let review = CreatePullRequestAction(
        session: session, provider: .codex, title: "Fixture", origin: origin,
        service: ReviewFixtureService(), observation: nil, target: target)
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
      try output.write(to: URL(fileURLWithPath: "/private/tmp/tes321-v25-review-\(appearance).png"))
      #expect(image.pixelsWide >= Int(frame.width))
    }
  }

}


private struct ReviewFixtureService: PullRequestPublicationServiceProtocol {
  func prepare(_ context: PullRequestContext) async throws -> PullRequestPreparation {
    let repository = GitHubRepositoryIdentity(owner: "fixture", repository: "workbench")
    let checkout = PullRequestCheckout(
      root: context.projectPath, remote: repository, pushURL: "git@github.com:fixture/workbench.git",
      branch: "codex/fixture-publication", head: String(repeating: "a", count: 40))
    let refs = PullRequestRefs(base: String(repeating: "b", count: 40), head: nil)
    return .review(.init(context: context, checkout: checkout, baseBranch: "main", refs: refs,
                         files: ["Sources/Reviewed change.swift", "Tests/Cases with long folder names/Approval.swift"]))
  }

  func confirmRepository(_ context: PullRequestContext, name: String) async throws -> PullRequestPreparation {
    try await prepare(context)
  }

  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation { .pending }

  func reviewCurrentCommits(_ context: PullRequestContext) async throws -> PullRequestPreparation {
    try await prepare(context)
  }
}
