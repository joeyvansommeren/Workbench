//
//  SprintDestinationView.swift
//  AgentHub
//
//  The new shell's Jira and Linear destinations (`SprintBoardView` in the
//  prototype): a list head (sprint name, All | Mine, Filters) and a board of
//  equal columns. Each tracker is its own tab. The legacy `JiraSprintView` and
//  `LinearBoardView` stay for the flag-off path.
//

import AgentWorkflowJiraCLI
import SwiftUI

/// What both tracker destinations read from the provider.
@MainActor
private struct TrackerDestinationContext {
  let agentHub: AgentHubProvider

  var repositories: [SelectedRepository] {
    ShellSessionItems.repositories(
      claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel
    )
  }

  func sessionStatus(_ provider: SessionProviderKind, _ sessionID: String) -> SessionStatus? {
    let viewModel =
      provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
    return viewModel.sessionStatus(for: sessionID)
  }
}

struct JiraDestinationView: View {
  let agentHub: AgentHubProvider
  let actions: WorkspaceLaunchActions

  var body: some View {
    let context = TrackerDestinationContext(agentHub: agentHub)
    JiraSprintDestination(
      viewModel: agentHub.jiraSprintViewModel,
      repositories: context.repositories,
      linkedSessions: agentHub.jiraLinkedSessions(),
      isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
      isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
      sessionStatus: context.sessionStatus,
      onStart: { ticket, provider, repositoryPath in
        await actions.startJiraTicket(ticket, provider: provider, repositoryPath: repositoryPath)
      },
      onOpenSession: { agentHub.showSession($0) }
    )
  }
}

struct LinearDestinationView: View {
  let agentHub: AgentHubProvider
  let actions: WorkspaceLaunchActions

  var body: some View {
    let context = TrackerDestinationContext(agentHub: agentHub)
    LinearSprintDestination(
      viewModel: agentHub.linearViewModel,
      repositories: context.repositories,
      linkedSessions: agentHub.linearLinkedSessions(),
      isClaudeAvailable: agentHub.claudeSessionsViewModel.isCLIAvailable,
      isCodexAvailable: agentHub.codexSessionsViewModel.isCLIAvailable,
      sessionStatus: context.sessionStatus,
      onStart: { issue, provider, repositoryPath in
        await actions.startLinearIssue(issue, provider: provider, repositoryPath: repositoryPath)
      },
      onOpenSession: { agentHub.showLinearSession($0) }
    )
  }
}

// MARK: - Jira

struct JiraSprintDestination: View {
  @Bindable var viewModel: JiraSprintViewModel
  let repositories: [SelectedRepository]
  let linkedSessions: [String: [JiraLinkedSession]]
  let isClaudeAvailable: Bool
  let isCodexAvailable: Bool
  let sessionStatus: (SessionProviderKind, String) -> SessionStatus?
  let onStart: (JiraTicketSnapshot, SessionProviderKind, String) async -> Void
  let onOpenSession: (JiraLinkedSession) -> Void

  @State private var isFiltersOpen = false
  @FocusState private var isBoardFocused: Bool

  var body: some View {
    SprintDestinationLayout(isDetailVisible: viewModel.selectedTicketKey != nil) {
      SprintListHead(title: listHeadTitle, scope: scope) {
        if !isFailed {
          refreshButton
          filtersButton
        }
      }
    } content: {
      VStack(spacing: 0) {
        if let notice = viewModel.statusNotice {
          SprintNoticeView(
            text: notice.text, isError: notice.isError, onDismiss: viewModel.dismissStatusNotice)
        }
        content
      }
    } detail: {
      detail
    }
    .sheet(isPresented: isSyncPlanPresented) {
      JiraSyncPlanSheet(viewModel: viewModel)
    }
    .task {
      if viewModel.state == .idle { await viewModel.load() }
    }
    .onDisappear { viewModel.closeTicket() }
  }

  // MARK: Content

