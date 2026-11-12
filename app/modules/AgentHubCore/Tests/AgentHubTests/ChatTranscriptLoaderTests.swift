import AppKit
import SwiftUI
import Foundation
import Testing

@testable import AgentHubCore

/// A reader whose loads can be held back per path, to order A and B by hand.
private actor GatedReader: ChatTranscriptReading {
  private var results: [String: ChatTranscriptLoad] = [:]
  private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var held: Set<String> = []
  private(set) var loadCount: [String: Int] = [:]

  func set(_ result: ChatTranscriptLoad, for path: String, hold: Bool = false) {
    results[path] = result
    if hold { held.insert(path) }
  }

  func release(_ path: String) {
    held.remove(path)
    gates.removeValue(forKey: path)?.forEach { $0.resume() }
  }

  func items(at path: String, provider: SessionProviderKind) async -> [ChatTranscriptItem] {
    await load(at: path, provider: provider).items
  }

  func load(at path: String, provider: SessionProviderKind) async -> ChatTranscriptLoad {
    loadCount[path, default: 0] += 1
    if held.contains(path) {
      await withCheckedContinuation { gates[path, default: []].append($0) }
    }
    return results[path] ?? .missing
  }
}

@MainActor
@Suite("Chat transcript loader")
struct ChatTranscriptLoaderTests {
  private func item(_ text: String) -> ChatTranscriptItem {
    ChatTranscriptItem(id: text, kind: .assistant(text), timestamp: nil)
  }

  /// Tests run in parallel on the main actor, so wait for a condition, not a fixed delay.
  private func settle(until condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// A short grace period for things that must NOT happen.
  private func grace() async { try? await Task.sleep(for: .milliseconds(100)) }

  @Test("Switching to B while A is still loading never shows A's items")
  func slowPreviousLoadIsDiscarded() async {
    let reader = GatedReader()
    await reader.set(.loaded([item("from A")]), for: "/a", hold: true)
    await reader.set(.loaded([item("from B")]), for: "/b")
    let loader = ChatTranscriptLoader(reader: reader)

    loader.load(path: "/a", provider: .claude)
    #expect(loader.phase == .loading)
    #expect(loader.items.isEmpty)
    // A must really be in flight (held inside the reader) before B takes over,
    // so A's late completion is the thing being rejected.
    var aStarted = false
    var attempts = 0
    while !aStarted, attempts < 300 {
      aStarted = await reader.loadCount["/a", default: 0] > 0
      if !aStarted { try? await Task.sleep(for: .milliseconds(10)) }
      attempts += 1
    }
    #expect(aStarted)

    loader.load(path: "/b", provider: .claude)
    #expect(loader.items.isEmpty)
    await settle { loader.phase == .ready }
    #expect(loader.items == [item("from B")])

    await reader.release("/a")
    await grace()
    #expect(loader.items == [item("from B")])
    #expect(loader.path == "/b")
    #expect(await reader.loadCount["/a"] == 1)
  }

  @Test("Only the active card's composer takes focus; focusing a background one activates its card")
  func composerFocusPolicy() {
    #expect(ChatComposerFocusPolicy.shouldTakeFocus(isActiveCard: true))
    #expect(!ChatComposerFocusPolicy.shouldTakeFocus(isActiveCard: false))
    #expect(ChatComposerFocusPolicy.shouldActivateCard(isActiveCard: false, composerFocused: true))
    #expect(!ChatComposerFocusPolicy.shouldActivateCard(isActiveCard: true, composerFocused: true))
    #expect(!ChatComposerFocusPolicy.shouldActivateCard(isActiveCard: false, composerFocused: false))
  }

  @Test("Opening another chat in the same active column focuses its input")
  func openingChatFocusesInput() async {
    let reader = GatedReader()
    let host = NSHostingView(rootView: ChatTranscriptView(
      transcriptPath: "/focus-a", providerKind: .claude, reader: reader, onSend: { _ in false }))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    await settle { window.firstResponder is NSTextView }
    #expect(window.firstResponder is NSTextView)

    window.makeFirstResponder(nil)
    host.rootView = ChatTranscriptView(
      transcriptPath: "/focus-b", providerKind: .claude, reader: reader, onSend: { _ in false })
    await settle { window.firstResponder is NSTextView }
    #expect(window.firstResponder is NSTextView)

    window.makeFirstResponder(nil)
    host.rootView = ChatTranscriptView(
      transcriptPath: "/focus-c", providerKind: .claude, reader: reader,
      onSend: { _ in false }, isActiveCard: false)
    await grace()
    #expect(!(window.firstResponder is NSTextView))
  }

  @Test("Missing, then present: the phase follows the file")
  func missingThenReady() async {
    let reader = GatedReader()
    let loader = ChatTranscriptLoader(reader: reader)
    loader.load(path: "/x", provider: .codex)
    await settle { loader.phase == .missing }
    #expect(loader.phase == .missing)

    await reader.set(.loaded([]), for: "/x")
    loader.load(path: "/x", provider: .codex)
    await settle { loader.phase == .ready }
    #expect(loader.phase == .ready)
    #expect(loader.items.isEmpty)

    await reader.set(.loaded([item("hi")]), for: "/x")
    loader.load(path: "/x", provider: .codex)
    await settle { !loader.items.isEmpty }
    #expect(loader.items == [item("hi")])
  }

  @Test("No path means no transcript; a reload keeps shown items until new ones arrive")
  func noPathAndReloadInPlace() async {
    let reader = GatedReader()
    await reader.set(.loaded([item("one")]), for: "/p")
    let loader = ChatTranscriptLoader(reader: reader)
    loader.load(path: nil, provider: .claude)
    #expect(loader.phase == .noTranscript)

    loader.load(path: "/p", provider: .claude)
    await settle { !loader.items.isEmpty }
    #expect(loader.items == [item("one")])

    await reader.set(.loaded([item("one"), item("two")]), for: "/p", hold: true)
    loader.load(path: "/p", provider: .claude)
    await grace()
    #expect(loader.items == [item("one")])  // same path: nothing is blanked
    #expect(loader.phase == .ready)
    await reader.release("/p")
    await settle { loader.items.count == 2 }
    #expect(loader.items == [item("one"), item("two")])
  }
}
