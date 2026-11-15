//
//  CIFailureFixAction.swift
//  AgentHub
//
//  "Fix CI" from a CI-failure notification: builds the fix prompt from the
//  failed checks and sends it to the session's agent. Shared by the legacy
//  monitoring panel and the new shell.
//

import AgentHubGitHub
import Foundation

@MainActor
enum CIFailureFixAction {
  /// How long a notification action waits for its session to appear (the app
  /// may have been closed, or the session not loaded yet): 40 × 250 ms.
  static let waitAttempts = 40
  static let waitInterval: Duration = .milliseconds(250)

  /// Sends the fix prompt. The caller shows the terminal first.
  static func send(
    _ payload: GitHubCIFailureNotificationPayload,
    session: CLISession,
    viewModel: CLISessionsViewModel
  ) {
    guard let fixService = viewModel.agentHubProvider?.gitHubCIFixService else { return }
    Task {
      let prompt = await fixService.buildFixPrompt(
        projectPath: payload.projectPath,
        prNumber: payload.prNumber,
        prTitle: payload.prTitle,
        branchName: payload.branchName,
        failedChecks: payload.failedChecks.map {
          GitHubCIFixPromptBuilder.FailedCheck(
            name: $0.name,
            workflowName: $0.workflowName,
            detailsUrl: $0.detailsUrl
          )
        }
      )
      if !viewModel.sendPromptToActiveTerminal(forKey: session.id, prompt: prompt) {
        viewModel.showTerminalWithPrompt(for: session, prompt: prompt)
      }
      viewModel.focusTerminal(forKey: session.id)
    }
  }

  static func canFix(viewModel: CLISessionsViewModel) -> Bool {
    viewModel.agentHubProvider?.gitHubCIFixService != nil
  }
}
