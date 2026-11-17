import Foundation
import Testing

@testable import AgentHubSessionGraph

@Suite("CodexSessionFileScanner")
struct CodexSessionFileScannerTests {
  @Test("Reads session metadata when the first JSONL line exceeds sixteen kilobytes")
  func readsOversizedSessionMetaLine() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "55555555-5555-5555-5555-555555555555"
    let projectPath = "/tmp/oversized-project"
    let sessionFile = root.appending(path: "session.jsonl")

    try oversizedCodexSessionFileContents(
      sessionID: sessionID,
      cwd: projectPath,
      branch: "feature/oversized-meta",
      baseInstructionsLength: 24_000
    )
    .write(to: sessionFile, atomically: true, encoding: .utf8)

    let meta = try #require(CodexSessionFileScanner.readSessionMeta(from: sessionFile.path))

    #expect(meta.sessionId == sessionID)
    #expect(meta.projectPath == projectPath)
    #expect(meta.branch == "feature/oversized-meta")
    #expect(meta.sessionFilePath == sessionFile.path)

    let expectedDate = iso8601Date("2026-05-05T12:00:00.000Z")
    #expect(meta.startedAt == expectedDate)
  }
  @Test("Only explicit interactive CLI origins identify a ticket launch")
  func interactiveOrigin() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-source-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("rollout.jsonl")
    for (source, parent, expected) in [
      ("cli", false, true), ("cli", true, false), ("exec", false, false), ("unknown", false, false),
    ] {
      var payload: [String: Any] = ["id": "session-333", "cwd": "/tmp/test-333", "source": source]
      if parent { payload["parent_thread_id"] = "parent-333" }
      let data = try JSONSerialization.data(withJSONObject: [
        "type": "session_meta", "payload": payload,
      ])
      try data.write(to: file)
      #expect(
        CodexSessionFileScanner.readSessionMeta(from: file.path)?.isInteractiveCLI == expected)
    }
  }

}

private func iso8601Date(_ string: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: string) {
    return date
  }

  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}

private func oversizedCodexSessionFileContents(
  sessionID: String,
  cwd: String,
  branch: String,
  baseInstructionsLength: Int
) -> String {
  let sessionMeta: [String: Any] = [
    "timestamp": "2026-05-05T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": sessionID,
      "timestamp": "2026-05-05T12:00:00.000Z",
      "cwd": cwd,
      "git": [
        "branch": branch
      ],
      "base_instructions": [
        "text": String(repeating: "x", count: baseInstructionsLength)
      ]
    ]
  ]
  let userMessage: [String: Any] = [
    "timestamp": "2026-05-05T12:00:01.000Z",
    "type": "event_msg",
    "payload": [
      "type": "user_message",
      "message": "hello"
    ]
  ]

  return """
    \(jsonLine(sessionMeta))
    \(jsonLine(userMessage))

    """
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "codex_session_file_scanner_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
