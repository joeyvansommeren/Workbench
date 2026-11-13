//
//  ApprovalRequestPresentation.swift
//  AgentHub
//
//  Pure: what the approval banner says about a pending Claude tool use. The
//  title names the kind of request; the detail is the command, file path, URL
//  or MCP tool the user is asked to allow.
//

import Foundation

public struct ApprovalRequestPresentation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case command
    case fileEdit
    case fileWrite
    case webRequest
    case mcpTool
    case other
  }

  public let kind: Kind
  public let title: String
  /// One line, capped at `maxDetailLength`. Nil when the tool sent nothing to show.
  public let detail: String?

  /// Long enough for a real command; the banner truncates visually and its
  /// tooltip shows the whole capped string.
  public static let maxDetailLength = 400

  public init(toolName: String, input: String?, filePath: String? = nil) {
    let input = Self.oneLine(input)
    switch toolName {
    case "Bash":
      kind = .command
      title = "Approve this command?"
      detail = Self.capped(input)
    case "Edit", "MultiEdit", "NotebookEdit":
      kind = .fileEdit
      title = "Approve this edit?"
      detail = Self.capped(Self.oneLine(filePath) ?? input)
    case "Write":
      kind = .fileWrite
      title = "Approve writing this file?"
      detail = Self.capped(Self.oneLine(filePath) ?? input)
    case "WebFetch":
      kind = .webRequest
      title = "Approve this web request?"
      detail = Self.capped(input)
    case "WebSearch":
      kind = .webRequest
      title = "Approve this web search?"
      detail = Self.capped(input)
    default:
      if let mcp = Self.mcpParts(toolName) {
        kind = .mcpTool
        title = "Approve this MCP tool?"
        let name = "\(mcp.server) · \(mcp.tool)"
        detail = Self.capped(input.map { "\(name)  \($0)" } ?? name)
      } else {
        kind = .other
        title = "Approve \(toolName.isEmpty ? "this tool" : toolName)?"
        detail = Self.capped(input)
      }
    }
  }

  public init(pending: PendingToolUse) {
    self.init(
      toolName: pending.toolName,
      input: pending.input,
      filePath: pending.codeChangeInput?.filePath
    )
  }

  /// `mcp__server__tool` → ("server", "tool"). Server names may contain "_".
  static func mcpParts(_ toolName: String) -> (server: String, tool: String)? {
    guard toolName.hasPrefix("mcp__") else { return nil }
    let rest = toolName.dropFirst("mcp__".count)
    guard let separator = rest.range(of: "__", options: .backwards) else { return nil }
    let server = String(rest[..<separator.lowerBound])
    let tool = String(rest[separator.upperBound...])
    guard !server.isEmpty, !tool.isEmpty else { return nil }
    return (server, tool)
  }

  private static func oneLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return joined.isEmpty ? nil : joined
  }

  private static func capped(_ text: String?) -> String? {
    guard let text else { return nil }
    guard text.count > maxDetailLength else { return text }
    return String(text.prefix(maxDetailLength - 1)) + "…"
  }
}
