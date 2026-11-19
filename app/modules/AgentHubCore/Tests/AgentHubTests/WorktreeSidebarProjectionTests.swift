import Foundation
import Observation
import Testing

@testable import AgentHubCore

@Suite("Worktree sidebar projection")
@MainActor
struct WorktreeSidebarProjectionTests {
  @Test("A delayed monitor update cannot remove a newly registered worktree from Claude")
  func delayedMonitorUpdatePreservesRegisteredWorktree() async throws {
    let monitor = TestLaunchMonitorService(publishesRegistrationUpdates: false)
    let viewModel = makeLaunchRequestViewModel(providerKind: .claude, monitorService: monitor)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
    _ = await viewModel.registerCreatedWorktree(
      name: "first",
      path: root.appendingPathComponent("first", isDirectory: true).path,
      parentRepositoryPath: repoPath
    )
    let olderRepositories = await monitor.getSelectedRepositories()
    let latest = await viewModel.registerCreatedWorktree(
      name: "latest",
      path: root.appendingPathComponent("latest", isDirectory: true).path,
      parentRepositoryPath: repoPath
    )
    try #require(viewModel.selectedRepositories.flatMap(\.worktrees).contains { $0.path == latest.path })
    try await waitForSidebarUpdate(in: viewModel) {
      await monitor.publishDelayedRegistrationSnapshot(olderRepositories)
    }

    let paths = viewModel.selectedRepositories.flatMap(\.worktrees).map(\.path)
    #expect(paths.contains(latest.path))
    #expect(viewModel.selectedRepositories.first?.name == "Refreshed")

    try await waitForSidebarUpdate(in: viewModel) {
      await monitor.setSelectedRepositories([])
    }
    #expect(viewModel.selectedRepositories.isEmpty)
  }

  @Test("A monitor read that overlaps registration cannot replace a newer sidebar list")
  func overlappingMonitorReadPreservesRegisteredWorktree() async throws {
    let monitor = TestLaunchMonitorService(publishesRegistrationUpdates: false)
    let viewModel = makeLaunchRequestViewModel(providerKind: .claude, monitorService: monitor)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo").path
    _ = await viewModel.registerCreatedWorktree(
      name: "first",
      path: root.appendingPathComponent("first").path,
      parentRepositoryPath: repoPath
    )
    let read = await monitor.pauseReadAfterPublishing()
    defer { read.release.signal() }
    try await read.started.wait()
    let latest = await viewModel.registerCreatedWorktree(
      name: "latest",
      path: root.appendingPathComponent("latest").path,
      parentRepositoryPath: repoPath
    )
    try #require(viewModel.selectedRepositories.flatMap(\.worktrees).contains { $0.path == latest.path })
    await monitor.renameRepositoriesForRefresh()

    try await waitForSidebarUpdate(in: viewModel) {
      read.release.signal()
    }

    #expect(viewModel.selectedRepositories.flatMap(\.worktrees).contains { $0.path == latest.path })
    #expect(viewModel.selectedRepositories.first?.name == "Refreshed")
  }

  private func waitForSidebarUpdate(in viewModel: CLISessionsViewModel, after update: () async -> Void) async throws {
    let sidebarUpdated = AsyncTestCompletion()
    withObservationTracking {
      _ = viewModel.selectedRepositories
    } onChange: {
      sidebarUpdated.signal()
    }
    await update()
    try await sidebarUpdated.wait()
  }
}
