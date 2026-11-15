//
//  SessionRemovalMessages.swift
//  AgentHub
//
//  Confirmation text for removing a repository or a worktree from Workbench.
//  Shared by the legacy sidebar and the new shell's tree so both say the
//  same thing.
//

import Foundation

enum SessionRemovalMessages {
  static func repository(name: String, sessionCount: Int, workspaceCount: Int) -> String {
    var effects: [String] = []
    if sessionCount > 0 {
      effects.append("archive \(sessionCount) active \(sessionCount == 1 ? "thread" : "threads")")
    }
    if workspaceCount > 0 {
      effects.append("close \(workspaceCount) \(workspaceCount == 1 ? "workspace" : "workspaces")")
    }
    guard !effects.isEmpty else { return "This will remove \(name) from your list." }
    return "This will \(effects.joined(separator: " and ")) and remove \(name) from your list."
  }

  static func worktree(name: String, sessionCount: Int) -> String {
    if sessionCount > 0 {
      let threadLabel = sessionCount == 1 ? "thread" : "threads"
      return "This will archive \(sessionCount) focused \(threadLabel) "
        + "and stop focusing \(name) in Workbench. The worktree stays on disk."
    }
    return "This will stop focusing \(name) in Workbench. The worktree stays on disk."
  }
}