  private var isFailed: Bool {
    if case .failed = viewModel.state { return true }
    return false
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.state {
    case .failed(let message):
      JiraSprintFailureView(message: message, viewModel: viewModel)
    case .idle, .loading, .loaded:
      if viewModel.sprintTickets.isEmpty && viewModel.state != .loaded {
        SprintLoadingView()
      } else if viewModel.selectedSprint == nil {
        WBEmptyState(
          systemImage: "calendar",
          title: "No open sprint",
          description: "This board has no active or upcoming sprint. Pick another board in Filters."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        board
      }
    }
  }

  private var board: some View {
    SprintBoardView(
      columns: SprintBoardItems.jira(
        columns: viewModel.columns,
        linkedSessions: linkedSessions,
        pullRequests: viewModel.pullRequestsByTicket,
        status: sessionStatus
      ),
      selectedTicketID: viewModel.selectedTicketKey,
      actions: SprintBoardActions(
        onOpen: open,
        onStart: { start($0, provider: nil) },
        onOpenSession: { key in
          if let session = SprintBoardItems.sessionToOpen(linkedSessions[key] ?? []) {
            onOpenSession(session)
          }
        },
        onMove: { key, columnID in
          let category = viewModel.columns.first { $0.id == columnID }?.category
          Task { await viewModel.moveTicket(key, toStatus: columnID, category: category) }
        },
        browseURL: { key in
          viewModel.sprintTickets.first { $0.key == key }.flatMap(viewModel.browseURL(for:))
        }
      )
    )
    .focusable()
    .focused($isBoardFocused)
    .focusEffectDisabled()
    .onKeyPress(.upArrow) { move(.up) }
    .onKeyPress(.downArrow) { move(.down) }
    .onKeyPress(.leftArrow) { move(.left) }
    .onKeyPress(.rightArrow) { move(.right) }
    .onKeyPress(.escape) {
      guard viewModel.selectedTicketKey != nil else { return .ignored }
      close()
      return .handled
    }
    .overlay {
      if viewModel.filteredTickets.isEmpty {
        WBEmptyState(
          systemImage: "line.3.horizontal.decrease",
          title: "No matching tickets",
          description: "Switch to All or clear the filters."
        )
        .allowsHitTesting(false)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let ticket = viewModel.selectedTicket {
      JiraTicketDetailView(
        ticket: ticket,
        sprintName: viewModel.selectedSprint?.name,
        isLoadingDetail: viewModel.isLoadingDetail,
        browseURL: viewModel.browseURL(for: ticket),
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        linkedSessions: linkedSessions[ticket.key] ?? [],
        pullRequests: viewModel.pullRequestsByTicket[ticket.key],
        isLoadingPullRequests: viewModel.loadingPullRequestKeys.contains(ticket.key),
        onRefreshPullRequests: { viewModel.loadPullRequestsIfNeeded(for: ticket.key, force: true) },
        isStartingSession: viewModel.startingSessionKeys.contains(ticket.key),
        isClaudeAvailable: isClaudeAvailable,
        isCodexAvailable: isCodexAvailable,
        onStart: { provider in start(ticket.key, provider: provider) },
        onOpenSession: onOpenSession,
        onClose: close
      )
    }
  }

  // MARK: List head

  /// The sprint name and days left, once a sprint is loaded.
  private var listHeadTitle: SprintTitle? {
    viewModel.selectedSprint.map { SprintTitle.jira($0) }
  }

  private var scope: Binding<SprintAssigneeScope> {
    SprintAssigneeScope.binding(
      isMine: { viewModel.assigneeFilter == .me },
      setMine: { viewModel.assigneeFilter = $0 ? .me : .everyone }
    )
  }

  private var refreshButton: some View {
    IconButton(
      systemImage: "arrow.clockwise",
      accessibilityLabel: "Refresh sprint",
      accessibilityIdentifier: "sprint.refresh"
    ) {
      Task { await viewModel.load() }
    }
    .disabled(viewModel.state == .loading)
    .help("Refresh sprint  ⌘R")
    .keyboardShortcut("r", modifiers: .command)
  }

  private var activeFilterCount: Int {
    var count = viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1
    switch viewModel.assigneeFilter {
    case .person, .unassigned: count += 1
    case .everyone, .me: break
    }
    return count
  }

  private var filtersButton: some View {
    FiltersButton(
      activeCount: activeFilterCount,
      accessibilityIdentifier: "sprint.filters",
      onOpen: { isFiltersOpen = true },
      onClear: {
        viewModel.searchText = ""
        switch viewModel.assigneeFilter {
        case .person, .unassigned: viewModel.assigneeFilter = .everyone
        case .everyone, .me: break
        }
        MainThreadStallMonitor.breadcrumb("sprint filter: clear")
      }
    )
    .popover(isPresented: $isFiltersOpen, arrowEdge: .bottom) {
      JiraSprintFiltersPopover(
        viewModel: viewModel,
        onSync: {
          isFiltersOpen = false
          let openSessionKeys = Set(linkedSessions.filter { $0.value.contains { $0.isMonitored } }.keys)
          viewModel.startSync(openSessionKeys: openSessionKeys)
        }
      )
    }
  }

  // MARK: Actions

  private func open(_ key: String) {
    viewModel.openTicket(key)
    isBoardFocused = true
    MainThreadStallMonitor.breadcrumb("sprint ticket: open \(key)")
  }

  private func close() {
    viewModel.closeTicket()
    MainThreadStallMonitor.breadcrumb("sprint ticket: close")
  }

  private func move(_ direction: JiraSprintViewModel.MoveDirection) -> KeyPress.Result {
    viewModel.moveSelection(direction)
    if let key = viewModel.selectedTicketKey {
      MainThreadStallMonitor.breadcrumb("sprint ticket: open \(key)")
    }
    return .handled
  }

  /// Starts a session, or opens the detail when no project or agent is picked yet.
  private func start(_ key: String, provider: SessionProviderKind?) {
    guard
      let ticket = viewModel.selectedTicket?.key == key
        ? viewModel.selectedTicket : viewModel.sprintTickets.first(where: { $0.key == key }),
      let path = viewModel.repositoryPath,
      let provider = SprintStartProvider.resolve(
        provider, isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable)
    else {
      open(key)
      return
    }
    guard viewModel.beginStartingSession(for: key) else { return }
    MainThreadStallMonitor.breadcrumb("sprint ticket: start \(key)")
    Task {
      defer { viewModel.endStartingSession(for: key) }
      await onStart(ticket, provider, path)
    }
  }

  private var isSyncPlanPresented: Binding<Bool> {
    Binding(
      get: { viewModel.syncPlan != nil },
      set: { if !$0 { viewModel.cancelSync() } }
    )
  }
}

// MARK: - Filters popover

private struct JiraSprintFiltersPopover: View {
  @Bindable var viewModel: JiraSprintViewModel
  let onSync: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      WorkbenchField("Search tickets", text: $viewModel.searchText, systemImage: "magnifyingglass")
      if !viewModel.sprints.isEmpty {
        SprintFilterSection(title: "Sprint") {
          Picker("Sprint", selection: sprintSelection) {
            ForEach(viewModel.sprints) { sprint in
              Text(sprint.isActive ? "\(sprint.name) · active" : sprint.name).tag(sprint.id)
            }
          }
          .labelsHidden()
        }
      }
      if viewModel.boards.count > 1 {
        SprintFilterSection(title: "Board") {
          Picker("Board", selection: boardSelection) {
            ForEach(viewModel.boards) { board in
              Text(board.name).tag(board.id)
            }
          }
          .labelsHidden()
        }
      }
      SprintFilterSection(title: "Assignee") {
        Picker("Assignee", selection: assigneeSelection) {
          Text("Everyone").tag(JiraSprintViewModel.AssigneeFilter.everyone)
          Text("Mine").tag(JiraSprintViewModel.AssigneeFilter.me)
          ForEach(viewModel.assignees) { assignee in
            Text(assignee.name).tag(JiraSprintViewModel.AssigneeFilter.person(accountId: assignee.accountId))
          }
          if viewModel.unassignedCount > 0 {
            Text("Unassigned").tag(JiraSprintViewModel.AssigneeFilter.unassigned)
          }
        }
        .labelsHidden()
      }
      syncButton
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Width.popover)
  }

  @ViewBuilder
  private var syncButton: some View {
    if viewModel.isPlanningSync {
      Button("Cancel sync", action: viewModel.cancelSyncPlanning)
        .buttonStyle(.wbSecondary)
    } else {
      Button(action: onSync) {
        Label("Sync with pull requests", systemImage: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.wbSecondary)
      .disabled(viewModel.state != .loaded)
      .help(
        "Move the tickets you see to match their pull requests and open sessions. You review the changes before anything moves in Jira."
      )
    }
  }

  private var sprintSelection: Binding<Int> {
    Binding(
      get: { viewModel.selectedSprintID ?? -1 },
      set: { id in
        MainThreadStallMonitor.breadcrumb("sprint filter: sprint \(id)")
        Task { await viewModel.selectSprint(id) }
      }
    )
  }

  private var boardSelection: Binding<Int> {
    Binding(
      get: { viewModel.selectedBoardID ?? -1 },
      set: { id in
        MainThreadStallMonitor.breadcrumb("sprint filter: board \(id)")
        Task { await viewModel.selectBoard(id) }
      }
    )
  }

  private var assigneeSelection: Binding<JiraSprintViewModel.AssigneeFilter> {
    Binding(
      get: { viewModel.assigneeFilter },
      set: { filter in
        viewModel.assigneeFilter = filter
        MainThreadStallMonitor.breadcrumb("sprint filter: assignee")
      }
    )
  }
}

// MARK: - Failure

/// Missing acli: the install command. Other failures: the error and Connect.
private struct JiraSprintFailureView: View {
  let message: String
  @Bindable var viewModel: JiraSprintViewModel

  var body: some View {
    VStack(spacing: 0) {
      if !viewModel.isCLIMissing {
        ErrorBanner(message)
          .padding(.horizontal, DesignTokens.Spacing.lg)
      }
      Group {
        if viewModel.isCLIMissing {
          WBEmptyState(
            systemImage: "terminal",
            title: "Install the Atlassian CLI",
            description: "Sprint reads Jira through acli. Install it, then retry."
          ) {
            VStack(spacing: DesignTokens.Spacing.md) {
              CommandBlock(JiraCLIProcessRunner.installCommand)
                .frame(maxWidth: 760)
              retryButton
            }
          }
        } else {
          WBEmptyState(
            systemImage: "exclamationmark.triangle",
            isError: true,
            title: "Could not load Jira",
            description: "Connect your Atlassian account, then retry."
          ) {
            connectButton
            retryButton
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private var connectButton: some View {
    if viewModel.isConnecting {
      Button("Waiting for browser…") {}
        .buttonStyle(.wbPrimary)
        .disabled(true)
    } else {
      Button("Connect Jira") { Task { await viewModel.connect() } }
        .buttonStyle(.wbPrimary)
    }
  }

  private var retryButton: some View {
    Button("Retry") { Task { await viewModel.load() } }
      .buttonStyle(.wbSecondary)
  }
}
