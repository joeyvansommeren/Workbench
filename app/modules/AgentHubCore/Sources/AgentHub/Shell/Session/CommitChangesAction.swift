//
//  CommitChangesAction.swift
//  AgentHub
//
//  "Commit N files…" in the session side panel. Workbench never commits by
//  itself: it asks the agent to commit, the same way "Create PR" asks it to
//  open a pull request. The agent's `git commit` then asks for approval.
//

import Foundation

/// A per-session "one at a time" guard with a short cooldown, so a double
/// click sends one prompt.
@MainActor
final class SessionActionCooldown {
  private var activeSessionIDs: Set<String> = []

  /// False while the session's action is still cooling down.
  func begin(_ sessionID: String) -> Bool {
    activeSessionIDs.insert(sessionID).inserted
  }

  func end(_ sessionID: String) {
    activeSessionIDs.remove(sessionID)
  }

  func isActive(_ sessionID: String) -> Bool {
    activeSessionIDs.contains(sessionID)
  }
}

@MainActor
enum CommitChangesAction {
  static let cooldown = SessionActionCooldown()
  static let cooldownDuration: Duration = .seconds(2)

  static func title(fileCount: Int) -> String {
    fileCount == 1 ? "Commit 1 file…" : "Commit \(fileCount) files…"
  }

  static func prompt(fileCount: Int) -> String {
    let files = fileCount == 1 ? "the changed file" : "the \(fileCount) changed files"
    return
      "Commit \(files) in this worktree. Write the commit message from the session context. Do not push."
  }

  /// Sends the commit prompt to the session's terminal (or queues it when the
  /// terminal is not running yet), then focuses the terminal. Does nothing
  /// while the previous commit request for this session cools down.
  static func perform(
    session: CLISession,
    terminalKey: String,
    fileCount: Int,
    viewModel: CLISessionsViewModel,
    showTerminal: () -> Void
  ) {
    guard cooldown.begin(session.id) else { return }
    showTerminal()
    let prompt = prompt(fileCount: fileCount)
    if !viewModel.sendPromptToActiveTerminal(forKey: terminalKey, prompt: prompt) {
      viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
    }
    viewModel.focusTerminal(forKey: terminalKey)
    Task {
      try? await Task.sleep(for: cooldownDuration)
      cooldown.end(session.id)
    }
  }
}
