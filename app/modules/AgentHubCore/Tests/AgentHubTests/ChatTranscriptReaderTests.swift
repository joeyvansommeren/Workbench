import Foundation
import Testing

@testable import AgentHubCore

@Suite("Chat transcript reader")
struct ChatTranscriptReaderTests {
  private func kinds(_ items: [ChatTranscriptItem]) -> [ChatTranscriptItem.Kind] { items.map(\.kind) }

  @Test("Claude: your text, replies, and tool steps; meta and thinking stay hidden")
  func claudeLines() {
    let lines = [
      #"{"type":"user","message":{"role":"user","content":"Fix the login bug"}}"#,
      #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
      #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"git status\nmore"}}]}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
    ]
    let items = lines.flatMap { ChatTranscriptReader.claudeItems(line: Data($0.utf8), idPrefix: "x") }
    #expect(kinds(items) == [.user("Fix the login bug"), .assistant("On it."), .tool(name: "Bash", summary: "git status")])
  }

  @Test("Claude: compaction is a notice; background tasks, notifications, and queue records are runtime events")
  func claudeRuntimeRecords() {
    let lines = [
      #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"auto","preTokens":467909,"durationMs":128412}}"#,
      #"{"type":"system","subtype":"stop_hook_summary","content":"x"}"#,
      #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued..."}}"#,
      #"{"type":"user","timestamp":"2026-10-22T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Command running in background with ID: bwhqvcbym. Output is being written to: /tmp/x"}]}}"#,
      #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"Command running in background with ID: by7ucxdh3"}]}]}}"#,
      #"{"type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>bwhqvcbym</task-id>\n<status>completed</status>\n</task-notification>"}}"#,
      #"{"type":"user","message":{"role":"user","content":"<system-reminder>\n[SYSTEM NOTIFICATION]\n<task-notification>\n<task-id>by7ucxdh3</task-id>\n</task-notification>"}}"#,
      #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-22T12:09:06.410Z","sessionId":"s","content":"<task-notification>\n<task-id>bwhqvcbym</task-id>"}"#,
      #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-22T12:09:07.000Z","sessionId":"s","content":"please also run the tests"}"#,
      #"{"type":"queue-operation","operation":"remove","timestamp":"2026-10-22T12:09:07.932Z","sessionId":"s","content":"<task-notification>\n<task-id>bwhqvcbym</task-id>"}"#,
      #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-10-22T12:11:53.728Z","sessionId":"s"}"#,
      #"{"type":"user","message":{"role":"user","content":"real question"}}"#,
    ]
    let entries = lines.map { ChatTranscriptReader.claudeEntry(line: Data($0.utf8), idPrefix: "x") }
    #expect(
      kinds(entries.flatMap(\.items)) == [
        .notice(.contextCompacted(preTokens: 467_909, durationMs: 128_412)),
        .user("real question"),
      ])
    let events = entries.flatMap(\.events)
    #expect(events.count == 8)
    #expect(events[0] == .backgroundTaskStarted(id: "bwhqvcbym", at: ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")))
    #expect(events[1] == .backgroundTaskStarted(id: "by7ucxdh3", at: nil))
    #expect(events[2] == .backgroundTaskFinished(id: "bwhqvcbym"))
    #expect(events[3] == .backgroundTaskFinished(id: "by7ucxdh3"))
    guard case .enqueue(let text, _, let isInternal) = events[4] else { Issue.record("expected enqueue"); return }
    #expect(text.hasPrefix("<task-notification>") && isInternal)
    #expect(events[5] == .enqueue(text: "please also run the tests", at: ISO8601DateFormatter().date(from: "2026-10-22T12:09:07Z"), isInternal: false))
    #expect(events[6] == .remove(text: "<task-notification>\n<task-id>bwhqvcbym</task-id>"))
    #expect(events[7] == .dequeue)

    var runtime = ChatTranscriptRuntime()
    for event in events { runtime.apply(event) }
    #expect(runtime.unfinishedBackgroundTasks.isEmpty)
    #expect(runtime.visibleQueue.isEmpty)  // the user's entry was dequeued (submitted)

