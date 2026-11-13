import Foundation
import Testing

@testable import AgentHubGitDiff

@Suite("GitDiffService")
struct GitDiffServiceTests {

  @Test("lists and renders unstaged changes")
  func listsAndRendersUnstagedChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(file.additions == 1)
    #expect(file.deletions == 1)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed")
    #expect(!payload.isLimitedContext)
  }

  @Test("lists and renders staged changes")
  func listsAndRendersStagedChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "staged".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .staged, baseBranch: nil)

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "staged")
    #expect(!payload.isLimitedContext)
  }

  @Test("lists and renders branch changes")
  func listsAndRendersBranchChanges() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "feature/diff")
    try "branch".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")
    try fixture.runGit("commit", "-m", "branch change")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .branch, baseBranch: "main")
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .branch, baseBranch: "main")

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "branch")
    #expect(!payload.isLimitedContext)
  }

  @Test("branch changes are scoped to the selected worktree", .disabled("headless-quarantine: temp-dir symlink path normalization (/var vs /private/var); see TestQuarantine.md"))
  func branchChangesAreScopedToSelectedWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-worktree-scoped-diff")
    try "parent only".write(toFile: fixture.repoPath + "/ParentOnly.swift", atomically: true, encoding: .utf8)
    try "worktree branch".write(toFile: worktreePath + "/WorktreeOnly.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "WorktreeOnly.swift", at: worktreePath)
    try fixture.runGit("commit", "-m", "worktree branch change", at: worktreePath)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: worktreePath, mode: .branch, baseBranch: "main")

    #expect(state.files.map(\.relativePath) == ["WorktreeOnly.swift"])
    let allWithinWorktree = state.files.allSatisfy { $0.filePath.hasPrefix(worktreePath + "/") }
    #expect(allWithinWorktree)
  }

  @Test("renders deleted unstaged files")
  func rendersDeletedUnstagedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.removeItem(atPath: fixture.repoPath + "/README.md")

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "")
  }

  @Test("lists and renders untracked files")
  func listsAndRendersUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "new file".write(toFile: fixture.repoPath + "/NewFile.txt", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "NewFile.txt" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.oldContent == "")
    #expect(payload.newContent == "new file")
    #expect(!payload.isLimitedContext)
    #expect(file.status == .untracked)
  }

  @Test("unified patch for modified and untracked files")
  func unifiedPatchForModifiedAndUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try "new file".write(toFile: fixture.repoPath + "/NewFile.txt", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let modified = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let untracked = try #require(state.files.first(where: { $0.relativePath == "NewFile.txt" }))

    let modifiedPatch = try await service.unifiedPatch(for: modified, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(modifiedPatch.contains("diff --git a/README.md b/README.md"))
    #expect(modifiedPatch.contains("-initial"))
    #expect(modifiedPatch.contains("+changed"))

    let untrackedPatch = try await service.unifiedPatch(for: untracked, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(untrackedPatch.contains("@@ -0,0 +1"))
    #expect(untrackedPatch.contains("+new file"))
  }

  @Test("unified patch for staged, branch and renamed files")
  func unifiedPatchForStagedBranchAndRenamedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let service = GitDiffService()

    try "staged".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")
    let staged = try await service.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let stagedFile = try #require(staged.files.first(where: { $0.relativePath == "README.md" }))
    let stagedPatch = try await service.unifiedPatch(for: stagedFile, at: fixture.repoPath, mode: .staged, baseBranch: nil)
    #expect(stagedPatch.contains("-initial"))
    #expect(stagedPatch.contains("+staged"))

    try fixture.runGit("checkout", "-b", "feature/patch")
    try fixture.runGit("commit", "-m", "branch change")
    let branch = try await service.changedFiles(at: fixture.repoPath, mode: .branch, baseBranch: "main")
    let branchFile = try #require(branch.files.first(where: { $0.relativePath == "README.md" }))
    let branchPatch = try await service.unifiedPatch(for: branchFile, at: fixture.repoPath, mode: .branch, baseBranch: "main")
    #expect(branchPatch.contains("diff --git a/README.md b/README.md"))
    #expect(branchPatch.contains("+staged"))

    try fixture.runGit("mv", "README.md", "Renamed.md")
    let renamed = try await service.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let renamedFile = try #require(renamed.files.first(where: { $0.relativePath == "Renamed.md" }))
    let renamedPatch = try await service.unifiedPatch(for: renamedFile, at: fixture.repoPath, mode: .staged, baseBranch: nil)
    #expect(renamedPatch.contains("rename from README.md"))
    #expect(renamedPatch.contains("rename to Renamed.md"))
  }

  @Test("unified patch falls back to the git CLI when libgit2 fails")
  func unifiedPatchFallsBackToCLI() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let service = GitDiffService(
      renderPolicy: .default,
      largeWorktreeIndexByteThreshold: GitDiffService.defaultLargeWorktreeIndexByteThreshold,
      libGit2UnifiedPatch: { _, _, _, _, _ in throw GitDiffError.gitCommandFailed("forced libgit2 failure") }
    )
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let patch = try await service.unifiedPatch(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(patch.hasPrefix("diff --git a/README.md b/README.md"))
    #expect(patch.contains("+changed"))
  }

  @Test("unified patch over the size limit throws, from libgit2 and from the CLI")
  func unifiedPatchTooLarge() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try String(repeating: "a long changed line\n", count: 200)
      .write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    let policy = GitDiffRenderPolicy(maxFullContentBytes: 512 * 1024, maxPatchBytes: 1024)

    let libgit2 = GitDiffService(renderPolicy: policy)
    let state = try await libgit2.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    do {
      _ = try await libgit2.unifiedPatch(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
      Issue.record("expected patchTooLarge from libgit2")
    } catch GitDiffError.patchTooLarge(let path) {
      #expect(path == "README.md")
    }

    let cli = GitDiffService(
      renderPolicy: policy,
      largeWorktreeIndexByteThreshold: GitDiffService.defaultLargeWorktreeIndexByteThreshold,
      libGit2UnifiedPatch: { _, _, _, _, _ in throw GitDiffError.gitCommandFailed("forced libgit2 failure") }
    )
    do {
      _ = try await cli.unifiedPatch(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
      Issue.record("expected patchTooLarge")
    } catch GitDiffError.patchTooLarge(let path) {
      #expect(path == "README.md")
    }
  }

  @Test("uses stable file ids across refreshes")
  func usesStableFileIdsAcrossRefreshes() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let service = GitDiffService()
    let first = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let second = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(first.files.map(\.id) == second.files.map(\.id))
  }

  @Test("detects unstaged renames")
  func detectsUnstagedRenames() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try FileManager.default.moveItem(
      atPath: fixture.repoPath + "/README.md",
      toPath: fixture.repoPath + "/Renamed.md"
    )

    let service = GitDiffService()
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "Renamed.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(file.status == .renamed)
    #expect(file.oldRelativePath == "README.md")
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "initial")
  }

  @Test("uses hunk fallback for large tracked files")
  func usesHunkFallbackForLargeTrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "changed line\nsecond line\n".write(
      toFile: fixture.repoPath + "/README.md",
      atomically: true,
      encoding: .utf8
    )

    let service = GitDiffService(renderPolicy: GitDiffRenderPolicy(maxFullContentBytes: 8))
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "README.md" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.isLimitedContext)
    #expect(payload.renderMode == .limitedHunks)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed line\nsecond line")
  }

  @Test("uses no-index hunk fallback for large untracked files")
  func usesNoIndexHunkFallbackForLargeUntrackedFiles() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try "alpha\nbeta\n".write(toFile: fixture.repoPath + "/LargeNew.txt", atomically: true, encoding: .utf8)

    let service = GitDiffService(renderPolicy: GitDiffRenderPolicy(maxFullContentBytes: 4))
    let state = try await service.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first(where: { $0.relativePath == "LargeNew.txt" }))
    let payload = try await service.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)

    #expect(payload.isLimitedContext)
    #expect(payload.renderMode == .limitedHunks)
    #expect(payload.oldContent == "")
    #expect(payload.newContent == "alpha\nbeta")
  }

  // MARK: - Large-worktree gate (native git path)

  /// Forcing the gate (threshold 0) must produce the same file set, counts, and statuses
  /// as the default libgit2 path — so monorepos don't regress correctness, only get faster.
  @Test("large-worktree gate: native unstaged matches libgit2 results")
  func largeWorktreeNativeUnstagedMatchesLibgit2() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try "brand new".write(toFile: fixture.repoPath + "/Added.txt", atomically: true, encoding: .utf8)
    let libgit2 = GitDiffService()
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let expected = try await libgit2.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let actual = try await native.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(Set(actual.files.map(\.relativePath)) == Set(expected.files.map(\.relativePath)))
    let readme = try #require(actual.files.first { $0.relativePath == "README.md" })
    #expect(readme.status == .modified)
    #expect(readme.additions == 1)
    #expect(readme.deletions == 1)
    let added = try #require(actual.files.first { $0.relativePath == "Added.txt" })
    #expect(added.status == .untracked)
  }

  @Test("large-worktree gate: native staged reports status and renames")
  func largeWorktreeNativeStagedReportsStatusAndRenames() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try fixture.runGit("mv", "README.md", "Doc.md")               // staged rename
    try "added".write(toFile: fixture.repoPath + "/Added.txt", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "Added.txt")                         // staged add
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let state = try await native.changedFiles(at: fixture.repoPath, mode: .staged, baseBranch: nil)
    let renamed = try #require(state.files.first { $0.relativePath == "Doc.md" })
    #expect(renamed.status == .renamed)
    #expect(renamed.oldRelativePath == "README.md")
    let added = try #require(state.files.first { $0.relativePath == "Added.txt" })
    #expect(added.status == .added)
  }

  @Test("large-worktree gate: renders a file listed via the native path")
  func largeWorktreeGateRendersListedFile() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    let native = GitDiffService(largeWorktreeIndexByteThreshold: 0)
    let state = try await native.changedFiles(at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    let file = try #require(state.files.first { $0.relativePath == "README.md" })
    let payload = try await native.renderPayload(for: file, at: fixture.repoPath, mode: .unstaged, baseBranch: nil)
    #expect(payload.oldContent == "initial")
    #expect(payload.newContent == "changed")
  }
}

