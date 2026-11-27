//
//  LocalDiffSummaryService.swift
//  AgentHubGitDiff
//
//  Summarizes local/branch changes for compact UI entry points.
//

import Foundation

public struct LocalDiffSummary: Equatable, Sendable {
  public let fileCount: Int
  public let additions: Int
  public let deletions: Int
  public let hasUncommittedChanges: Bool?

  public static let empty = LocalDiffSummary(fileCount: 0, additions: 0, deletions: 0)

  public init(fileCount: Int, additions: Int, deletions: Int, hasUncommittedChanges: Bool? = nil) {
    self.fileCount = fileCount
    self.additions = additions
    self.deletions = deletions
    self.hasUncommittedChanges = hasUncommittedChanges
  }
}

public protocol LocalDiffSummaryServiceProtocol: Sendable {
  func cachedSummary(for projectPath: String) async -> LocalDiffSummary?
  func summary(for projectPath: String) async -> LocalDiffSummary
  func invalidate(projectPath: String) async
  func invalidateAfterPendingActivity(projectPath: String) async -> Bool
}

extension LocalDiffSummaryServiceProtocol {
  public func invalidateAfterPendingActivity(projectPath: String) async -> Bool {
    await invalidate(projectPath: projectPath)
    return !Task.isCancelled
  }
}

public actor LocalDiffSummaryService: LocalDiffSummaryServiceProtocol {
  public static let shared = LocalDiffSummaryService()

  typealias Evaluator = @Sendable (String) async -> LocalDiffSummary

  private struct InFlightEvaluation: Sendable {
    let id: UUID
    let generation: Int
    let task: Task<LocalDiffSummary, Never>
  }

  private let evaluator: Evaluator
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let minimumRefreshInterval: TimeInterval
  private let adaptiveThrottleMultiplier: Double
  private var cache: [String: LocalDiffSummary] = [:]
  private var cacheGeneration: [String: Int] = [:]
  private var inFlightTasks: [String: InFlightEvaluation] = [:]
  private var lastEvaluationStartedAt: [String: Date] = [:]
  private var lastEvaluationDuration: [String: TimeInterval] = [:]

  init(
    evaluator: Evaluator? = nil,
    minimumRefreshInterval: TimeInterval = 1.0,
    adaptiveThrottleMultiplier: Double = 3.0,
    now: @escaping @Sendable () -> Date = { .now },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) {
    self.evaluator = evaluator ?? { projectPath in
      await Self.defaultEvaluator(projectPath: projectPath)
    }
    self.now = now
    self.sleep = sleep
    self.minimumRefreshInterval = minimumRefreshInterval
    self.adaptiveThrottleMultiplier = adaptiveThrottleMultiplier
  }

  public func cachedSummary(for projectPath: String) async -> LocalDiffSummary? {
    cache[Self.normalize(projectPath)]
  }

  public func summary(for projectPath: String) async -> LocalDiffSummary {
    let normalizedProjectPath = Self.normalize(projectPath)

    if let cached = cache[normalizedProjectPath] {
      return cached
    }
    if let inFlightTask = inFlightTasks[normalizedProjectPath] {
      return await inFlightTask.task.value
    }

    let evaluator = evaluator
    let task = Task(priority: .utility) {
      await evaluator(normalizedProjectPath)
    }
    let evaluationStartedAt = now()
    lastEvaluationStartedAt[normalizedProjectPath] = evaluationStartedAt
    let inFlightEvaluation = InFlightEvaluation(
      id: UUID(),
      generation: cacheGeneration[normalizedProjectPath] ?? 0,
      task: task
    )
    inFlightTasks[normalizedProjectPath] = inFlightEvaluation

    let summary = await task.value
    if inFlightTasks[normalizedProjectPath]?.id == inFlightEvaluation.id {
      inFlightTasks.removeValue(forKey: normalizedProjectPath)
      lastEvaluationDuration[normalizedProjectPath] = now().timeIntervalSince(evaluationStartedAt)
      if (cacheGeneration[normalizedProjectPath] ?? 0) == inFlightEvaluation.generation {
        cache[normalizedProjectPath] = summary
      }
    }
    return summary
  }

  public func invalidate(projectPath: String) async {
    let normalizedProjectPath = Self.normalize(projectPath)

    if inFlightTasks[normalizedProjectPath] != nil {
      return
    }

    if let lastEvaluationStartedAt = lastEvaluationStartedAt[normalizedProjectPath],
      now().timeIntervalSince(lastEvaluationStartedAt)
        < effectiveRefreshInterval(for: normalizedProjectPath)
    {
      return
    }

    cacheGeneration[normalizedProjectPath, default: 0] += 1
    cache.removeValue(forKey: normalizedProjectPath)
  }

  /// Wait for an older scan and its throttle window before invalidating. A
  /// canceled sidebar task leaves the shared evaluator running, but does not
  /// schedule another scan after its row disappears.
  public func invalidateAfterPendingActivity(projectPath: String) async -> Bool {
    let path = Self.normalize(projectPath)
    while !Task.isCancelled {
      if let inFlight = inFlightTasks[path] {
        _ = await inFlight.task.value
        await Task.yield()
        continue
      }
      if let start = lastEvaluationStartedAt[path] {
        let remaining = effectiveRefreshInterval(for: path) - now().timeIntervalSince(start)
        if remaining > 0 {
          do { try await sleep(remaining) } catch { return false }
          continue
        }
      }
      cacheGeneration[path, default: 0] += 1
      cache.removeValue(forKey: path)
      return true
    }
    return false
  }

  /// Slow repos self-throttle: a worktree whose evaluation costs N seconds may
  /// only re-evaluate every `multiplier × N` seconds, so activity-driven
  /// invalidations can't queue back-to-back full-worktree scans. Fast repos
  /// stay on the minimum floor and keep live summaries.
  private func effectiveRefreshInterval(for normalizedProjectPath: String) -> TimeInterval {
    guard let duration = lastEvaluationDuration[normalizedProjectPath] else {
      return minimumRefreshInterval
    }
    return max(minimumRefreshInterval, adaptiveThrottleMultiplier * duration)
  }

  public nonisolated static func normalize(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  private nonisolated static func defaultEvaluator(projectPath: String) async -> LocalDiffSummary {
    await Task.detached(priority: .utility) {
      let service = GitDiffService()
      var filesByPath: [String: GitDiffFileEntry] = [:]
      var uncommittedFilesFound = false
      var uncommittedModesRead = 0

      for mode in DiffMode.allCases {
        do {
          let state = try await service.changedFiles(at: projectPath, mode: mode, baseBranch: nil)
          if mode == .staged || mode == .unstaged {
            uncommittedModesRead += 1
            uncommittedFilesFound = uncommittedFilesFound || !state.files.isEmpty
          }
          for file in state.files where filesByPath[file.relativePath] == nil {
            filesByPath[file.relativePath] = file
          }
        } catch {
          continue
        }
      }

      let additions = filesByPath.values.reduce(0) { $0 + $1.additions }
      let deletions = filesByPath.values.reduce(0) { $0 + $1.deletions }
      return LocalDiffSummary(
        fileCount: filesByPath.count,
        additions: additions,
        deletions: deletions,
        hasUncommittedChanges: uncommittedFilesFound ? true : (uncommittedModesRead == 2 ? false : nil)
      )
    }.value
  }
}