    #expect(ChatTranscriptReader.finishedBackgroundTaskID(in: "please read <task-id>x</task-id>") == nil)
    #expect(ChatTranscriptReader.startedBackgroundTaskID(in: "ok") == nil)
    #expect(ChatTranscriptReader.isMachineInput("<task-notification>x"))
    #expect(!ChatTranscriptReader.isMachineInput("hello"))
  }

  @Test("Runtime facts survive the item window cap and reset with the file")
  func runtimeOutlivesItemWindow() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = ChatTranscriptReader(maxItems: 2)
    var text = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"Command running in background with ID: longrun"}]}}"# + "\n"
    text += #"{"type":"queue-operation","operation":"enqueue","content":"waiting"}"# + "\n"
    for index in 0..<5 { text += userLine("m\(index)") }
    try text.write(to: url, atomically: false, encoding: .utf8)

    let load = await reader.load(at: url.path, provider: .claude)
    #expect(load.items.count == 2)  // window capped
    #expect(load.runtime.unfinishedBackgroundTasks.map(\.id) == ["longrun"])
    #expect(load.runtime.visibleQueue.map(\.text) == ["waiting"])

    try userLine("fresh").write(to: url, atomically: true, encoding: .utf8)  // replaced file
    let reset = await reader.load(at: url.path, provider: .claude)
    #expect(reset.runtime == ChatTranscriptRuntime())
    #expect(kinds(reset.items) == [.user("fresh")])
  }

  @Test("Codex: injected context is dropped, exec commands become tool steps")
  func codexLines() {
    let lines = [
      ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\n..."},{"type":"input_text","text":"<environment_context>x</environment_context>"},{"type":"input_text","text":"Review PR 12"}]}}"##,
      ##"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"##,
      ##"{"type":"response_item","payload":{"type":"reasoning","encrypted_content":"x"}}"##,
      ##"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd:\"gh pr view 12\"})"}}"##,
      ##"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"git\",\"diff\"]}"}}"##,
      ##"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Looks good."}]}}"##,
    ]
    let items = lines.flatMap { ChatTranscriptReader.codexItems(line: Data($0.utf8), idPrefix: "x") }
    #expect(
      kinds(items) == [
        .user("Review PR 12"), .tool(name: "exec", summary: "gh pr view 12"),
        .tool(name: "shell", summary: "git diff"), .assistant("Looks good."),
      ])
  }

  @Test("Reads only appended lines and waits for a partial last line")
  func incremental() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let first = #"{"type":"user","message":{"role":"user","content":"one"}}"# + "\n"
    try first.write(to: url, atomically: true, encoding: .utf8)
    let reader = ChatTranscriptReader()
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("one")])

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}"# + "\n" + #"{"type":"user","mes"#).utf8))
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("one"), .assistant("two")])

    try handle.write(contentsOf: Data((#"sage":{"role":"user","content":"three"}}"# + "\n").utf8))
    try handle.close()
    #expect(
      kinds(await reader.items(at: url.path, provider: .claude))
        == [.user("one"), .assistant("two"), .user("three")])
  }

  private func userLine(_ text: String) -> String {
    #"{"type":"user","message":{"role":"user","content":""# + text + "\"}}\n"
  }

  @Test("A same-size or larger rewrite, an atomic replace, and a truncate all reload")
  func rewrites() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = ChatTranscriptReader()
    try userLine("AAA").write(to: url, atomically: false, encoding: .utf8)
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("AAA")])

    // Same length, rewritten in place (same inode).
    try Data(userLine("BBB").utf8).write(to: url)
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("BBB")])

    // Larger rewrite in place whose old prefix changed.
    try Data((userLine("CCC") + userLine("DDD")).utf8).write(to: url)
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("CCC"), .user("DDD")])

    // Atomic replace (new inode), same length as before.
    try (userLine("EEE") + userLine("FFF")).write(to: url, atomically: true, encoding: .utf8)
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("EEE"), .user("FFF")])

    // Truncate.
    try Data(userLine("G").utf8).write(to: url)
    #expect(kinds(await reader.items(at: url.path, provider: .claude)) == [.user("G")])
  }

  @Test("Missing, empty, and present files are told apart")
  func loadStates() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let reader = ChatTranscriptReader()
    #expect(await reader.load(at: url.path, provider: .claude) == .missing)
    try "".write(to: url, atomically: false, encoding: .utf8)
    #expect(await reader.load(at: url.path, provider: .claude) == .loaded([]))
    try userLine("hi").write(to: url, atomically: false, encoding: .utf8)
    #expect(kinds(await reader.load(at: url.path, provider: .claude).items) == [.user("hi")])
    try FileManager.default.removeItem(at: url)
    #expect(await reader.load(at: url.path, provider: .claude) == .missing)
    // Back after removal: a fresh read, not the cached items.
    try userLine("again").write(to: url, atomically: false, encoding: .utf8)
    #expect(kinds(await reader.load(at: url.path, provider: .claude).items) == [.user("again")])
  }

  @Test("Tracked files are capped; the oldest is dropped and re-read from scratch")
  func trackedFileCap() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("chat-cap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = ChatTranscriptReader(maxTrackedFiles: 2)
    let files = (0..<3).map { directory.appendingPathComponent("\($0).jsonl") }
    for (index, file) in files.enumerated() {
      try userLine("m\(index)").write(to: file, atomically: false, encoding: .utf8)
      _ = await reader.items(at: file.path, provider: .claude)
    }
    // File 0 was evicted; reading it again must still return its content.
    #expect(kinds(await reader.items(at: files[0].path, provider: .claude)) == [.user("m0")])
  }
}

