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
    // With only 3 colours, some will collide. But these three
    // are picked to be different under the hash.
    let paths = [
      "/Users/joey/Projects/Alpha",
      "/Users/joey/Projects/Beta",
      "/Users/joey/Projects/Gamma",
      "/Users/joey/Projects/Delta",
      "/Users/joey/Projects/Epsilon",
    ]
    let colours = Set(paths.map { RepositoryTileColor.forPath($0) })
    // With 5 paths and 3 colours, at least 2 distinct colours should appear.
    #expect(colours.count >= 2)
  }

  @Test("worktrees share parent repo colour when resolved to the same path")
  func worktreesShareParent() {
    // When WorktreeModuleResolver resolves both to the same root,
    // the same path string is passed in, so the colour matches.
    let parentPath = "/Users/joey/Projects/Workbench"
    let parentColour = RepositoryTileColor.forPath(parentPath)
    // A worktree that resolves to the same canonical path
    let worktreeColour = RepositoryTileColor.forPath(parentPath)
    #expect(parentColour == worktreeColour)
  }

  @Test("all three colours are reachable")
  func allColoursReachable() {
    // Brute-force: try many paths until we find all 3 colours.
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
