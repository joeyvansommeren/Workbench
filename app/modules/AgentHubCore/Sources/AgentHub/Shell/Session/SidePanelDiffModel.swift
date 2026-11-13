//
//  SidePanelDiffModel.swift
//  AgentHub
//
//  State for the compact side panel Diff (`SidePanelDiffView`): the flat
//  file list for one `DiffMode`, the selected file, and that file's hunks.
//  Loads through `GitDiffServiceProtocol`; parses with `SidePanelDiffParser`.
//

import AgentHubGitDiff
import Foundation
import Observation

/// The selected file's hunks, capped for the narrow panel.
struct SidePanelRenderedDiff: Equatable, Sendable {
  let path: String
  let hunks: [SidePanelDiffHunk]
  /// Lines in the whole file diff.
  let totalLineCount: Int

  var renderedLineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
  var isTruncated: Bool { renderedLineCount < totalLineCount }
}

enum SidePanelFileDiffState: Equatable {
  case idle
  case loading
  case loaded(SidePanelRenderedDiff)
  case binary
  /// Over the patch size limit; only the full diff can show it.
  case tooLarge
  case failed(String)
}

@MainActor
@Observable
final class SidePanelDiffModel {
  /// Lines drawn per file. More lines go to the full diff ("Show full diff").
  nonisolated static let renderedLineLimit = 400

  enum ListState: Equatable {
    case loading
    case loaded
    case failed(String)
  }

  private(set) var mode: DiffMode = .branch
  /// False once the user picks a mode in the menu.
  private(set) var isModeAutomatic = true
  private(set) var listState: ListState = .loading
  private(set) var files: [GitDiffFileEntry] = []
  private(set) var selectedPath: String?
  private(set) var fileDiff: SidePanelFileDiffState = .idle
  /// Bumps after each list load, so the selected file's hunks reload too.
  private(set) var listRevision = 0

  @ObservationIgnored let projectPath: String
  @ObservationIgnored private let service: any GitDiffServiceProtocol
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var fileGeneration = 0
  @ObservationIgnored private var lastRefreshStart: ContinuousClock.Instant?

  init(projectPath: String, service: any GitDiffServiceProtocol) {
    self.projectPath = projectPath
    self.service = service
  }

  var selectedFile: GitDiffFileEntry? {
    files.first { $0.relativePath == selectedPath }
  }

  var additions: Int { files.reduce(0) { $0 + $1.additions } }
  var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

  /// The mode for "Show full diff": nil until a list has loaded, so the full
  /// diff keeps its own auto-select instead of a mode that failed.
  var loadedMode: DiffMode? { listState == .loaded ? mode : nil }

  /// Changes when the hunks below the list must (re)load.
  var fileLoadKey: String { "\(listRevision)|\(mode.rawValue)|\(selectedPath ?? "")" }

  // MARK: - List

  /// Loads the file list. While the mode is automatic, the first mode with
  /// changes wins, probed cheap first (`branch → staged → unstaged`, the
  /// `DiffMode` order): the header diffstat and "Commit N files…" count every
  /// mode, so an empty Branch list under them would read as wrong.
  func refresh() async {
    lastRefreshStart = .now
    loadGeneration += 1
    let generation = loadGeneration
    if files.isEmpty { listState = .loading }

    let result = await loadList()
    guard generation == loadGeneration else { return }

    switch result {
    case .success(let (loadedMode, state)):
      mode = loadedMode
      files = state.files
      listState = .loaded
      if selectedPath == nil || !state.files.contains(where: { $0.relativePath == selectedPath }) {
        selectedPath = state.files.first?.relativePath
        fileDiff = .idle
      }
      listRevision += 1
    case .failure(let error):
      files = []
      selectedPath = nil
      fileDiff = .idle
      listState = .failed(error.localizedDescription)
    }
  }

  /// For frequent triggers (agent activity): refreshes start at most once per
  /// `minimumInterval`. A newer trigger cancels this task and waits only for
  /// the rest of the interval, so a steady stream still refreshes.
  func refreshThrottled(minimumInterval: Duration = .seconds(2)) async {
    if let lastRefreshStart {
      let wait = minimumInterval - (ContinuousClock.now - lastRefreshStart)
      if wait > .zero {
        do { try await Task.sleep(for: wait) } catch { return }
      }
    }
    await refresh()
  }

