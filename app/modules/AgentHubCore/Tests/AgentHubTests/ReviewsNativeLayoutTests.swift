import AgentHubGitHub
import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Reviews native layout", .serialized)
struct ReviewsNativeLayoutTests {
  // This host exposes no SwiftUI AX children, even in a visible window.
  // Use public scroll-document geometry and inspect the actual rendered PNGs.
  // ReviewsPolishTests exercises the production action methods, not UI presses.
  @Test("Render complete title stress cases for normal and minimum windows")
  func renderTitleStressCases() async throws {
    let title = "Review workspace navigation and preserve every selected item while resizing the window — 界面の確認 👩🏽‍💻 "
      + "LongUnbrokenComponentNameForTheNavigationAndReviewWorkspace"
    let rows = [
      GitHubReviewTableRow(pullRequest: request("draft", title: title, isDraft: true), sessionLinks: []),
      GitHubReviewTableRow(pullRequest: request("ready", title: "Ready for review"), sessionLinks: [])
    ]
    let suite = "reviews-native-columns-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ReviewsColumnPreferences(userDefaults: defaults)

    for restored in [false, true] {
      if restored { preferences.setVisible(true, column: .author, rows: rows) }
      let columns = ReviewsColumnPreferences(userDefaults: defaults).columns(for: rows)
      for width in [CGFloat(1_144), 743, 604, 203] {
        for appearance in [ColorScheme.light, .dark] {
          let view = table(rows: rows, columns: columns).environment(\.colorScheme, appearance)
          let (window, host) = host(view, width: width, height: 720)
          defer { window.close() }
          let scroll = try await scrollView(in: host)
          let document = try #require(scroll.documentView)
          #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
          let mode = restored ? "restored" : "default"
          let scheme = appearance == .light ? "light" : "dark"
          try saveImage(host, name: "workbench-reviews-\(Int(width))-\(scheme)-\(mode)")
          print("REVIEWS_RENDER width=\(width) mode=\(mode) scheme=\(scheme) document=\(document.frame) visible=\(scroll.documentVisibleRect)")
        }
      }
    }
  }

  @Test("Long titles increase actual scroll-document height instead of clipping inside fixed rows")
  func longTitlesGrowRows() async throws {
    let long = String(repeating: "Preserve the complete title and its selected review target 界面 👩🏽‍💻. ", count: 5)
    for width in [CGFloat(1_144), 743, 604, 203] {
      var heights: [CGFloat] = []
      for title in ["Short title", long] {
        let rows = makeRows(title: title)
        let view = table(rows: rows, columns: [.title, .checks, .updated])
        // A small viewport exposes row height instead of the viewport's minimum height.
        let (window, host) = host(view, width: width, height: 40)
        defer { window.close() }
        let scroll = try await scrollView(in: host)
        let document = try #require(scroll.documentView)
        heights.append(document.frame.height)
        #expect(document.frame.width <= scroll.contentView.bounds.width + 1)
      }
      #expect(heights[1] > heights[0], "Long title must increase real content height at \(width) points")
      print("REVIEWS_ROW_HEIGHT width=\(width) short=\(heights[0]) long=\(heights[1])")
    }
  }

  @Test("Render human and agent review controls in the actual detail")
  func renderReviewActions() async throws {
    let selected = request("selected", title: "Review the selected pull request and preserve its exact target")
    let template = GitHubPromptTemplate(
      id: "independent", name: "Independent review", prompt: "Review", builtInKind: .independentReview)
    let control = PullRequestReviewControl(
      agent: .codex, templates: [template], isStarting: false, isAgentAvailable: { _ in true },
      onSelectAgent: { _ in }, onReview: { _, _ in }, onWriteOwnMessage: { _ in })
    for appearance in [ColorScheme.light, .dark] {
      let detail = PullRequestDetailView(
        pullRequest: selected, detail: nil, isLoadingDetail: false, detailError: nil,
        detailUpdatedAt: nil, tileColor: .teal, viewerLogin: nil, sessionLinks: [],
        sessionFeedback: nil, review: control, onOpenSession: { _ in }, onFollowUp: { _, _ in },
        onRefresh: {}, onClose: {})
        .environment(\.colorScheme, appearance)
        .environment(\.openURL, OpenURLAction { _ in .handled })
      let (window, host) = host(detail, width: 400, height: 720)
      defer { window.close() }
      _ = try await scrollView(in: host)
      try saveImage(host, name: "workbench-reviews-detail-\(appearance == .light ? "light" : "dark")")
    }
  }

  private func makeRows(title: String) -> [GitHubReviewTableRow] {
    // One row makes the height comparison independent of lazy row estimates.
    [GitHubReviewTableRow(pullRequest: request("title", title: title), sessionLinks: [])]
  }

  private func table(rows: [GitHubReviewTableRow], columns: [ReviewsTableColumn]) -> some View {
    ReviewsTableView(
      rows: rows.map { ReviewsTableRowPresentation(row: $0, checks: .success) },
      selectedID: nil, sort: nil, columns: columns,
      context: { _ in
        ReviewsTableRowContext(
          tileColor: .teal,
          review: PullRequestReviewControl(
            agent: .codex, templates: [], isStarting: false, isAgentAvailable: { _ in false },
            onSelectAgent: { _ in }, onReview: { _, _ in }, onWriteOwnMessage: { _ in }),
          onOpenSession: nil)
      }, onSort: { _ in }, onSelect: { _ in }, onMoveSelection: { _ in },
      isDetailOpen: false, onOpenDetail: {}, onCloseDetail: {})
      // The shell supplies this surface through ContentPanel in the running app.
      .background(Color.wbSurfaceContent)
  }

  private func request(_ id: String, title: String, isDraft: Bool = false) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: id, number: 42, title: title, url: "https://github.com/example/\(id)/pull/42",
      repositoryName: "workspace", repositoryNameWithOwner: "example/workspace",
      authorLogin: "contributor", updatedAt: nil, isDraft: isDraft, state: "open",
      projectStatus: nil, projectPriority: nil)
  }

  private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
    let window = BackgroundTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    window.presentForTesting()
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    return (window, host)
  }

  private func scrollView(in host: NSView) async throws -> NSScrollView {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      if let scroll = subviews(of: host).compactMap({ $0 as? NSScrollView }).first,
        let document = scroll.documentView, document.frame.height > 0 { return scroll }
      await Task.yield()
    } while Date() < deadline
    throw MissingScrollDocument()
  }

  private func subviews(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { subviews(of: $0) }
  }

  private func saveImage<V: View>(_ host: NSHostingView<V>, name: String) throws {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/private/tmp/\(name).png"))
  }

  private struct MissingScrollDocument: Error {}
}
