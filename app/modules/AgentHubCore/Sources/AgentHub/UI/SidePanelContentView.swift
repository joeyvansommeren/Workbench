//
//  SidePanelContentView.swift
//  AgentHub
//
//  The view for one `SidePanelContent` case: diff, plan, preview, GitHub,
//  edits, MCP apps, simulator, measurements, artifact or Studio. Moved out of
//  `MultiProviderMonitoringPanelView.sidePanelView(for:)` so the legacy panel
//  and the new shell's `SessionSidePanel` host the same panels.
//

import AgentHubGitHub
import SwiftUI

struct SidePanelContentView: View {
  let content: SidePanelContent
  let providerKind: SessionProviderKind
  let viewModel: CLISessionsViewModel
  let onDismiss: () -> Void
  /// Shows the session's terminal and sends it a prompt (diff and plan feedback).
  let onShowTerminalWithPrompt: (String, CLISession) -> Void
  /// The GitHub panel's pop-out button: the host presents it in a sheet.
  let onGitHubPopOut: (GitHubViewModel, CLISession, String, [GitHubPullRequestURLReference]) -> Void
  let isExpanded: Bool
  let onToggleExpanded: () -> Void
  let onCollapseExpandedAfterSend: () -> Void
  let openEditorFilePath: String?

  var body: some View {
    switch content {
    case .diff(_, let session, let projectPath):
      GitDiffView(
        session: session,
        projectPath: projectPath,
        onDismiss: onDismiss,
        cliConfiguration: viewModel.cliConfiguration(for: providerKind),
        providerKind: providerKind,
        onInlineRequestSubmit: { prompt, sess in
          onDismiss()
          onShowTerminalWithPrompt(prompt, sess)
        },
        isEmbedded: true
      )
    case .plan(_, let session, let planState):
      PlanView(
        session: session,
        planState: planState,
        onDismiss: onDismiss,
        isEmbedded: true,
        providerKind: providerKind,
        onSendFeedback: { feedback, sess in
          onDismiss()
          onShowTerminalWithPrompt(feedback, sess)
        }
      )
    case .webPreview(let sessionId, let session, let projectPath, let mode):
      WebPreviewView(
        session: session,
        projectPath: projectPath,
        onDismiss: onDismiss,
        isEmbedded: true,
        onInspectSubmit: { prompt, sess in
          if !viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) {
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          }
        },
        onQueuedSubmit: { prompt, sess in
          viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt)
        },
        viewModel: viewModel,
        providerKind: providerKind,
        mode: mode,
        agentLocalhostURL: viewModel.monitorStates[sessionId]?.detectedLocalhostURL,
        monitorState: viewModel.monitorStates[sessionId],
        isExpanded: isExpanded,
        onToggleExpanded: onToggleExpanded,
        onCollapseExpandedAfterSend: onCollapseExpandedAfterSend
      )
    case .mermaid(_, let session):
      MermaidDiagramView(
        session: session,
        onDismiss: onDismiss,
        isEmbedded: true
      )
    case .gitHub(_, let session, let projectPath, let linkedPullRequests):
      let gitHubViewModel = GitHubViewModel(
        service: viewModel.agentHubProvider?.gitHubService ?? GitHubCLIService(),
        observationService: viewModel.agentHubProvider?.gitHubPRObservationService
      )
      GitHubPanelView(
        projectPath: projectPath,
        branchName: session.branchName,
        linkedPullRequests: linkedPullRequests,
        onDismiss: onDismiss,
        isEmbedded: true,
        session: session,
        viewModel: gitHubViewModel,
        onSendToSession: { prompt, sess in
          viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
        },
        onPopOut: { panelViewModel in
          onGitHubPopOut(panelViewModel, session, projectPath, linkedPullRequests)
        }
      )
    case .edits(let sessionId, let session):
      if let pendingToolUse = viewModel.monitorStates[sessionId]?.pendingToolUse {
        PendingChangesView(
          session: session,
          pendingToolUse: pendingToolUse,
          onDismiss: onDismiss,
          isEmbedded: true,
          onApprovalResponse: { response, sess in
            viewModel.showTerminalWithPrompt(for: sess, prompt: response)
          }
        )
      } else {
        PendingChangesWaitingView(
          session: session,
          onDismiss: onDismiss
        )
      }
    case .mcpApp(let sessionId, let session, _):
      MCPAppSidePanelView(
        session: session,
        viewModel: viewModel,
        monitorState: viewModel.monitorStates[sessionId],
        onDismiss: onDismiss,
        isEmbedded: true,
        isExpanded: isExpanded,
        onToggleExpanded: onToggleExpanded
      )
    case .simulator(let sessionId, let session, let projectPath):
      SimulatorPreviewSidePanelView(
        session: session,
        projectPath: projectPath,
        providerKind: providerKind,
        onDismiss: onDismiss,
        onSendToSession: { prompt, sess in
          // Deliver the fix prompt to the running session terminal without
          // disturbing the user's current view: keep the simulator side panel
          // open and don't flip the card content mode (e.g. diffs/files) to
          // terminal. Stash a pending prompt only if no terminal is active yet.
          if !viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) {
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          }
        },
        openEditorFilePath: openEditorFilePath
      )
      .id("\(sessionId)|\(projectPath)")
    case .measurements(_, let session):
      MeasurementsSidePanelView(
        session: session,
        viewModel: viewModel,
        onDismiss: onDismiss,
        isEmbedded: true
      )
    case .claudeArtifact(let sessionId, _):
      ArtifactSidePanelView(
        artifacts: viewModel.monitorStates[sessionId]?.detectedArtifacts ?? [],
        onDismiss: onDismiss,
        isEmbedded: true,
        isExpanded: isExpanded,
        onToggleExpanded: onToggleExpanded
      )
    case .studio(_, let session):
      StudioSidePanelView(
        session: session,
        viewModel: viewModel,
        onDismiss: onDismiss,
        isEmbedded: true,
        isExpanded: isExpanded,
        onToggleExpanded: onToggleExpanded,
        onSendPrompt: { prompt, sess in
          if !viewModel.sendPromptToActiveTerminal(forKey: sess.id, prompt: prompt) {
            viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
          }
        }
      )
    }
  }
}
