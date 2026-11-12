import Foundation
import Testing
@testable import SimulatorPreview

@MainActor
@Suite("Hot reload source watcher startup")
struct HotReloadSourceWatcherTests {
  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
  }

  @Test("A slow scan runs off main and preserves changes received while scanning")
  func responsiveStartup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("App.swift").path
    FileManager.default.createFile(atPath: source, contents: Data())
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let watcher = HotReloadSourceWatcher { _, _ in
      #expect(!Thread.isMainThread)
      started.signal()
      _ = release.wait(timeout: .now() + 3)
      return [source]
    }
    defer { release.signal(); watcher.stop() }
    var received: [HotReloadSourceChange] = []
    let before = Date()
    watcher.start(projectPath: root.path) { received += $0 }
    #expect(Date().timeIntervalSince(before) < 0.5)
    var scanStarted = false
    await waitUntil {
      if !scanStarted { scanStarted = started.wait(timeout: .now()) == .success }
      return scanStarted
    }
    watcher.handle(paths: [source])
    #expect(received.isEmpty)
    release.signal()
    await waitUntil { !watcher.isScanning }
    #expect(received == [.injectable(path: source)])
  }

  @Test("A late scan from the previous project cannot replace the new snapshot")
  func switchDuringScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = b.appendingPathComponent("App.swift").path
    FileManager.default.createFile(atPath: source, contents: Data())
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let watcher = HotReloadSourceWatcher { path, _ in
      if path == a.path {
        _ = release.wait(timeout: .now() + 3)
        finished.signal()
        return []
      }
      return [source]
    }
    defer { release.signal(); watcher.stop() }
    watcher.start(projectPath: a.path) { _ in Issue.record("Previous project callback") }
    var received: [HotReloadSourceChange] = []
    watcher.start(projectPath: b.path) { received += $0 }
    await waitUntil { !watcher.isScanning }
    release.signal()
    var didFinish = false
    await waitUntil {
      if !didFinish { didFinish = finished.wait(timeout: .now()) == .success }
      return didFinish
    }
    await Task.yield()
    watcher.handle(paths: [source])
    #expect(received == [.injectable(path: source)])
  }

  @Test("Stopping cancels a pending scan and prevents its callback")
  func stopDuringScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let started = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    let watcher = HotReloadSourceWatcher { _, isCancelled in
      started.signal()
      let deadline = Date().addingTimeInterval(3)
      while !isCancelled(), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
      #expect(isCancelled())
      cancelled.signal()
      return []
    }
    defer { watcher.stop() }
    var callback = false
    watcher.start(projectPath: root.path) { _ in callback = true }
    var scanStarted = false
    await waitUntil {
      if !scanStarted { scanStarted = started.wait(timeout: .now()) == .success }
      return scanStarted
    }
    watcher.handle(paths: [root.appendingPathComponent("New.swift").path])
    watcher.stop()
    var didCancel = false
    await waitUntil {
      if !didCancel { didCancel = cancelled.wait(timeout: .now()) == .success }
      return didCancel
    }
    #expect(!watcher.isScanning)
    #expect(!callback)
  }
}
