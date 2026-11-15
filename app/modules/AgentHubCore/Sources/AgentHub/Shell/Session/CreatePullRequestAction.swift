//
//  CreatePullRequestAction.swift
//  AgentHub
//
//  "Create PR": asks the agent to open a pull request for the current
//  branch. Shared by the legacy `MonitoringCardView` and the new shell.
//

import Foundation

@MainActor
enum CreatePullRequestAction {
  static let prompt =
    "Make a PR for the current branch. Include the local changes in this worktree and use the session context for the title, body, and validation notes."

  /// Sends the prompt to the session's terminal (or queues it), focuses the
  /// terminal, and keeps the action disabled for two seconds so a double
  /// click sends one prompt.
  static func perform(
    session: CLISession,
    terminalKey: String,
    viewModel: CLISessionsViewModel,
    showTerminal: () -> Void
  ) {
    guard viewModel.beginCreatingPullRequest(for: session.id) else { return }
    showTerminal()
    if !viewModel.sendPromptToActiveTerminal(forKey: terminalKey, prompt: prompt) {
      viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
    }
    viewModel.focusTerminal(forKey: terminalKey)
    // Clear after a short cooldown — the prompt has been sent synchronously, but
    // keep the button disabled long enough to prevent an accidental double click.
    Task {
      try? await Task.sleep(for: .seconds(2))
      viewModel.endCreatingPullRequest(for: session.id)
    }
  }
}