@Suite("Terminal workspace active tab")
struct TerminalWorkspaceActiveTabTests {
  @Test("The active tab of the active panel reports its linked child session")
  func activeLinkedSession() {
    let child = TerminalWorkspaceLinkedSessionSnapshot(provider: .codex, sessionId: "child-1")
    let snapshot = TerminalWorkspaceSnapshot(
      panels: [
        TerminalWorkspacePanelSnapshot(
          role: .primary,
          tabs: [
            TerminalWorkspaceTabSnapshot(role: .agent, name: "Claude"),
            TerminalWorkspaceTabSnapshot(role: .agent, name: "Codex", linkedSession: child),
          ],
          activeTabIndex: 1),
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary, tabs: [TerminalWorkspaceTabSnapshot(role: .shell)]),
      ],
      activePanelIndex: 0)
    #expect(snapshot.activeLinkedSession == child)

    var onAgent = snapshot
    onAgent.panels[0].activeTabIndex = 0
    #expect(onAgent.activeLinkedSession == nil)

    var onShell = snapshot
    onShell.activePanelIndex = 1
    #expect(onShell.activeLinkedSession == nil)

    var outOfRange = snapshot
    outOfRange.activePanelIndex = 9
    #expect(outOfRange.activeTab?.name == "Claude")
  }
}

@Suite("Chat actions")
struct ChatActionsTests {
  @Test("Questions get numbered options plus yes/no; statements get nothing")
  func quickReplies() {
    let question = """
      I found two ways to fix it.

      1. **Patch** the parser
      2. Rewrite the reader

      Which one do you want?
      """
    let replies = QuickReply.replies(for: question)
    #expect(replies.map(\.message) == ["1", "2", "Yes, go ahead.", "No."])
    #expect(replies.first?.label == "1 · Patch the parser")
    #expect(QuickReply.replies(for: "Done. All tests pass.").isEmpty)
  }

  @Test("Fenced code blocks are extracted for one-click copy")
  func codeBlocks() {
    let text = "Run this:\n\n```bash\nnpm install\nnpm test\n```\n\nand ```\n```\n"
    let blocks = ChatCodeBlocks.extract(from: text)
    #expect(blocks.map(\.code) == ["npm install\nnpm test"])
    #expect(blocks.first?.preview == "npm install")
  }
}

@Suite("Chat markdown text")
struct ChatMarkdownTextTests {
  @Test("Splits prose and fenced code; keeps an unclosed fence as code")
  func segments() {
    let text = "Intro **bold**\n\n```swift\nlet x = 1\n```\nAfter\n```\nopen"
    #expect(
      ChatMarkdownText.segments(of: text)
        == [.prose("Intro **bold**"), .code("let x = 1"), .prose("After"), .code("open")])
  }

  @Test("Turns a pipe table into rows; a pipe line without divider stays prose")
  func tables() {
    let text = "Open PRs:\n\n| PR | CI |\n|---|:--:|\n| [#1057](https://x) | groen |\n| #1042 |\n\nDone\n| not a table |"
    #expect(
      ChatMarkdownText.segments(of: text)
        == [
          .prose("Open PRs:"),
          .table([["PR", "CI"], ["[#1057](https://x)", "groen"], ["#1042"]]),
          .prose("Done\n| not a table |"),
        ])
  }

  @Test("Pipes inside a code fence stay code")
  func tableInCode() {
    #expect(ChatMarkdownText.segments(of: "```\n| a |\n|---|\n```") == [.code("| a |\n|---|")])
  }

  @Test("Inline markdown keeps line breaks and turns headings bold")
  func inline() {
    let rendered = ChatMarkdownText.inline("# Title\nline one\nline `two`")
    #expect(String(rendered.characters) == "Title\nline one\nline two")
  }
}
