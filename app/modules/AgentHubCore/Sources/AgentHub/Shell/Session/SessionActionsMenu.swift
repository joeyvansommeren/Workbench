//
//  SessionActionsMenu.swift
//  AgentHub
//
//  The session header's "…" menu: the legacy card's actions popover (copy ID,
//  transcript, open in Terminal, refresh, name, fork, add files) and, below
//  them, the resource links (`ResourceLinksPanel`: links, current PR, local
//  changes, Create PR).
//

import AgentHubGitHub
import SwiftUI

struct SessionActionsMenu: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let isPending: Bool
  let viewModel: CLISessionsViewModel
  let quickAccessViewModel: SessionGitHubQuickAccessViewModel
  let onDismiss: () -> Void
  let onViewTranscript: () -> Void
  let onRename: () -> Void
  let onAddFiles: () -> Void
  let onFork: () -> Void
  let onCreatePullRequest: () -> Void

  var body: some View {
    MenuSurface(width: DesignTokens.Width.popover + 60) {
      VStack(alignment: .leading, spacing: 0) {
        if !isPending {
          row("Copy Session ID", systemImage: "doc.on.doc") { viewModel.copySessionId(session) }
          row("View Transcript", systemImage: "doc.text", action: onViewTranscript)
          if providerKind == .claude {
            row("Open in Terminal", systemImage: "rectangle.portrait.and.arrow.right") {
              _ = viewModel.connectToSession(session)
            }
          }
          row("Refresh Terminal", systemImage: "arrow.clockwise") {
            viewModel.refreshTerminal(forKey: session.id, sessionId: session.id, projectPath: session.projectPath)
          }
          row("Name Session…", systemImage: "pencil", action: onRename)
          row("Fork…", systemImage: "arrow.triangle.branch", action: onFork)
          divider
        }
        row("Add Files…", systemImage: "plus.rectangle.on.folder", action: onAddFiles)
        if !isPending {
          ResourceLinksPanel(
            links: state?.detectedResourceLinks ?? [],
            providerKind: providerKind,
            currentPullRequest: quickAccessViewModel.currentBranchPR,
            localDiffSummary: viewModel.localDiffSummary(for: session.projectPath),
            isCreatingPullRequest: viewModel.creatingPullRequestSessionIDs.contains(session.id),
            onCreatePullRequest: {
              onDismiss()
              onCreatePullRequest()
            }
          ) {
            EmptyView()
          }
          .padding(.top, DesignTokens.Spacing.xs)
        }
      }
    }
  }

  private var state: SessionMonitorState? { viewModel.monitorStates[session.id] }

  private var divider: some View {
    Rectangle()
      .fill(Color.wbBorderHairline)
      .frame(height: 1)
      .padding(.vertical, DesignTokens.Spacing.xs)
  }

  /// A menu row. Closes the popover first; sheets open after it is gone.
  private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    MenuRow(title: title, systemImage: systemImage) {
      onDismiss()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: action)
    }
  }
}

private struct MenuRow: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: systemImage)
          .font(.system(size: 12))
          .frame(width: 16)
          .foregroundStyle(Color.wbTextSecondary)
        Text(title)
          .wbText(.body)
          .foregroundStyle(Color.wbTextPrimary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .frame(height: DesignTokens.Size.row - 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isHovered ? Color.wbSurfaceHover : Color.clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item)
    )
    .onHover { isHovered = $0 }
  }
}
