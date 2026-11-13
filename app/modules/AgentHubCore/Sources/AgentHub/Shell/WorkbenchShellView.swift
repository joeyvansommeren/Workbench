//
//  WorkbenchShellView.swift
//  AgentHub
//
//  Root of the new (Apple prototype) window, shown when
//  `AgentHubDefaults.appleShellEnabled` is on at launch.
//
//  Three slots, each its own view so later phases replace only their slot:
//  - sidebar: `ShellSidebarContainer` (P5)
//  - toolbar: `ShellToolbar` (P6 tabs, P8/P9 titles)
//  - detail:  `ShellDetailSlot` (P6 Sessions, P8 Reviews, P9 Sprint)
//
//  Layout-loop rules (implementation plan, section 4): no split views, no
//  geometry-driven widths, only backgrounds ignore the top safe area, and the
//  sidebar collapses as a plain `HStack` child.
//

import SwiftUI

public struct WorkbenchShellView: View {
  @Environment(\.agentHub) private var agentHub

  public init() {}

  public var body: some View {
    if let agentHub {
      ShellRoot(agentHub: agentHub)
    } else {
      ContentUnavailableView("Workbench provider not found", systemImage: "exclamationmark.triangle")
    }
  }
}

/// Owns the per-window state: the shell model, plus the Sessions navigation
/// model and action coordinator (never provider singletons).
private struct ShellRoot: View {
  let agentHub: AgentHubProvider

  @State private var shellModel = WorkbenchShellModel()
  @State private var sessionNavigationModel = SessionNavigationModel()
  @State private var sessionsActionCoordinator = SessionsActionCoordinator()
  @State private var isResumingByID = false

  private var launchActions: WorkspaceLaunchActions {
    WorkspaceLaunchActions(agentHub: agentHub, showSessions: { shellModel.select(.sessions) })
  }

  private var sessionActions: ShellSessionActions {
    ShellSessionActions(
      agentHub: agentHub,
      coordinator: sessionsActionCoordinator,
      navigationModel: sessionNavigationModel
    )
  }

  var body: some View {
    ShellFrame(onNewSession: startNewSession)
      // Keyed on the palette revision; the per-window models above live
      // outside the keyed subtree, so a palette switch keeps them.
      .wbRedrawsOnPaletteChange()
      .frame(minWidth: ShellLayout.windowMinWidth, minHeight: ShellLayout.windowMinHeight)
      .environment(shellModel)
      .environment(\.sessionNavigationModel, sessionNavigationModel)
      .environment(\.sessionsActionCoordinator, sessionsActionCoordinator)
      .modifier(
        SessionsPresentationModifier(
          coordinator: sessionsActionCoordinator,
          claudeViewModel: agentHub.claudeSessionsViewModel,
          codexViewModel: agentHub.codexSessionsViewModel,
          workspaceViewModel: agentHub.agentWorkspacesViewModel,
          navigationModel: sessionNavigationModel,
          intelligenceViewModel: agentHub.intelligenceViewModel,
          contextProfileService: agentHub.contextProfileService
        )
      )
      .modifier(ShellRootEffects(agentHub: agentHub, launchActions: launchActions))
      .onChange(of: shellModel.destination) { oldDestination, _ in
        // Sessions left the tree: drop its sheets, alerts and scroll targets.
        guard oldDestination == .sessions else { return }
        sessionsActionCoordinator.clearTransientPresentation()
        sessionNavigationModel.clearTransientNavigation()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: AgentHubAppCommand.selectWorkspaceNotification)
      ) { notification in
        guard let section = AgentHubAppCommand.workspaceSection(from: notification) else { return }
        shellModel.select(legacySection: section)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: AgentHubAppCommand.resumeSessionByIDNotification)
      ) { _ in
        isResumingByID = true
      }
      .sheet(isPresented: $isResumingByID) {
        ResumeSessionByIDSheet(
          onResume: { id in await launchActions.resumeSession(id: id) },
          onDismiss: { isResumingByID = false }
        )
      }
      .focusedSceneValue(
        \.workbenchShell,
        ShellCommandTarget(model: shellModel, startNewSession: startNewSession)
      )
  }

  private func startNewSession() {
    shellModel.select(.sessions)
    sessionActions.startFocusedSession()
  }
}

/// Window-level work copied from `AgentHubOperationsView` (the legacy root
/// keeps its own copy): link resolved pending sessions to reviews and Jira,
/// load review associations, and watch for worktree launch requests.
private struct ShellRootEffects: ViewModifier {
  let agentHub: AgentHubProvider
  let launchActions: WorkspaceLaunchActions

  func body(content: Content) -> some View {
    content
      .onChange(of: agentHub.claudeSessionsViewModel.resolvedPendingSessionHistory) { _, resolutions in
        launchActions.handleResolvedPendingSessions(resolutions, provider: .claude)
      }
      .onChange(of: agentHub.codexSessionsViewModel.resolvedPendingSessionHistory) { _, resolutions in
        launchActions.handleResolvedPendingSessions(resolutions, provider: .codex)
      }
      .task { await agentHub.gitHubReviewsViewModel.loadSessionAssociations() }
      .task { agentHub.startWorktreeLaunchRequestMonitoring() }
  }
}

extension ShellFrame
where Sidebar == ShellSidebarContainer, Toolbar == ShellToolbar, Detail == ShellDetailSlot {
  /// The production frame with the three real slots.
  init(onNewSession: @escaping () -> Void) {
    self.init(
      sidebar: { ShellSidebarContainer() },
      toolbar: { ShellToolbar(onNewSession: onNewSession) },
      detail: { ShellDetailSlot() }
    )
  }
}

/// The window frame: `surfaceWindow` behind everything, the sidebar column,
/// and the main column (title row over the content panel). Generic over its
/// three slots so each phase swaps one slot and previews/tests can stub them.
struct ShellFrame<Sidebar: View, Toolbar: View, Detail: View>: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @ViewBuilder let sidebar: Sidebar
  @ViewBuilder let toolbar: Toolbar
  @ViewBuilder let detail: Detail

  var body: some View {
    HStack(spacing: 0) {
      if shellModel.sidebarVisible {
        sidebar
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      VStack(spacing: 0) {
        toolbar
        ContentPanel(isSidebarVisible: shellModel.sidebarVisible) {
          VStack(spacing: 0) {
            NodeProcessGuardNotice()
            detail
          }
        }
      }
    }
    .overlay(alignment: .topLeading) {
      ShellWindowControls()
    }
    .animation(.wbAnimation(DesignTokens.Motion.medium), value: shellModel.sidebarVisible)
    .background(Color.wbSurfaceWindow.ignoresSafeArea())
  }
}
