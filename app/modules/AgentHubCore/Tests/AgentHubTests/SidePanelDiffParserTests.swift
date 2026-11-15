import Testing

@testable import AgentHubCore

@Suite("SidePanelDiffParser")
struct SidePanelDiffParserTests {

  @Test("Multi-hunk modified file: headers, kinds and line numbers")
  func multiHunk() throws {
    let text = """
      diff --git a/Jira/JiraCLIStatus.swift b/Jira/JiraCLIStatus.swift
      index 1111111..2222222 100644
      --- a/Jira/JiraCLIStatus.swift
      +++ b/Jira/JiraCLIStatus.swift
      @@ -12,3 +12,3 @@ enum JiraCLIStatus
         case available(version: String)
      -  case missing
      +  case missing(installHint: String)

      @@ -40,2 +40,4 @@
       }
      +  static let hint = ""
      +  // end
       // tail
      """
    let files = SidePanelDiffParser.parse(text)
    let file = try #require(files.first)
    #expect(files.count == 1)
    #expect(file.change == .modified)
    #expect(file.oldPath == "Jira/JiraCLIStatus.swift")
    #expect(file.path == "Jira/JiraCLIStatus.swift")
    #expect(file.hunks.count == 2)

    let first = file.hunks[0]
    #expect(first.header == "@@ -12,3 +12,3 @@ enum JiraCLIStatus")
    #expect(first.lines.map(\.kind) == [.context, .removed, .added, .context])
    #expect(first.lines.map(\.oldLineNumber) == [12, 13, nil, 14])
    #expect(first.lines.map(\.newLineNumber) == [12, nil, 13, 14])
    #expect(first.lines.map(\.displayLineNumber) == [12, 13, 13, 14])
    // A blank context line written without its leading space still counts.
    #expect(first.lines[3].text == "")

    let second = file.hunks[1]
    #expect(second.oldStart == 40 && second.oldCount == 2 && second.newStart == 40 && second.newCount == 4)
    #expect(second.lines.map(\.newLineNumber) == [40, 41, 42, 43])
    #expect(second.lines.map(\.oldLineNumber) == [40, nil, nil, 41])
    #expect(file.lineCount == 8)
  }

  @Test("Added file: /dev/null old side, new-side numbers from 1")
  func addedFile() throws {
    let text = """
      diff --git a/Tests/New.swift b/Tests/New.swift
      new file mode 100644
      index 0000000..3333333
      --- /dev/null
      +++ b/Tests/New.swift
      @@ -0,0 +1,2 @@
      +import Testing
      +struct New {}
      """
    let file = try #require(SidePanelDiffParser.parse(text).first)
    #expect(file.change == .added)
    #expect(file.oldPath == nil)
    #expect(file.path == "Tests/New.swift")
    #expect(file.hunks[0].lines.map(\.newLineNumber) == [1, 2])
    #expect(file.hunks[0].lines.allSatisfy { $0.kind == .added && $0.oldLineNumber == nil })
  }

  @Test("Deleted file: path falls back to the old path")
  func deletedFile() throws {
    let text = """
      diff --git a/Old.swift b/Old.swift
      deleted file mode 100644
      --- a/Old.swift
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -line one
      -line two
      """
    let file = try #require(SidePanelDiffParser.parse(text).first)
    #expect(file.change == .deleted)
    #expect(file.newPath == nil)
    #expect(file.path == "Old.swift")
    #expect(file.hunks[0].lines.map(\.displayLineNumber) == [1, 2])
  }

  @Test("Pure rename has paths and no hunks; rename with edits keeps hunks")
  func renames() throws {
    let text = """
      diff --git a/A.swift b/B.swift
      similarity index 100%
      rename from A.swift
      rename to B.swift
      diff --git a/Dir/C.swift b/Dir/D.swift
      similarity index 90%
      rename from Dir/C.swift
      rename to Dir/D.swift
      --- a/Dir/C.swift
      +++ b/Dir/D.swift
      @@ -1 +1 @@
      -old
      +new
      """
    let files = SidePanelDiffParser.parse(text)
    #expect(files.count == 2)
    #expect(files[0].change == .renamed)
    #expect(files[0].oldPath == "A.swift")
    #expect(files[0].newPath == "B.swift")
    #expect(files[0].hunks.isEmpty)
    #expect(files[1].change == .renamed)
    #expect(files[1].oldPath == "Dir/C.swift")
    #expect(files[1].path == "Dir/D.swift")
    // `@@ -1 +1 @@`: a missing count means 1.
    #expect(files[1].hunks[0].oldCount == 1 && files[1].hunks[0].newCount == 1)
    #expect(files[1].hunks[0].lines.map(\.kind) == [.removed, .added])
  }

  @Test("Binary files are flagged and have no hunks")
  func binary() throws {
    let text = """
      diff --git a/icon.png b/icon.png
      index 4444444..5555555 100644
      Binary files a/icon.png and b/icon.png differ
      """
    let file = try #require(SidePanelDiffParser.parse(text).first)
    #expect(file.isBinary)
    #expect(file.hunks.isEmpty)
    #expect(file.path == "icon.png")
  }

  @Test("No-newline marker flags the line and is not counted")
  func noNewlineAtEOF() throws {
    let text = """
      diff --git a/x.txt b/x.txt
      --- a/x.txt
      +++ b/x.txt
      @@ -1,2 +1,2 @@
       keep
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """
    let file = try #require(SidePanelDiffParser.parse(text).first)
    let lines = file.hunks[0].lines
    #expect(lines.count == 3)
    #expect(lines.map(\.hasNoNewlineAtEnd) == [false, true, true])
    #expect(lines[2].newLineNumber == 2)
    #expect(lines[1].oldLineNumber == 2)
  }

  @Test("Hunk bodies are bounded by their counts, not by line prefixes")
  func countsBoundHunks() throws {
    // A removed line whose content starts with "-- " looks like a `---` header.
    let text = """
      diff --git a/a.sql b/a.sql
      --- a/a.sql
      +++ b/a.sql
      @@ -1,1 +1,0 @@
      --- comment
      diff --git a/b.txt b/b.txt
      --- a/b.txt
      +++ b/b.txt
      @@ -1 +1 @@
      -b
      +c
      """
    let files = SidePanelDiffParser.parse(text)
    #expect(files.count == 2)
    #expect(files[0].hunks[0].lines.map(\.text) == ["-- comment"])
    #expect(files[1].path == "b.txt")
    #expect(files[1].hunks[0].lines.count == 2)
  }

  @Test("Paths with spaces and quotes")
  func pathsWithSpaces() {
    #expect(SidePanelDiffParser.gitHeaderPaths("a/My File.swift b/My File.swift")?.new == "My File.swift")
    #expect(SidePanelDiffParser.cleanPath("\"b/caf\\303\\251.txt\"") == "caf\\303\\251.txt")
    #expect(SidePanelDiffParser.cleanPath("/dev/null") == nil)
    #expect(SidePanelDiffParser.cleanPath("a/x.txt\t2026-01-01") == "x.txt")
  }

  @Test("Hunks without a file header and empty input")
  func headerless() {
    let files = SidePanelDiffParser.parse("@@ -3,1 +3,1 @@\n-a\n+b")
    #expect(files.count == 1)
    #expect(files[0].path == nil)
    #expect(files[0].hunks[0].lines.map(\.displayLineNumber) == [3, 3])
    #expect(SidePanelDiffParser.parse("").isEmpty)
  }
}
