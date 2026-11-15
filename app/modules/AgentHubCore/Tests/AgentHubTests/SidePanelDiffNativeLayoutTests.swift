import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Side panel diff native layout", .serialized)
struct SidePanelDiffNativeLayoutTests {
  @Test("A long file list and the selected code have separate visible scrolls")
  func longListKeepsCodeVisible() async throws {
    for height: CGFloat in [320, 700] {
      let fixture = try await Fixture(height: height)
      defer { fixture.close() }

      let scrolls = fixture.verticalScrolls()
      #expect(scrolls.count >= 2, "A 300-file list needs its own scroll at \(height) points")
      guard scrolls.count >= 2 else { continue }
      let visibleHeights = scrolls.map { scroll in
        scroll.convert(scroll.bounds, to: fixture.host).intersection(fixture.host.bounds).height
      }
      #expect(
        visibleHeights.allSatisfy { $0 >= DesignTokens.Size.row * 2 },
        "File navigation and code must each keep two rows visible at \(height) points")
    }
  }

  @Test("Selecting an offscreen file reveals it in the file list")
  func keyboardSelectionRevealsFile() async throws {
    let fixture = try await Fixture(height: 320)
    defer { fixture.close() }
    let initialScroll = try #require(fixture.fileListScroll())
    let initialOffset = initialScroll.contentView.bounds.minY

    fixture.model.moveSelection(by: 190)
    let revealed = fixture.waitUntil {
      guard let scroll = fixture.fileListScroll() else { return false }
      return scroll.contentView.bounds.minY > initialOffset + DesignTokens.Size.row
    }

    #expect(fixture.model.selectedPath == fixture.paths[198])
    #expect(revealed, "Offscreen selection must scroll into the file viewport")
  }

  @Test("A restored offscreen selection is visible when the file list opens")
  func restoredSelectionIsVisible() async throws {
    let selectedIndex = 198
    let fixture = try await Fixture(height: 320, initialSelectedIndex: selectedIndex)
    defer { fixture.close() }

    #expect(fixture.model.selectedPath == fixture.paths[selectedIndex])
    let revealed = await fixture.waitUntilAsync {
      guard let scroll = fixture.fileListScroll() else { return false }
      let selectedMidpoint = (CGFloat(selectedIndex) + 0.5) * DesignTokens.Size.row
      return scroll.contentView.bounds.minY <= selectedMidpoint
        && selectedMidpoint <= scroll.contentView.bounds.maxY
    }
    #expect(revealed, "The restored file row must be inside the visible list viewport")
  }
}

@MainActor
private final class Fixture {
  let model: SidePanelDiffModel
  let paths: [String]
  let host: NSHostingView<AnyView>
  let window: NSWindow

  init(height: CGFloat, initialSelectedIndex: Int = 8) async throws {
    let paths = (0..<300).map { "Sources/Example/File\(String(format: "%03d", $0)).swift" }
    let files = paths.map { SidePanelDiffMockService.entry($0, 1, 0) }
    let patches = Dictionary(
      uniqueKeysWithValues: paths.map { path in
        (path, SidePanelDiffMockService.patch(path, addedLines: path == paths[8] ? 200 : 1))
      })
    let service = SidePanelDiffMockService(
      filesByMode: [.branch: .success(files)], patches: patches)
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    model.select(path: paths[initialSelectedIndex])
    await model.loadSelectedFileDiff()

    self.paths = paths
    self.model = model
    host = NSHostingView(
      rootView: AnyView(
        SidePanelDiffView(
          model: model,
          refreshKey: SidePanelDiffRefreshKey(summary: nil, lastActivity: nil),
          onShowFullDiff: {}
        )
        .frame(width: 400, height: height)
      )
    )
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: height),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    guard waitUntil({ !verticalScrolls().isEmpty }) else {
      throw FixtureError.scrollDidNotRender
    }
  }

  func close() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  @discardableResult
  func waitUntil(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }

  func waitUntilAsync(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      host.layoutSubtreeIfNeeded()
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  func verticalScrolls() -> [NSScrollView] {
    func collect(_ view: NSView) -> [NSScrollView] {
      let nested = view.subviews.flatMap(collect)
      return (view as? NSScrollView).map { [$0] + nested } ?? nested
    }
    return collect(host)
      .filter { scroll in
        (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height
          + DesignTokens.Size.row
      }
  }

  func fileListScroll() -> NSScrollView? {
    verticalScrolls().max {
      ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
    }
  }
}

private enum FixtureError: Error {
  case scrollDidNotRender
}
