//
//  SidePanelDiffParser.swift
//  AgentHub
//
//  Parses unified diff text (`git diff` / libgit2 patch output) into files
//  and hunks for the compact side panel Diff (`SidePanelDiffView`). Pure:
//  no git, no WebKit.
//

import Foundation

struct SidePanelDiffLine: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case context
    case added
    case removed
  }

  let kind: Kind
  /// Line number in the old file. Nil for added lines.
  let oldLineNumber: Int?
  /// Line number in the new file. Nil for removed lines.
  let newLineNumber: Int?
  let text: String
  /// Followed by `\ No newline at end of file`.
  var hasNoNewlineAtEnd = false

  /// The single number the panel shows: the new line, or the old line for a
  /// removed line (as in the prototype's `.hunk-line .ln`).
  var displayLineNumber: Int? { newLineNumber ?? oldLineNumber }
}

struct SidePanelDiffHunk: Equatable, Sendable {
  /// The full `@@ -a,b +c,d @@ context` line.
  let header: String
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  var lines: [SidePanelDiffLine]
}

struct SidePanelParsedFileDiff: Equatable, Sendable {
  enum Change: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
  }

  var oldPath: String?
  var newPath: String?
  var change: Change = .modified
  var isBinary = false
  var hunks: [SidePanelDiffHunk] = []

  /// The path the file has after the change (the old path for a deletion).
  var path: String? { newPath ?? oldPath }
  var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