private actor LocalDiffSummaryEvaluatorSpy {
  private var queuedSummaries: [LocalDiffSummary]
  private(set) var evaluationCount = 0
  private let delay: Duration?

  init(
    queuedSummaries: [LocalDiffSummary],
    delay: Duration? = nil
  ) {
    self.queuedSummaries = queuedSummaries
    self.delay = delay
  }

  func evaluate(projectPath _: String) async -> LocalDiffSummary {
    evaluationCount += 1
    if let delay {
      try? await Task.sleep(for: delay)
    }

    guard !queuedSummaries.isEmpty else {
      return .empty
    }

    return queuedSummaries.removeFirst()
  }
}

@Suite("LocalDiffSummaryService")
struct LocalDiffSummaryServiceTests {

  @Test("counts unique files across branch staged and unstaged diffs")
  func countsUniqueFilesAcrossDiffModes() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    try fixture.runGit("checkout", "-b", "feature/summary")
    try "branch".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")
    try fixture.runGit("commit", "-m", "branch change")

    try "unstaged".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try "staged".write(toFile: fixture.repoPath + "/StagedOnly.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "StagedOnly.swift")
    try "untracked".write(toFile: fixture.repoPath + "/UntrackedOnly.swift", atomically: true, encoding: .utf8)

    let service = LocalDiffSummaryService(minimumRefreshInterval: 0)
    let summary = await service.summary(for: fixture.repoPath)

    #expect(summary.fileCount == 3)
  }

