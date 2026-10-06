//
//  AgentHubViews.swift
//  AgentHub
//
//  Pre-configured view components for AgentHub
//

import AgentHubGitHub
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

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Workspace", selection: $section) {
          ForEach(AgentHubWorkspaceSection.allCases) { section in
            Text(section.rawValue).tag(section)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320)
        .tint(Color.brandPrimary(from: runtimeTheme))
        .accessibilityLabel("AgentHub workspace")

        Spacer()

        if section == .workflows {
          Label(
            "Workflow policy: approval before commit, push, or pull request",
            systemImage: "hand.raised"
          )
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .frame(height: AgentHubLayout.topBarHeight)
      .background(
        Color.themedPanelBackground(for: colorScheme, theme: runtimeTheme)
      )

      Divider()

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
              }
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
                await startReview(
                  pullRequest,
                  provider: provider,
                  template: template,
                  agentHub: agentHub
                )
              },
              onOpenSession: { link in
                openReviewSession(link, agentHub: agentHub)
              }
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
      minWidth: 1200,
      maxWidth: .infinity,
      minHeight: 750,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .background(
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
        .ignoresSafeArea()
    )
    .onChange(
      of: agentHub?.claudeSessionsViewModel.resolvedPendingSessionHistory ?? [:]
    ) { _, resolutions in
      guard let agentHub else { return }
      Task {
        await agentHub.gitHubReviewsViewModel.resolveReviewLaunches(
          resolutions,
          provider: .claude
        )
        applyReviewSessionTitles(provider: .claude, agentHub: agentHub)
      }
    }
    .onChange(
      of: agentHub?.codexSessionsViewModel.resolvedPendingSessionHistory ?? [:]
    ) { _, resolutions in
      guard let agentHub else { return }
      Task {
        await agentHub.gitHubReviewsViewModel.resolveReviewLaunches(
          resolutions,
          provider: .codex
        )
        applyReviewSessionTitles(provider: .codex, agentHub: agentHub)
      }
    }
    .task {
      guard let agentHub else { return }
      await agentHub.gitHubReviewsViewModel.loadSessionAssociations()
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

  private func startReview(
    _ pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    template: GitHubPromptTemplate,
    agentHub: AgentHubProvider
  ) async {
    guard let project = agentHub.gitHubReviewsViewModel.selectedProject,
      let view = agentHub.gitHubReviewsViewModel.selectedView
    else { return }

    let repositories = WorktreeModuleResolver.mergedRepositories(
      agentHub.claudeSessionsViewModel.selectedRepositories
        + agentHub.codexSessionsViewModel.selectedRepositories
    )
    guard
      let repositoryPath = localRepositoryPath(
        named: pullRequest.repositoryName,
        repositories: repositories
      )
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "No local checkout found for \(pullRequest.repositoryNameWithOwner). Add that repository in Sessions first."
      )
      return
    }

    let sessionsViewModel =
      provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(repositoryPath)
    let target = WorktreeBranch(
      name: pullRequest.title,
      path: normalizedPath,
      isWorktree: false,
      isExpanded: true
    )
    let prompt = GitHubPromptLibrary.shared.renderedPrompt(
      template: template,
      context: GitHubPromptContext(
        pullRequest: pullRequest,
        project: project,
        view: view,
        provider: provider
      )
    )

    sessionsViewModel.addRepository(at: normalizedPath)
    guard
      let pendingID = sessionsViewModel.startAutomatedSessionInHub(
        target,
        initialPrompt: prompt
      )
    else {
      agentHub.gitHubReviewsViewModel.presentLaunchError(
        "Could not start the \(provider.rawValue) pull request session."
      )
      return
    }
    await agentHub.gitHubReviewsViewModel.registerReviewLaunch(
      for: pullRequest,
      provider: provider,
      pendingID: pendingID,
      projectPath: normalizedPath
    )
    await agentHub.gitHubReviewsViewModel.resolveReviewLaunches(
      sessionsViewModel.resolvedPendingSessionHistory,
      provider: provider
    )
    applyReviewSessionTitles(provider: provider, agentHub: agentHub)
  }

  private func applyReviewSessionTitles(
    provider: SessionProviderKind,
    agentHub: AgentHubProvider
  ) {
    let sessionsViewModel =
      provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    for (sessionID, title) in agentHub.gitHubReviewsViewModel.linkedSessionTitles(
      provider: provider
    ) {
      sessionsViewModel.setCustomName(title, forSessionId: sessionID)
    }
  }

  private func openReviewSession(
    _ link: GitHubReviewSessionLink,
    agentHub: AgentHubProvider
  ) {
    let sessionsViewModel =
      link.provider == .claude
      ? agentHub.claudeSessionsViewModel
      : agentHub.codexSessionsViewModel
    if !link.isPending, !sessionsViewModel.isMonitoring(sessionId: link.session.id) {
      sessionsViewModel.startMonitoring(session: link.session)
    }
    agentHub.globalSessionSelectionRouter.select(
      providerKind: link.provider,
      sessionId: link.session.id,
      projectPath: link.session.projectPath,
      itemId: link.itemID,
      session: link.isPending ? nil : link.session
    )
    section = .sessions
  }

  private func localRepositoryPath(
    named repositoryName: String,
    repositories: [SelectedRepository]
  ) -> String? {
    if let repository = repositories.first(where: {
      $0.name.localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
        || URL(fileURLWithPath: $0.path).lastPathComponent
          .localizedCaseInsensitiveCompare(repositoryName) == .orderedSame
    }) {
      return repository.path
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/LocalDocuments/Github/\(repositoryName)",
      "\(home)/Documents/GitHub/\(repositoryName)",
      "\(home)/Developer/\(repositoryName)",
      "\(home)/Projects/\(repositoryName)",
    ]
    return candidates.first { candidate in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
        && isDirectory.boolValue
        && FileManager.default.fileExists(atPath: "\(candidate)/.git")
    }
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
    .frame(minWidth: 1200, minHeight: 750)
    .modifier(RemoveTitleToolbarModifier())
    .task {
      provider.startWorktreeLaunchRequestMonitoring()
    }
  }

  private var missingProviderView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("AgentHub provider not found")
        .font(.headline)
      Text("Add .agentHub() modifier to a parent view")
        .font(.caption)
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
      Text("AgentHub provider not found")
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
