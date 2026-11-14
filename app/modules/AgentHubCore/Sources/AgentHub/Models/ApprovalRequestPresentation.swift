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
  /// The same text with its line breaks kept, for the banner: the user must
  /// see the whole command before approving it. Capped at
  /// `maxFullDetailLength` so a pasted blob can't stall layout. Nil exactly
  /// when `detail` is nil.
  public let fullDetail: String?

  /// Long enough for a real command in a tooltip or a VoiceOver label.
  public static let maxDetailLength = 400
  public static let maxFullDetailLength = 20_000

  public init(toolName: String, input: String?, filePath: String? = nil) {
    let input = Self.trimmed(input)
    let shown: String?
    switch toolName {
    case "Bash":
      kind = .command
      title = "Approve this command?"
      shown = input
    case "Edit", "MultiEdit", "NotebookEdit":
      kind = .fileEdit
      title = "Approve this edit?"
      shown = Self.trimmed(filePath) ?? input
    case "Write":
      kind = .fileWrite
      title = "Approve writing this file?"
      shown = Self.trimmed(filePath) ?? input
    case "WebFetch":
      kind = .webRequest
      title = "Approve this web request?"
      shown = input
    case "WebSearch":
      kind = .webRequest
      title = "Approve this web search?"
      shown = input
    default:
      if let mcp = Self.mcpParts(toolName) {
        kind = .mcpTool
        title = "Approve this MCP tool?"
        let name = "\(mcp.server) · \(mcp.tool)"
        shown = input.map { "\(name)  \($0)" } ?? name
      } else {
        kind = .other
        title = "Approve \(toolName.isEmpty ? "this tool" : toolName)?"
        shown = input
      }
    }
    detail = Self.capped(Self.oneLine(shown), to: Self.maxDetailLength)
    fullDetail = detail == nil ? nil : Self.capped(shown, to: Self.maxFullDetailLength)
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

  private static func trimmed(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }

  private static func oneLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return joined.isEmpty ? nil : joined
  }

  private static func capped(_ text: String?, to limit: Int) -> String? {
    guard let text else { return nil }
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "…"
  }
}
