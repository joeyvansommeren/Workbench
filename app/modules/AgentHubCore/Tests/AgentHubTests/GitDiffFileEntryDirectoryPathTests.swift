import Testing

@testable import AgentHubGitDiff

/// `directoryPath` splits the relative path as a string. It used to go
/// through `URL(fileURLWithPath:)`, which resolved it against the current
/// directory and showed an absolute folder such as `/private/tmp/Jira/…`.
@Suite("GitDiffFileEntry directoryPath")
struct GitDiffFileEntryDirectoryPathTests {
  private func entry(_ relativePath: String) -> GitDiffFileEntry {
    GitDiffFileEntry(
      filePath: "/repo/" + relativePath,
      relativePath: relativePath,
      additions: 1,
      deletions: 0
    )
  }

  @Test("a relative path keeps a relative folder")
  func relativePath() {
    #expect(entry("Sources/View.swift").directoryPath == "Sources")
  }

  @Test("a nested path keeps every folder, no trailing slash")
  func nestedPath() {
    #expect(entry("app/modules/Core/Sources/View.swift").directoryPath == "app/modules/Core/Sources")
  }

  @Test("a file at the repository root has no folder")
  func rootLevelFile() {
    #expect(entry("README.md").directoryPath == "")
  }

  @Test("spaces in folder and file names are kept as they are")
  func pathWithSpaces() {
    #expect(entry("My Folder/Sub Folder/My File.swift").directoryPath == "My Folder/Sub Folder")
  }

  @Test("the folder never becomes absolute")
  func neverAbsolute() {
    #expect(!entry("Jira/Board.swift").directoryPath.hasPrefix("/"))
    #expect(entry("Jira/Board.swift").fileName == "Board.swift")
  }
}
