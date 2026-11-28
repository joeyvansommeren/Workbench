import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser retention")
struct SessionJSONLParserRetentionTests {

  @Test("Captures the complete final assistant message for workflow handoff")
  func capturesFinalAssistantMessage() {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = """
      {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","stop_reason":"end_turn","content":[\
      {"type":"text","text":"Implementation complete."},{"type":"text","text":"All tests pass."}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.currentStatus == .responseReady)
    #expect(result.lastAssistantMessage == "Implementation complete.\nAll tests pass.")
  }

  @Test("A string prompt clears prior response readiness before the next tool runs")
  func startsTurnFromStringPrompt() {
    let firstTurn = [
      #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Review the fixture."}]}}"#,
      #"{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Reviewed."}]}}"#,
    ]
    let metadata = [
      #"{"type":"user","timestamp":"2026-01-01T00:00:02Z","isMeta":true,"message":{"role":"user","content":"Hook output"}}"#,
      #"{"type":"user","timestamp":"2026-01-01T00:00:02Z","isCompactSummary":true,"message":{"role":"user","content":"Previously in this session"}}"#,
      #"{"type":"user","timestamp":"2026-01-01T00:00:02Z","message":{"role":"user","content":"<task-notification>Completed.</task-notification>"}}"#,
      #"{"type":"user","timestamp":"2026-01-01T00:00:02Z","message":{"role":"user","content":{"text":"Malformed input"}}}"#,
    ]
    let prompt = #"{"type":"user","timestamp":"2026-01-01T00:00:03Z","message":{"role":"user","content":"Read the next fixture."}}"#
    let tool = #"{"type":"assistant","timestamp":"2026-01-01T00:00:04Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read","id":"read-1","input":{"file_path":"fixture.txt"}}]}}"#
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(firstTurn + metadata, into: &result)
    #expect(result.currentStatus == .responseReady)
    #expect(result.messageCount == 2)
    let completedAt = result.turnProgress.lastCompletedAt

    SessionJSONLParser.parseNewLines([prompt], into: &result)
    let promptedAt = Date(timeIntervalSince1970: 1_767_225_603)
    SessionJSONLParser.updateCurrentStatus(&result, now: promptedAt)
    #expect(result.currentStatus == .thinking)
    #expect(result.turnProgress.startedAt == promptedAt)
    #expect(result.recentActivities.last?.type == .userMessage)
    #expect(result.recentActivities.last?.description == "Read the next fixture.")

    SessionJSONLParser.parseNewLines([tool], into: &result)
    SessionJSONLParser.updateCurrentStatus(&result, now: promptedAt.addingTimeInterval(1))
    #expect(result.currentStatus == .executingTool(name: "Read"))
    #expect(result.turnProgress.phase == .working)
    #expect(result.turnProgress.lastCompletedAt == completedAt)
  }

  @Test("Treats Claude AskUserQuestion as input instead of approval")
  func detectsClaudeUserQuestion() {
    let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
    let line = """
      {"type":"assistant","timestamp":"\(timestamp)","message":{"role":"assistant","content":[{"type":"tool_use","id":"question-1","name":"AskUserQuestion","input":{"questions":[]}}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.currentStatus == .awaitingApproval(tool: "AskUserQuestion"))
    #expect(SidebarSessionAttention(status: result.currentStatus) == .inputRequired)
  }

  @Test("Compacts older code change activities but keeps the newest five detailed")
  func compactsOlderCodeChangeActivities() {
    let lines = (1...7).map { index in
      """
      {"type":"assistant","timestamp":"2026-01-01T00:00:0\(index)Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"write-\(index)","name":"Write","input":{"file_path":"/tmp/File\(index).swift","content":"struct File\(index) {}"}}]}}
      """
    }

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.recentActivities.count == 7)

    let compactedInputs = result.recentActivities.prefix(2).compactMap(\.toolInput)
    #expect(compactedInputs.count == 2)
    let allCompactedNewStringNil = compactedInputs.allSatisfy { $0.newString == nil }
    #expect(allCompactedNewStringNil)
    let allCompactedAreWrites = compactedInputs.allSatisfy { $0.toolType == .write }
    #expect(allCompactedAreWrites)
    #expect(compactedInputs.map(\.filePath) == ["/tmp/File1.swift", "/tmp/File2.swift"])

    let retainedInputs = result.recentActivities.suffix(5).compactMap(\.toolInput)
    #expect(retainedInputs.count == 5)
    let allRetainedHaveNewString = retainedInputs.allSatisfy { $0.newString != nil }
    #expect(allRetainedHaveNewString)
    #expect(result.pendingToolUses["write-1"]?.codeChangeInput?.newString == "struct File1 {}")
  }

  @Test("Caps detected resource links to the newest fifty URLs")
  func capsDetectedResourceLinks() {
    let lines = (1...55).map { index in
      """
      {"type":"assistant","timestamp":"2026-01-01T00:00:\(String(format: "%02d", index))Z","message":{"role":"assistant","content":[{"type":"text","text":"Reference https://example\(index).com/resource"}]}}
      """
    }

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(lines, into: &result)

    let urls = result.detectedResourceLinks.map(\.url)
    #expect(urls.count == 50)
    #expect(!urls.contains("https://example1.com/resource"))
    #expect(!urls.contains("https://example5.com/resource"))
    #expect(urls.first == "https://example6.com/resource")
    #expect(urls.last == "https://example55.com/resource")
  }
}
