//
//  AgentHubViews.swift
//  AgentHub
//
//  Pre-configured view components for AgentHub
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import SwiftUI

// MARK: - RemoveTitleToolbarModifier

/// A view modifier that removes the toolbar title on macOS 15+
private struct RemoveTitleToolbarModifier: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}

// MARK: - AgentHubOperationsView

/// The application-level workspace for structured ticket workflows and raw sessions.
public struct AgentHubOperationsView: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var section = AgentHubWorkspaceSection.workflows
  @State private var isResumingByID = false
  @State private var sessionNavigationModel = SessionNavigationModel()
  @State private var sessionsActionCoordinator = SessionsActionCoordinator()

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: DesignTokens.Spacing.md) {
        WorkspaceSwitcherBar(selection: $section)
          .fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: DesignTokens.Spacing.sm)
        if section == .workflows {
          // Longest label that fits; narrow windows get the short form.
          ViewThatFits(in: .horizontal) {
            StateChip(text: "Approval required before commit, push, or PR", systemImage: "hand.raised.fill")
            StateChip(text: "Approval required", systemImage: "hand.raised.fill")
          }
          .help("Workflow policy: a human approves every commit, push, and pull request")
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: AgentHubLayout.topBarHeight)
      .background(
        Color.themedPanelBackground(for: colorScheme, theme: runtimeTheme)
      )

      Divider()
      NodeProcessGuardNotice()

      Group {
        switch section {
        case .workflows:
          if let agentHub {
            AgentWorkflowDashboardView(
              viewModel: agentHub.workflowDashboardViewModel,
              onOpenSession: { assignment in
                agentHub.globalSessionSelectionRouter.select(
                  providerKind: assignment.provider,
                  sessionId: assignment.session.id,
                  projectPath: assignment.session.projectPath,
                  session: assignment.session
                )
                section = .sessions
              },
              onCloseSession: { assignment in
                let sessionsViewModel =
                  assignment.provider == .claude
                  ? agentHub.claudeSessionsViewModel
                  : agentHub.codexSessionsViewModel
                sessionsViewModel.stopMonitoring(session: assignment.session)
              },
              onStartSession: { workflowID, provider, initialPrompt in
                startSession(
                  in: workflowID,
                  provider: provider,
                  initialPrompt: initialPrompt,
                  agentHub: agentHub
                )
              },
              onCompareSessions: { request in
                agentHub.openWorkflowSessionComparison(request)
                section = .sessions
              },
              isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
              isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable
            )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .reviews:
          if let agentHub {
            GitHubReviewsView(
              viewModel: agentHub.gitHubReviewsViewModel,
              claudeSessionsViewModel: agentHub.claudeSessionsViewModel,
              codexSessionsViewModel: agentHub.codexSessionsViewModel,
              onReview: { pullRequest, provider, template in
                await launchActions(agentHub).startReview(
                  pullRequest,
                  provider: provider,
                  template: template
                )
              },
              onOpenSession: { link in
                launchActions(agentHub).openReviewSession(link)
              }
            )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .sprint:
          if let agentHub {
            JiraSprintView(
                viewModel: agentHub.jiraSprintViewModel,
                repositories: WorktreeModuleResolver.mergedRepositories(
                  agentHub.claudeSessionsViewModel.selectedRepositories
                    + agentHub.codexSessionsViewModel.selectedRepositories
                ),
                linkedSessions: agentHub.jiraLinkedSessions(),
                isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
                isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
                onStart: { ticket, provider, repositoryPath in
                  await launchActions(agentHub).startJiraTicket(
                    ticket,
                    provider: provider,
                    repositoryPath: repositoryPath
                  )
                },
                onOpenSession: { agentHub.showSession($0) }
              )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .linear:
          if let agentHub {
            LinearBoardView(
              viewModel: agentHub.linearViewModel,
              repositories: WorktreeModuleResolver.mergedRepositories(
                agentHub.claudeSessionsViewModel.selectedRepositories
                  + agentHub.codexSessionsViewModel.selectedRepositories
              ),
              linkedSessions: agentHub.linearLinkedSessions(),
              isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
              isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
              onStart: { issue, provider, repositoryPath in
                await launchActions(agentHub).startLinearIssue(
                  issue,
                  provider: provider,
                  repositoryPath: repositoryPath
                )
              },
              onOpenSession: { agentHub.showLinearSession($0) }
            )
          } else {
            ContentUnavailableView(
              "AgentHub provider not found",
              systemImage: "exclamationmark.triangle"
            )
          }
        case .sessions:
          AgentHubSessionsView()
        }
      }
    }
    .frame(
      minWidth: AgentHubLayout.windowMinWidth,
      maxWidth: .infinity,
      minHeight: AgentHubLayout.windowMinHeight,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .background(
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
        .ignoresSafeArea()
    )
    .onChange(of: section) { _, newSection in
      MainThreadStallMonitor.breadcrumb("tab: \(newSection.rawValue)")
    }
    .onChange(
      of: agentHub?.claudeSessionsViewModel.resolvedPendingSessionHistory ?? [:]
    ) { _, resolutions in
      guard let agentHub else { return }
      launchActions(agentHub).handleResolvedPendingSessions(resolutions, provider: .claude)
    }
    .onChange(
      of: agentHub?.codexSessionsViewModel.resolvedPendingSessionHistory ?? [:]
    ) { _, resolutions in
      guard let agentHub else { return }
      launchActions(agentHub).handleResolvedPendingSessions(resolutions, provider: .codex)
    }
    .task {
      guard let agentHub else { return }
      await agentHub.gitHubReviewsViewModel.loadSessionAssociations()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AgentHubAppCommand.resumeSessionByIDNotification)
    ) { _ in
      isResumingByID = true
    }
    .sheet(isPresented: $isResumingByID) {
      if let agentHub {
        ResumeSessionByIDSheet(
          onResume: { id in await launchActions(agentHub).resumeSession(id: id) },
          onDismiss: { isResumingByID = false }
        )
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: AgentHubAppCommand.selectWorkspaceNotification)
    ) { notification in
      guard let requestedSection = AgentHubAppCommand.workspaceSection(from: notification) else {
        return
      }
      section = requestedSection
    }
    .modifier(RemoveTitleToolbarModifier())
    .environment(\.sessionNavigationModel, sessionNavigationModel)
    .environment(\.sessionsActionCoordinator, sessionsActionCoordinator)
  }

  private func startSession(
    in workflowID: String,
    provider: SessionProviderKind,
    initialPrompt: String?,
    agentHub: AgentHubProvider
  ) {
    guard
      let workflow = agentHub.workflowDashboardViewModel.prepareManualSessionLaunch(
        workflowID: workflowID,
        provider: provider
      )
    else {
      return
    }

    let sessionsViewModel =
      provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(workflow.repositoryPath)
    let existingWorktree = sessionsViewModel.selectedRepositories
      .flatMap(\.worktrees)
      .first {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == normalizedPath
      }
    let launchTarget =
      existingWorktree
      ?? WorktreeBranch(
        name: workflow.branchName
          ?? URL(fileURLWithPath: normalizedPath).lastPathComponent,
        path: normalizedPath,
        isWorktree: workflow.branchName != nil
      )

    sessionsViewModel.addRepository(at: normalizedPath)
    let trimmedPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    sessionsViewModel.startNewSessionInHub(
      launchTarget,
      initialPrompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : "Work on \(workflow.name)."
    )
    if let pendingSessionID = sessionsViewModel.lastCreatedPendingId {
      agentHub.workflowDashboardViewModel.associateManualSessionLaunch(
        workflowID: workflowID,
        provider: provider,
        pendingSessionID: pendingSessionID
      )
    }
    section = .sessions
  }

  private func launchActions(_ agentHub: AgentHubProvider) -> WorkspaceLaunchActions {
    WorkspaceLaunchActions(agentHub: agentHub, showSessions: { section = .sessions })
  }
}