  func setMode(_ newMode: DiffMode) async {
    MainThreadStallMonitor.breadcrumb("side panel diff: mode \(newMode.rawValue)")
    isModeAutomatic = false
    guard newMode != mode || listState != .loaded else { return }
    mode = newMode
    files = []
    selectedPath = nil
    fileDiff = .idle
    await refresh()
  }

  private func loadList() async -> Result<(DiffMode, GitDiffState), Error> {
    let candidates = isModeAutomatic ? DiffMode.allCases : [mode]
    var firstLoaded: (DiffMode, GitDiffState)?
    var lastError: Error?
    for candidate in candidates {
      do {
        let state = try await service.changedFiles(at: projectPath, mode: candidate, baseBranch: nil)
        if !state.files.isEmpty { return .success((candidate, state)) }
        if firstLoaded == nil { firstLoaded = (candidate, state) }
      } catch {
        lastError = error
      }
    }
    if let firstLoaded { return .success(firstLoaded) }
    return .failure(lastError ?? GitDiffError.gitCommandFailed("No diff modes could be loaded"))
  }

  // MARK: - Selection

  func select(path: String) {
    guard path != selectedPath, files.contains(where: { $0.relativePath == path }) else { return }
    MainThreadStallMonitor.breadcrumb("side panel diff: file \(path)")
    selectedPath = path
    fileDiff = .idle
  }

  /// ↑/↓ in the list. Stops at the ends.
  func moveSelection(by offset: Int) {
    guard !files.isEmpty else { return }
    let current = files.firstIndex { $0.relativePath == selectedPath } ?? 0
    let next = min(max(current + offset, 0), files.count - 1)
    select(path: files[next].relativePath)
  }

  // MARK: - Selected file

  func loadSelectedFileDiff() async {
    fileGeneration += 1
    let generation = fileGeneration
    guard let file = selectedFile else {
      fileDiff = .idle
      return
    }
    if file.isBinary {
      fileDiff = .binary
      return
    }
    // A refresh of the same file keeps the old hunks on screen until the new
    // ones arrive, so the panel does not flash while the agent works.
    var showsSameFile = false
    if case .loaded(let shown) = fileDiff { showsSameFile = shown.path == file.relativePath }
    if !showsSameFile { fileDiff = .loading }

    do {
      let patch = try await service.unifiedPatch(for: file, at: projectPath, mode: mode, baseBranch: nil)
      // Parsing a large patch (up to 2 MB) stays off the main thread.
      let parsed = await Task.detached(priority: .userInitiated) {
        SidePanelDiffParser.parse(patch).first
      }.value
      guard generation == fileGeneration, selectedPath == file.relativePath else { return }
      if parsed?.isBinary == true {
        fileDiff = .binary
      } else {
        fileDiff = .loaded(Self.rendered(path: file.relativePath, hunks: parsed?.hunks ?? []))
      }
    } catch is CancellationError {
      return
    } catch {
      guard generation == fileGeneration, selectedPath == file.relativePath else { return }
      if case GitDiffError.binaryFile = error {
        fileDiff = .binary
      } else if case GitDiffError.patchTooLarge = error {
        fileDiff = .tooLarge
      } else {
        fileDiff = .failed(error.localizedDescription)
      }
    }
  }

  /// Keeps whole hunks and cuts the hunk that crosses `limit`.
  nonisolated static func rendered(
    path: String,
    hunks: [SidePanelDiffHunk],
    limit: Int = renderedLineLimit
  ) -> SidePanelRenderedDiff {
    let total = hunks.reduce(0) { $0 + $1.lines.count }
    var kept: [SidePanelDiffHunk] = []
    var budget = limit
    for hunk in hunks where budget > 0 {
      var hunk = hunk
      if hunk.lines.count > budget { hunk.lines = Array(hunk.lines.prefix(budget)) }
      budget -= hunk.lines.count
      kept.append(hunk)
    }
    return SidePanelRenderedDiff(path: path, hunks: kept, totalLineCount: total)
  }
}

/// Holds the compact diff's model in `SessionDetailContent`, so its mode and
/// selection survive "Show full diff" and back. One model per project path.
@MainActor
final class SidePanelDiffModelCache {
  private var model: SidePanelDiffModel?
  private let makeService: () -> any GitDiffServiceProtocol

  init(makeService: @escaping () -> any GitDiffServiceProtocol = { GitDiffService() }) {
    self.makeService = makeService
  }

  func model(projectPath: String) -> SidePanelDiffModel {
    if let model, model.projectPath == projectPath { return model }
    let created = SidePanelDiffModel(projectPath: projectPath, service: makeService())
    model = created
    return created
  }
}
