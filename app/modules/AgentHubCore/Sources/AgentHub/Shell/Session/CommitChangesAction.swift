//
//  CommitChangesAction.swift
//  AgentHub
//
//  "Commit N files…" in the session side panel. Workbench never commits by
//  itself: it asks the agent to commit, the same way "Create PR" asks it to
//  open a pull request. The agent's `git commit` then asks for approval.
//

import Foundation

@MainActor
enum CommitChangesAction {
  static func title(fileCount: Int) -> String {
    fileCount == 1 ? "Commit 1 file…" : "Commit \(fileCount) files…"
  }

  static func prompt(fileCount: Int) -> String {
    let files = fileCount == 1 ? "the changed file" : "the \(fileCount) changed files"
    return
      "Commit \(files) in this worktree. Write the commit message from the session context. Do not push."
  }

  /// Sends the commit prompt to the session's terminal (or queues it when the
  /// terminal is not running yet), then focuses the terminal.
  static func perform(
    session: CLISession,
    terminalKey: String,
    fileCount: Int,
    viewModel: CLISessionsViewModel
  ) {
    let prompt = prompt(fileCount: fileCount)
    if !viewModel.sendPromptToActiveTerminal(forKey: terminalKey, prompt: prompt) {
      viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
    }
    viewModel.focusTerminal(forKey: terminalKey)
  }
}