// MARK: - AgentHubSessionsView

/// Pre-configured sessions view that reads from the environment
///
/// This view automatically gets its dependencies from the AgentHub provider
/// in the environment. Make sure to apply `.agentHub()` modifier to a parent view.
///
/// ## Example
/// ```swift
/// WindowGroup {
///   AgentHubSessionsView()
///     .agentHub(provider)
/// }
/// ```
public struct AgentHubSessionsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      sessionsListView(provider: provider)
    } else {
      missingProviderView
    }
  }

  @ViewBuilder
  private func sessionsListView(provider: AgentHubProvider) -> some View {
    MultiProviderSessionsListView(
      claudeViewModel: provider.claudeSessionsViewModel,
      codexViewModel: provider.codexSessionsViewModel,
      workspaceViewModel: provider.agentWorkspacesViewModel,
      columnVisibility: $columnVisibility,
      intelligenceViewModel: provider.intelligenceViewModel,
      worktreeBranchNamingService: provider.worktreeBranchNamingService,
      worktreeSuccessSoundService: provider.worktreeSuccessSoundService
    )
    .frame(minWidth: AgentHubLayout.windowMinWidth)
    .modifier(RemoveTitleToolbarModifier())
    .onChange(of: columnVisibility) { _, visibility in
      MainThreadStallMonitor.breadcrumb("sessions sidebar: \(visibility == .detailOnly ? "hidden" : "shown")")
    }
    .task {
      provider.startWorktreeLaunchRequestMonitoring()
    }
  }

  private var missingProviderView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Workbench provider not found")
        .font(.geist(size: 13, weight: .bold))
      Text("Add .agentHub() modifier to a parent view")
        .font(.geist(size: 10))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - AgentHubMenuBarContent

