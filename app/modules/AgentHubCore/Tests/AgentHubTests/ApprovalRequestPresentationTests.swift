import Foundation
import Testing

@testable import AgentHubCore

@Suite("Approval request presentation")
struct ApprovalRequestPresentationTests {
  @Test("Bash shows the command")
  func bashCommand() {
    let presentation = ApprovalRequestPresentation(
      toolName: "Bash", input: "gh pr review 212 --comment --body-file review.md")
    #expect(presentation.kind == .command)
    #expect(presentation.title == "Approve this command?")
    #expect(presentation.detail == "gh pr review 212 --comment --body-file review.md")
  }

  @Test("Edit, MultiEdit and Write show the full path when the code change carries it")
  func filePaths() {
    let path = "/Users/me/repo/Sources/App/Foo.swift"
    for tool in ["Edit", "MultiEdit"] {
      let presentation = ApprovalRequestPresentation(toolName: tool, input: "Foo.swift", filePath: path)
      #expect(presentation.kind == .fileEdit)
      #expect(presentation.title == "Approve this edit?")
      #expect(presentation.detail == path)
    }
    let write = ApprovalRequestPresentation(toolName: "Write", input: "Foo.swift", filePath: path)
    #expect(write.kind == .fileWrite)
    #expect(write.title == "Approve writing this file?")
    #expect(write.detail == path)
  }

  @Test("Without a code change the file name from the input is shown")
  func fileNameFallback() {
    let presentation = ApprovalRequestPresentation(toolName: "Edit", input: "Foo.swift")
    #expect(presentation.detail == "Foo.swift")
  }

  @Test("A pending tool use reads its file path from the code change")
  func fromPendingToolUse() {
    let pending = PendingToolUse(
      toolName: "Write", toolUseId: "t1", timestamp: Date(), input: "Foo.swift",
      codeChangeInput: CodeChangeInput(toolType: .write, filePath: "/repo/Foo.swift"))
    #expect(ApprovalRequestPresentation(pending: pending).detail == "/repo/Foo.swift")
  }

  @Test("WebFetch shows the URL")
  func webFetch() {
    let presentation = ApprovalRequestPresentation(toolName: "WebFetch", input: "https://example.com/docs")
    #expect(presentation.kind == .webRequest)
    #expect(presentation.title == "Approve this web request?")
    #expect(presentation.detail == "https://example.com/docs")
  }

  @Test("MCP tools show server and tool, with the input when present")
  func mcpTool() {
    let presentation = ApprovalRequestPresentation(toolName: "mcp__claude_ai_Linear__save_issue", input: nil)
    #expect(presentation.kind == .mcpTool)
    #expect(presentation.title == "Approve this MCP tool?")
    #expect(presentation.detail == "claude_ai_Linear · save_issue")

    let withInput = ApprovalRequestPresentation(toolName: "mcp__github__create_pr", input: "Fix acli")
    #expect(withInput.detail == "github · create_pr  Fix acli")
  }

  @Test("Unknown tools name the tool and show any input")
  func unknownTool() {
    let presentation = ApprovalRequestPresentation(toolName: "Skill", input: "deploy")
    #expect(presentation.kind == .other)
    #expect(presentation.title == "Approve Skill?")
    #expect(presentation.detail == "deploy")

    let empty = ApprovalRequestPresentation(toolName: "", input: "  ")
    #expect(empty.title == "Approve this tool?")
    #expect(empty.detail == nil)
  }

  @Test("Detail is one line and capped with an ellipsis")
  func truncation() {
    let multiline = ApprovalRequestPresentation(toolName: "Bash", input: "cd app\nmake test")
    #expect(multiline.detail == "cd app make test")

    let long = String(repeating: "a", count: ApprovalRequestPresentation.maxDetailLength + 50)
    let capped = ApprovalRequestPresentation(toolName: "Bash", input: long).detail ?? ""
    #expect(capped.count == ApprovalRequestPresentation.maxDetailLength)
    #expect(capped.hasSuffix("…"))

    let exact = String(repeating: "b", count: ApprovalRequestPresentation.maxDetailLength)
    #expect(ApprovalRequestPresentation(toolName: "Bash", input: exact).detail == exact)
  }
}
