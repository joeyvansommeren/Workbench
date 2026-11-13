import AgentHubGitDiff
import Foundation
import Testing

@testable import AgentHubCore

/// Answers from fixed per-mode lists; records which modes were probed.
final class SidePanelDiffMockService: GitDiffServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var filesByMode: [DiffMode: Result<[GitDiffFileEntry], Error>]
  private var patches: [String: String]
  private(set) var probedModes: [DiffMode] = []
  private(set) var patchRequests: [String] = []

  init(filesByMode: [DiffMode: Result<[GitDiffFileEntry], Error>] = [:], patches: [String: String] = [:]) {
    self.filesByMode = filesByMode
    self.patches = patches
  }

  func setFiles(_ files: [GitDiffFileEntry], for mode: DiffMode) {
    lock.withLock { filesByMode[mode] = .success(files) }
  }

  func setPatch(_ patch: String, for path: String) {
    lock.withLock { patches[path] = patch }
  }

  func changedFiles(at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> GitDiffState {
    let result = lock.withLock {
      probedModes.append(mode)
      return filesByMode[mode] ?? .success([])
    }
    return GitDiffState(files: try result.get())
  }

  func unifiedPatch(for file: GitDiffFileEntry, at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> String {
    try lock.withLock {
      patchRequests.append(file.relativePath)
      guard let patch = patches[file.relativePath] else { throw GitDiffError.fileNotFound(file.relativePath) }
      return patch
    }
  }

  func renderPayload(for file: GitDiffFileEntry, at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> GitDiffRenderPayload {
    GitDiffRenderPayload(oldContent: "", newContent: "")
  }

  func detectBaseBranch(at repoPath: String) async throws -> String { "main" }
  func findGitRoot(at path: String) async throws -> String { path }

  static func entry(_ path: String, _ additions: Int, _ deletions: Int, isBinary: Bool = false) -> GitDiffFileEntry {
    GitDiffFileEntry(filePath: "/repo/" + path, relativePath: path, additions: additions, deletions: deletions, isBinary: isBinary)
  }

  static func patch(_ path: String, addedLines: Int) -> String {
    var lines = ["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)", "@@ -0,0 +1,\(addedLines) @@"]
    lines += (1...addedLines).map { "+line \($0)" }
    return lines.joined(separator: "\n")
  }
}

@MainActor
@Suite("SidePanelDiffModel")
struct SidePanelDiffModelTests {
  private typealias Mock = SidePanelDiffMockService

  @Test("Stats sum the list; selection defaults to the first file")
  func statsAndDefaultSelection() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A.swift", 5, 2), Mock.entry("B/C.swift", 14, 3)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()

    #expect(model.listState == .loaded)
    #expect(model.mode == .branch)
    #expect(model.additions == 19)
    #expect(model.deletions == 5)
    #expect(model.selectedPath == "A.swift")
  }

  @Test("Automatic mode probes cheap first and stops at the first mode with changes")
  func cheapFirst() async {
    let service = Mock(filesByMode: [
      .branch: .success([]),
      .staged: .success([Mock.entry("S.swift", 1, 0)]),
      .unstaged: .success([Mock.entry("U.swift", 1, 0)]),
    ])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()

    #expect(service.probedModes == [.branch, .staged])
    #expect(model.mode == .staged)
    #expect(model.files.map(\.relativePath) == ["S.swift"])
  }

  @Test("A failing mode is skipped; all empty stays on the first loadable mode")
  func failuresAndEmpty() async {
    let service = Mock(filesByMode: [.branch: .failure(GitDiffError.gitCommandFailed("no base"))])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()

    #expect(service.probedModes == [.branch, .staged, .unstaged])
    #expect(model.listState == .loaded)
    #expect(model.mode == .staged)
    #expect(model.files.isEmpty)
    #expect(model.selectedPath == nil)
  }

  @Test("All modes failing shows the error")
  func allFail() async {
    let error = Result<[GitDiffFileEntry], Error>.failure(GitDiffError.notAGitRepository("/repo"))
    let service = Mock(filesByMode: [.branch: error, .staged: error, .unstaged: error])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()

    guard case .failed = model.listState else {
      Issue.record("expected failure, got \(model.listState)")
      return
    }
  }

  @Test("Selection survives a refresh by path, and falls back to the first file when gone")
  func selectionSurvivesRefresh() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A.swift", 1, 0), Mock.entry("B.swift", 1, 0)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    model.select(path: "B.swift")

    service.setFiles([Mock.entry("New.swift", 1, 0), Mock.entry("A.swift", 2, 0), Mock.entry("B.swift", 3, 1)], for: .branch)
    await model.refresh()
    #expect(model.selectedPath == "B.swift")
    #expect(model.selectedFile?.additions == 3)

    service.setFiles([Mock.entry("A.swift", 2, 0)], for: .branch)
    await model.refresh()
    #expect(model.selectedPath == "A.swift")
  }

  @Test("Explicit mode stops the automatic probe")
  func explicitMode() async {
    let service = Mock(filesByMode: [
      .branch: .success([Mock.entry("Br.swift", 1, 0)]),
      .unstaged: .success([Mock.entry("U.swift", 1, 0)]),
    ])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    #expect(model.mode == .branch)

    await model.setMode(.unstaged)
    #expect(!model.isModeAutomatic)
    #expect(model.mode == .unstaged)
    #expect(model.selectedPath == "U.swift")

    service.setFiles([], for: .unstaged)
    await model.refresh()
    #expect(model.mode == .unstaged)
    #expect(model.files.isEmpty)
  }

  @Test("Arrow keys move the selection and stop at the ends")
  func keyboard() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A", 1, 0), Mock.entry("B", 1, 0), Mock.entry("C", 1, 0)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()

    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    #expect(model.selectedPath == "C")
    model.moveSelection(by: -5)
    #expect(model.selectedPath == "A")
  }

  @Test("Selected file loads its hunks; binary entries never fetch a patch")
  func loadsSelectedFile() async throws {
    let service = Mock(
      filesByMode: [.branch: .success([Mock.entry("A.swift", 2, 0), Mock.entry("img.png", 0, 0, isBinary: true)])],
      patches: ["A.swift": Mock.patch("A.swift", addedLines: 2)]
    )
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()

    guard case .loaded(let diff) = model.fileDiff else {
      Issue.record("expected hunks, got \(model.fileDiff)")
      return
    }
    #expect(diff.path == "A.swift")
    #expect(diff.hunks.count == 1)
    #expect(!diff.isTruncated)

    model.select(path: "img.png")
    await model.loadSelectedFileDiff()
    #expect(model.fileDiff == .binary)
    #expect(service.patchRequests == ["A.swift"])
  }

  @Test("Patch errors show on the file, not the list")
  func fileError() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A.swift", 1, 0)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()

    #expect(model.listState == .loaded)
    guard case .failed = model.fileDiff else {
      Issue.record("expected file failure, got \(model.fileDiff)")
      return
    }
  }

  @Test("Large files are capped at the line limit")
  func cap() async {
    let service = Mock(
      filesByMode: [.branch: .success([Mock.entry("Big.swift", 900, 0)])],
      patches: ["Big.swift": Mock.patch("Big.swift", addedLines: 900)]
    )
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()

    guard case .loaded(let diff) = model.fileDiff else {
      Issue.record("expected hunks, got \(model.fileDiff)")
      return
    }
    #expect(diff.renderedLineCount == SidePanelDiffModel.renderedLineLimit)
    #expect(diff.totalLineCount == 900)
    #expect(diff.isTruncated)
  }

  @Test("The cap keeps whole hunks and cuts the one that crosses it")
  func capAcrossHunks() {
    func hunk(_ count: Int) -> SidePanelDiffHunk {
      SidePanelDiffHunk(
        header: "@@", oldStart: 1, oldCount: 0, newStart: 1, newCount: count,
        lines: (0..<count).map { SidePanelDiffLine(kind: .added, oldLineNumber: nil, newLineNumber: $0 + 1, text: "") })
    }
    let rendered = SidePanelDiffModel.rendered(path: "x", hunks: [hunk(3), hunk(4), hunk(5)], limit: 5)
    #expect(rendered.hunks.map(\.lines.count) == [3, 2])
    #expect(rendered.totalLineCount == 12)
    #expect(rendered.isTruncated)
  }

  @Test("Staging moves the automatic list from Unstaged to Staged; an explicit Unstaged empties")
  func stagingChangesTheList() async {
    let service = Mock(filesByMode: [.unstaged: .success([Mock.entry("X.swift", 2, 1)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    #expect(model.mode == .unstaged)

    // `git add -A`: same file, same counts, now staged.
    service.setFiles([], for: .unstaged)
    service.setFiles([Mock.entry("X.swift", 2, 1)], for: .staged)
    await model.refresh()
    #expect(model.mode == .staged)
    #expect(model.selectedPath == "X.swift")

    await model.setMode(.unstaged)
    #expect(model.files.isEmpty)
  }

  @Test("loadedMode is nil until a list loads and after a failure")
  func loadedMode() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A", 1, 0)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    #expect(model.loadedMode == nil)
    await model.refresh()
    #expect(model.loadedMode == .branch)

    let failing = Mock(filesByMode: [.staged: .failure(GitDiffError.gitCommandFailed("x"))])
    let failingModel = SidePanelDiffModel(projectPath: "/repo", service: failing)
    await failingModel.setMode(.staged)
    #expect(failingModel.loadedMode == nil)
    #expect(failingModel.mode == .staged)
  }

  @Test("A cancelled throttled refresh does not load")
  func throttleCancellation() async {
    let service = Mock(filesByMode: [.branch: .success([Mock.entry("A", 1, 0)])])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    let probes = service.probedModes.count

    let waiting = Task { await model.refreshThrottled(minimumInterval: .seconds(60)) }
    waiting.cancel()
    await waiting.value
    #expect(service.probedModes.count == probes)

    await model.refreshThrottled(minimumInterval: .zero)
    #expect(service.probedModes.count == probes + 1)
  }

  @Test("The cache keeps one model per project path")
  func cache() {
    let cache = SidePanelDiffModelCache(makeService: { Mock() })
    let first = cache.model(projectPath: "/a")
    #expect(cache.model(projectPath: "/a") === first)
    #expect(cache.model(projectPath: "/b") !== first)
  }

  // MARK: - Stale results and cancellation

  @Test("Selecting B while A loads: A's late result is dropped")
  func staleResultDropped() async throws {
    let service = GatedPatchService(files: ["A", "B"])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    #expect(model.selectedPath == "A")

    service.gate("A")
    let loadA = Task { await model.loadSelectedFileDiff() }
    try await waitUntil { service.isWaiting("A") }
    model.select(path: "B")
    await model.loadSelectedFileDiff()
    service.release("A")
    await loadA.value

    #expect(model.selectedPath == "B")
    #expect(loadedPath(model) == "B")
  }

  @Test("Reloading the same file keeps its hunks on screen until the new ones arrive")
  func sameFileRefreshKeepsLoaded() async throws {
    let service = GatedPatchService(files: ["A"])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()
    #expect(loadedPath(model) == "A")

    service.gate("A")
    let reload = Task { await model.loadSelectedFileDiff() }
    try await waitUntil { service.isWaiting("A") }
    #expect(loadedPath(model) == "A")
    service.release("A")
    await reload.value
    #expect(loadedPath(model) == "A")
  }

  @Test("CancellationError leaves the file state unchanged")
  func cancellationLeavesStateUnchanged() async {
    let service = GatedPatchService(files: ["A"])
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()
    let before = model.fileDiff

    service.setPatch(.failure(CancellationError()), for: "A")
    await model.loadSelectedFileDiff()
    #expect(model.fileDiff == before)
  }

  @Test("An oversized patch maps to tooLarge")
  func tooLarge() async {
    let service = GatedPatchService(files: ["A"])
    service.setPatch(.failure(GitDiffError.patchTooLarge("A")), for: "A")
    let model = SidePanelDiffModel(projectPath: "/repo", service: service)
    await model.refresh()
    await model.loadSelectedFileDiff()
    #expect(model.fileDiff == .tooLarge)
  }

  private func loadedPath(_ model: SidePanelDiffModel) -> String? {
    if case .loaded(let diff) = model.fileDiff { return diff.path }
    return nil
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() {
      try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition())
  }
}

/// Branch lists the given paths; `unifiedPatch` can be held per path until
/// the test releases it.
final class GatedPatchService: GitDiffServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private let files: [GitDiffFileEntry]
  private var patches: [String: Result<String, Error>] = [:]
  private var gated: Set<String> = []
  private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

  init(files paths: [String]) {
    files = paths.map { SidePanelDiffMockService.entry($0, 1, 0) }
    for path in paths {
      patches[path] = .success(SidePanelDiffMockService.patch(path, addedLines: 1))
    }
  }

  func setPatch(_ patch: Result<String, Error>, for path: String) {
    lock.withLock { patches[path] = patch }
  }

  func gate(_ path: String) {
    lock.withLock { _ = gated.insert(path) }
  }

  func isWaiting(_ path: String) -> Bool {
    lock.withLock { waiting[path] != nil }
  }

  func release(_ path: String) {
    let continuation = lock.withLock {
      gated.remove(path)
      return waiting.removeValue(forKey: path)
    }
    continuation?.resume()
  }

  func changedFiles(at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> GitDiffState {
    GitDiffState(files: mode == .branch ? files : [])
  }

  func unifiedPatch(for file: GitDiffFileEntry, at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> String {
    let path = file.relativePath
    if lock.withLock({ gated.contains(path) }) {
      await withCheckedContinuation { continuation in
        lock.withLock { waiting[path] = continuation }
      }
    }
    let result = lock.withLock { patches[path] ?? .failure(GitDiffError.fileNotFound(path)) }
    return try result.get()
  }

  func renderPayload(for file: GitDiffFileEntry, at repoPath: String, mode: DiffMode, baseBranch: String?) async throws -> GitDiffRenderPayload {
    GitDiffRenderPayload(oldContent: "", newContent: "")
  }

  func detectBaseBranch(at repoPath: String) async throws -> String { "main" }
  func findGitRoot(at path: String) async throws -> String { path }
}