  @Test("returns empty summary for non git paths")
  func returnsEmptySummaryForNonGitPaths() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "LocalDiffSummaryServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = LocalDiffSummaryService(minimumRefreshInterval: 0)
    let summary = await service.summary(for: directory.path)

    #expect(summary == .empty)
  }

  @Test("adaptive throttle blocks invalidate inside the multiplied-duration window")
  func adaptiveThrottleBlocksInvalidateWithinWindow() async {
    let evaluator = LocalDiffSummaryEvaluatorSpy(
      queuedSummaries: [
        LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0),
        LocalDiffSummary(fileCount: 2, additions: 2, deletions: 0),
      ],
      delay: .milliseconds(200)
    )
    let service = LocalDiffSummaryService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.summary(for: "/tmp/project")
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.summary(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first.fileCount == 1)
    #expect(second.fileCount == 1)
    #expect(evaluationCount == 1)
  }

  @Test("invalidate succeeds after the adaptive window elapses", .disabled("headless-quarantine: timing-sensitive adaptive-throttle test; see TestQuarantine.md"))
  func invalidateSucceedsAfterAdaptiveWindow() async {
    let evaluator = LocalDiffSummaryEvaluatorSpy(
      queuedSummaries: [
        LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0),
        LocalDiffSummary(fileCount: 2, additions: 2, deletions: 0),
      ],
      delay: .milliseconds(100)
    )
    let service = LocalDiffSummaryService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.summary(for: "/tmp/project")
    try? await Task.sleep(for: .milliseconds(700))
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.summary(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first.fileCount == 1)
    #expect(second.fileCount == 2)
    #expect(evaluationCount == 2)
  }

  @Test("fast evaluator keeps the minimum floor", .disabled("headless-quarantine: timing-sensitive adaptive-throttle test; see TestQuarantine.md"))
  func fastEvaluatorKeepsMinimumFloor() async {
    let evaluator = LocalDiffSummaryEvaluatorSpy(
      queuedSummaries: [
        LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0),
        LocalDiffSummary(fileCount: 2, additions: 2, deletions: 0),
      ]
    )
    let service = LocalDiffSummaryService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0.1,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.summary(for: "/tmp/project")
    await service.invalidate(projectPath: "/tmp/project")
    let blocked = await service.summary(for: "/tmp/project")

    try? await Task.sleep(for: .milliseconds(300))
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.summary(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first.fileCount == 1)
    #expect(blocked.fileCount == 1)
    #expect(second.fileCount == 2)
    #expect(evaluationCount == 2)
  }

  @Test("concurrent awaiters share one evaluation and keep throttle state intact")
  func concurrentAwaitersRecordOneDuration() async {
    let evaluator = LocalDiffSummaryEvaluatorSpy(
      queuedSummaries: [
        LocalDiffSummary(fileCount: 1, additions: 1, deletions: 0),
        LocalDiffSummary(fileCount: 2, additions: 2, deletions: 0),
      ],
      delay: .milliseconds(200)
    )
    let service = LocalDiffSummaryService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0,
      adaptiveThrottleMultiplier: 3
    )

    async let first = service.summary(for: "/tmp/project")
    async let second = service.summary(for: "/tmp/project")
    let summaries = await [first, second]
    let sharedCount = await evaluator.evaluationCount

    try? await Task.sleep(for: .milliseconds(900))
    await service.invalidate(projectPath: "/tmp/project")
    let refreshed = await service.summary(for: "/tmp/project")
    let finalCount = await evaluator.evaluationCount

    #expect(summaries.map(\.fileCount) == [1, 1])
    #expect(sharedCount == 1)
    #expect(refreshed.fileCount == 2)
    #expect(finalCount == 2)
  }
}
