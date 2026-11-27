import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite(.serialized)
struct TicketSessionChooserNativeTests {
  @Test("The real chooser fits with long tracker content and unavailable agents")
  func longTicketInLightAndDark() async throws {
    let title = "Recover the selected ticket and repository when the provider becomes unavailable — 界面の確認 👩🏽‍💻 "
      + "LongUnbrokenFrameworkNameForTheTicketSessionLaunchWorkspace"
    let request = TicketSessionRequest(id: "fixture", key: "TASK-2147483647", title: title) { _, _ in
      Issue.record("Rendering a chooser must not start a session")
      return "Unexpected start"
    }
    let repository = SelectedRepository(
      path: "/fixture/repository", name: "Repository with a long local checkout name — 日本語")
    let descriptors = TicketSessionProviderDescriptor.catalog
      + [TicketSessionProviderDescriptor(id: "future", name: "Future Agent")]
    let options = TicketSessionProviderOption.resolve(descriptors) { id in
      SessionProviderKind(rawValue: id).map { ($0, $0 == .codex) }
    }

    for scheme in [ColorScheme.light, .dark] {
      let fitted = try await fit(
        request, repositories: [repository], path: repository.path, options: options, scheme: scheme)
      #expect(fitted.width == DesignTokens.Width.sheet)
      #expect((180...500).contains(fitted.height))
    }

    let empty = try await fit(
      request, repositories: [], path: nil, options: options, scheme: .light)
    #expect(empty.height > 180)
  }

  private func fit(
    _ request: TicketSessionRequest, repositories: [SelectedRepository], path: String?,
    options: [TicketSessionProviderOption], scheme: ColorScheme
  ) async throws -> CGSize {
    var didRead = false
    let view = TicketSessionChooser(
      request: request, repositories: repositories, repositoryPath: path,
      readOptions: {
        didRead = true
        return options
      },
      onStarted: { _ in Issue.record("Rendering must not change the selected repository") }
    )
    .environment(\.colorScheme, scheme)

    let host = NSHostingView(rootView: view)
    let window = BackgroundTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Width.sheet, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.presentForTesting()
    defer {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !didRead, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(didRead, "The presented chooser must load the provider choices")
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }
}