enum SidePanelDiffParser {
  /// Parses every file in `text`. Text with hunks but no file header yields
  /// one file without paths.
  static func parse(_ text: String) -> [SidePanelParsedFileDiff] {
    var parser = State()
    // `omittingEmptySubsequences: false` keeps blank context lines that some
    // tools write without the leading space.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for rawLine in lines {
      parser.consume(rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine))
    }
    return parser.finish()
  }

  /// Parses a hunk header such as `@@ -12,7 +12,8 @@ enum Foo`. A missing
  /// count means 1, as in git.
  static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
    guard line.hasPrefix("@@ ") else { return nil }
    let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
    guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
    guard let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else { return nil }
    return (old.start, old.count, new.start, new.count)
  }

  private static func range(_ text: Substring) -> (start: Int, count: Int)? {
    let pieces = text.split(separator: ",", omittingEmptySubsequences: false)
    guard let start = Int(pieces[0]) else { return nil }
    if pieces.count == 1 { return (start, 1) }
    guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
    return (start, count)
  }

  /// `a/foo` → `foo`; `/dev/null` → nil; strips the quotes git adds around
  /// paths with special characters.
  static func cleanPath(_ raw: String) -> String? {
    var path = raw
    // `--- a/foo\t(timestamp)` from non-git tools.
    if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
    if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
      path = String(path.dropFirst().dropLast())
    }
    if path == "/dev/null" { return nil }
    if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
    return path
  }

  /// Splits `a/x b/y` from a `diff --git` line. With spaces in the paths the
  /// split is ambiguous; prefer the split where both sides are equal.
  static func gitHeaderPaths(_ rest: String) -> (old: String, new: String)? {
    let separators = rest.ranges(of: " b/")
    guard !separators.isEmpty else { return nil }
    let candidates = separators.map { separator in
      (old: String(rest[..<separator.lowerBound]), new: String(rest[rest.index(after: separator.lowerBound)...]))
    }
    let chosen = candidates.first { cleanPath($0.old) == cleanPath($0.new) } ?? candidates[0]
    guard let old = cleanPath(chosen.old), let new = cleanPath(chosen.new) else { return nil }
    return (old, new)
  }

  // MARK: - State machine

  private struct State {
    var files: [SidePanelParsedFileDiff] = []
    var current: SidePanelParsedFileDiff?
    var hunk: SidePanelDiffHunk?
    var oldRemaining = 0
    var newRemaining = 0
    var nextOld = 0
    var nextNew = 0

    mutating func consume(_ line: String) {
      if hunk != nil, oldRemaining > 0 || newRemaining > 0 {
        if consumeHunkBody(line) { return }
      }
      // The marker follows the hunk's last line, after the counts reach zero.
      if line.hasPrefix("\\") {
        markNoNewline()
        return
      }
      closeHunk()

      if line.hasPrefix("diff --git ") {
        startFile()
        if let paths = SidePanelDiffParser.gitHeaderPaths(String(line.dropFirst("diff --git ".count))) {
          current?.oldPath = paths.old
          current?.newPath = paths.new
        }
      } else if line.hasPrefix("@@ ") {
        startHunk(line)
      } else if line.hasPrefix("--- ") {
        if current == nil || current?.hunks.isEmpty == false { startFile() }
        let path = SidePanelDiffParser.cleanPath(String(line.dropFirst(4)))
        current?.oldPath = path
        if path == nil { current?.change = .added }
      } else if line.hasPrefix("+++ ") {
        if current == nil { startFile() }
        let path = SidePanelDiffParser.cleanPath(String(line.dropFirst(4)))
        current?.newPath = path
        if path == nil { current?.change = .deleted }
      } else if line.hasPrefix("new file mode") {
        current?.change = .added
      } else if line.hasPrefix("deleted file mode") {
        current?.change = .deleted
      } else if line.hasPrefix("rename from ") {
        current?.oldPath = String(line.dropFirst("rename from ".count))
        current?.change = .renamed
      } else if line.hasPrefix("rename to ") {
        current?.newPath = String(line.dropFirst("rename to ".count))
        current?.change = .renamed
      } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
        if current == nil { startFile() }
        current?.isBinary = true
      }
      // Anything else (index, mode, similarity lines) is header noise.
    }

    /// Returns false when the line can't belong to the hunk (a truncated or
    /// miscounted hunk), so the caller treats it as a header line.
    mutating func consumeHunkBody(_ line: String) -> Bool {
      let first = line.first
      let text = line.isEmpty ? "" : String(line.dropFirst())
      switch first {
      case " ", nil:
        append(.init(kind: .context, oldLineNumber: nextOld, newLineNumber: nextNew, text: text))
        nextOld += 1
        nextNew += 1
        oldRemaining -= 1
        newRemaining -= 1
      case "-":
        append(.init(kind: .removed, oldLineNumber: nextOld, newLineNumber: nil, text: text))
        nextOld += 1
        oldRemaining -= 1
      case "+":
        append(.init(kind: .added, oldLineNumber: nil, newLineNumber: nextNew, text: text))
        nextNew += 1
        newRemaining -= 1
      case "\\":
        markNoNewline()
      default:
        return false
      }
      return true
    }

    mutating func append(_ line: SidePanelDiffLine) {
      hunk?.lines.append(line)
    }

    mutating func markNoNewline() {
      if let last = hunk?.lines.indices.last {
        hunk?.lines[last].hasNoNewlineAtEnd = true
      } else if let lastHunk = current?.hunks.indices.last,
        let lastLine = current?.hunks[lastHunk].lines.indices.last {
        current?.hunks[lastHunk].lines[lastLine].hasNoNewlineAtEnd = true
      }
    }

    mutating func startHunk(_ line: String) {
      guard let range = SidePanelDiffParser.parseHunkHeader(line) else { return }
      if current == nil { startFile() }
      hunk = SidePanelDiffHunk(
        header: line, oldStart: range.oldStart, oldCount: range.oldCount,
        newStart: range.newStart, newCount: range.newCount, lines: [])
      oldRemaining = range.oldCount
      newRemaining = range.newCount
      nextOld = range.oldStart
      nextNew = range.newStart
    }

    mutating func closeHunk() {
      if let hunk { current?.hunks.append(hunk) }
      hunk = nil
      oldRemaining = 0
      newRemaining = 0
    }

    mutating func startFile() {
      closeHunk()
      if let current { files.append(current) }
      current = SidePanelParsedFileDiff()
    }

    mutating func finish() -> [SidePanelParsedFileDiff] {
      closeHunk()
      if let current { files.append(current) }
      current = nil
      return files
    }
  }
}