/// Pre-configured menu bar content for MenuBarExtra
///
/// Use this as the content of a MenuBarExtra to show global stats.
///
/// ## Example
/// ```swift
/// MenuBarExtra("Stats", systemImage: "sparkle") {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// }
/// ```
public struct AgentHubMenuBarContent: View {
  @Environment(\.agentHub) private var agentHub

  public init() {}

  public var body: some View {
    if let provider = agentHub {
      GlobalStatsMenuView(
        claudeService: provider.statsService,
        codexService: provider.codexStatsService,
        sessionsViewModel: provider.sessionsViewModel
      )
    } else {
      Text("Workbench provider not found")
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - AgentHubMenuBarLabel

/// Pre-configured label for MenuBarExtra
///
/// Shows an icon with token count in the menu bar.
///
/// ## Example
/// ```swift
/// @State private var provider = AgentHubProvider()
///
/// MenuBarExtra {
///   AgentHubMenuBarContent()
///     .environment(\.agentHub, provider)
/// } label: {
///   AgentHubMenuBarLabel(provider: provider)
/// }
/// ```
public struct AgentHubMenuBarLabel: View {
  let provider: AgentHubProvider

  public init(provider: AgentHubProvider) {
    self.provider = provider
  }

  public var body: some View {
    Image("AgentHubMenuBarIcon", bundle: .main)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: 18, height: 18)
  }
}

// MARK: - WorkspaceSwitcherBar

/// Owns the live counts so only this bar re-renders when sessions change, not
/// the whole workspace (its body reads session state that updates constantly).
private struct WorkspaceSwitcherBar: View {
  @Binding var selection: AgentHubWorkspaceSection
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    WorkspaceSwitcher(selection: $selection, items: items)
  }

  private var items: [WorkspaceSwitcherItem] {
    let activeSessions = agentHub.map {
      $0.claudeSessionsViewModel.monitoredSessionIds.count
        + $0.codexSessionsViewModel.monitoredSessionIds.count
    }
    return [
      WorkspaceSwitcherItem(
        section: .workflows, systemImage: "point.3.connected.trianglepath.dotted", shortcut: "1",
        count: nil),
      WorkspaceSwitcherItem(
        section: .reviews, systemImage: "arrow.triangle.pull", shortcut: "2",
        count: agentHub?.gitHubReviewsViewModel.pullRequests.count),
      WorkspaceSwitcherItem(
        section: .sessions, systemImage: "terminal", shortcut: "3", count: activeSessions),
      WorkspaceSwitcherItem(
        section: .sprint, systemImage: "rectangle.split.3x1", shortcut: "4",
        count: agentHub?.jiraSprintViewModel.myOpenTicketCount),
      WorkspaceSwitcherItem(
        section: .linear, systemImage: "line.3.horizontal", shortcut: "5",
        count: agentHub?.linearViewModel.myOpenIssueCount),
    ]
  }
}

// MARK: - ResumeSessionByIDSheet

/// Paste a session id (or a `claude --resume …` / `codex resume …` command).
struct ResumeSessionByIDSheet: View {
  let onResume: (String) async -> Bool
  let onDismiss: () -> Void

  @State private var text = ""
  @State private var isSearching = false
  @State private var notFound = false
  @FocusState private var isFocused: Bool

  private var sessionID: String? { CLISessionsViewModel.extractSessionID(from: text) }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Resume a session")
          .font(.geist(size: 15, weight: .semibold))
        Text("Paste a Claude or Codex session ID. A full resume command works too.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }
      TextField("Session ID", text: $text)
        .textFieldStyle(.roundedBorder)
        .font(.mono(size: 12))
        .focused($isFocused)
        .onSubmit(resume)
        .onChange(of: text) { _, _ in notFound = false }
      if notFound {
        Label("No Claude or Codex session found with this ID.", systemImage: "questionmark.circle")
          .font(.secondarySmall)
          .foregroundStyle(.orange)
      } else if !text.isEmpty, sessionID == nil {
        Text("That doesn't look like a session ID.")
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onDismiss)
          .keyboardShortcut(.cancelAction)
        Button(action: resume) {
          if isSearching { ProgressView().controlSize(.small) } else { Text("Resume") }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(sessionID == nil || isSearching)
      }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 460)
    .onAppear { isFocused = true }
  }

  private func resume() {
    guard let sessionID, !isSearching else { return }
    isSearching = true
    Task {
      let found = await onResume(sessionID)
      isSearching = false
      if found { onDismiss() } else { notFound = true }
    }
  }
}
