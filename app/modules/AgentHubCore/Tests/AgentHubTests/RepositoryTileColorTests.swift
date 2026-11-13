//
//  RepositoryTileColorTests.swift
//  AgentHubTests
//

import Testing
@testable import AgentHubCore

@Suite("RepositoryTileColor")
struct RepositoryTileColorTests {

  @Test("colour is deterministic: same path always returns same colour")
  func stableAcrossRuns() {
    let path = "/Users/joey/Projects/Workbench"
    let first = RepositoryTileColor.forPath(path)
    let second = RepositoryTileColor.forPath(path)
    let third = RepositoryTileColor.forPath(path)
    #expect(first == second)
    #expect(second == third)
  }

  @Test("different paths can map to different colours")
  func differentPaths() {
    let paths = [
      "/Users/joey/Projects/Alpha",
      "/Users/joey/Projects/Beta",
      "/Users/joey/Projects/Gamma",
      "/Users/joey/Projects/Delta",
      "/Users/joey/Projects/Epsilon",
    ]
    let colours = Set(paths.map { RepositoryTileColor.forPath($0) })
    #expect(colours.count >= 2)
  }

  @Test("worktrees share parent repo colour via WorktreeModuleResolver")
  func worktreesShareParent() {
    // Simulate a worktree path that normalises to the parent root.
    let parentPath = "/Users/joey/Projects/Workbench"
    let worktreePath = "/Users/joey/Projects/Workbench/"
    // WorktreeModuleResolver.normalizedDirectoryPath strips the trailing slash.
    let resolved = WorktreeModuleResolver.normalizedDirectoryPath(worktreePath)
    #expect(resolved == parentPath)
    // Both produce the same tile colour.
    #expect(RepositoryTileColor.forPath(parentPath) == RepositoryTileColor.forPath(worktreePath))
  }

  @Test("forPath(p) == forPath(p + '/') — trailing slash is normalised")
  func trailingSlashNormalised() {
    let base = "/Users/joey/Projects/Workbench"
    #expect(RepositoryTileColor.forPath(base) == RepositoryTileColor.forPath(base + "/"))
    #expect(RepositoryTileColor.forPath(base) == RepositoryTileColor.forPath(base + "///"))
  }

  @Test("all three colours are reachable")
  func allColoursReachable() {
    var found: Set<RepositoryTileColor> = []
    for i in 0..<1000 {
      found.insert(RepositoryTileColor.forPath("/path/\(i)"))
      if found.count == 3 { break }
    }
    #expect(found.count == 3, "Expected all 3 tile colours to be reachable")
  }

  @Test("empty path does not crash")
  func emptyPath() {
    let colour = RepositoryTileColor.forPath("")
    #expect(RepositoryTileColor.allCases.contains(colour))
  }
}
