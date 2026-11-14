//
//  SprintDestinationView.swift
//  AgentHub
//
//  The new shell's Jira and Linear destinations (`SprintBoardView` in the
//  prototype): a list head (sprint name, All | Mine, people (Jira), Filters) and a board of
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
      SprintListHead(title: listHeadTitle, scope: scope) { limit in
        if !isFailed {
          peopleStrip(visibleLimit: limit)
        }
      } trailing: {
        if !isFailed {
          refreshButton
          filtersButton
        }
      }
    } content: {
      VStack(spacing: 0) {
        if let refreshError = viewModel.refreshError {
          SprintNoticeView(
            text: refreshError, isError: true,
            onRetry: { Task { await viewModel.load(keepsBoardOnFailure: true) } },
            onDismiss: viewModel.dismissRefreshError)
        }
        if let notice = viewModel.statusNotice {
          SprintNoticeView(
            text: notice.text, isError: notice.isError, onRetry: nil,
            onDismiss: viewModel.dismissStatusNotice)
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
      if viewModel.state == .idle { await viewModel.load(keepsBoardOnFailure: true) }
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
        WBLoadingState("Loading sprint")
      } else if viewModel.selectedSprint == nil {
        WBEmptyState(
          systemImage: "calendar",
          title: "No open sprint",
          // The board picker only shows when there is another board to pick.
          description: viewModel.boards.count > 1
            ? "This board has no active or upcoming sprint. Pick another board in Filters."
            : "This board has no active or upcoming sprint."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.sprintTickets.isEmpty {
        WBEmptyState(systemImage: "tray", title: "No tickets in this sprint")
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
        startingKeys: viewModel.startingSessionKeys,
        status: sessionStatus
      ),
      selectedTicketID: viewModel.selectedTicketKey,
      isFocused: isBoardFocused,
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
    .onKeyPress(.return) { startSelected() }
    .onKeyPress(.escape) {
      guard viewModel.selectedTicketKey != nil else { return .ignored }
      close()
      return .handled
    }
    .overlay {
      if viewModel.filteredTickets.isEmpty {
        SprintNoMatchesView(
          title: "No matching tickets",
          onClearFilters: activeFilterCount > 0 ? clearFilters : nil,
          onShowAll: viewModel.assigneeFilter == .everyone ? nil : { viewModel.assigneeFilter = .everyone })
      }
    }
  }

  /// Return on the board: open the first ticket, or start the open one.
  private func startSelected() -> KeyPress.Result {
    guard let key = viewModel.selectedTicketKey else { return move(.down) }
    guard let ticket = viewModel.sprintTickets.first(where: { $0.key == key }),
      ticket.statusCategory != "done", (linkedSessions[key] ?? []).isEmpty
    else { return .ignored }
    start(key, provider: nil)
    return .handled
  }

  @ViewBuilder
  private var detail: some View {
    if let ticket = viewModel.selectedTicket {
      let links = linkedSessions[ticket.key] ?? []
      TicketDetailView(
        detail: TicketDetailPresentation.jira(
          ticket: ticket,
          sprintName: viewModel.selectedSprint?.name,
          isLoadingDetail: viewModel.isLoadingDetail,
          browseURL: viewModel.browseURL(for: ticket),
          columns: viewModel.columns,
          linkedSessions: links,
          pullRequests: viewModel.pullRequestsByTicket[ticket.key],
          isLoadingPullRequests: viewModel.loadingPullRequestKeys.contains(ticket.key),
          status: sessionStatus
        ),
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        isStarting: viewModel.startingSessionKeys.contains(ticket.key),
        isClaudeAvailable: isClaudeAvailable,
        isCodexAvailable: isCodexAvailable,
        actions: TicketDetailActions(
          onStart: { provider in start(ticket.key, provider: provider) },
          onOpenSession: { id in
            guard let link = links.first(where: { $0.id == id }) else { return }
            MainThreadStallMonitor.breadcrumb("sprint ticket: open session")
            onOpenSession(link)
          },
          onMove: { columnID in
            let category = viewModel.columns.first { $0.id == columnID }?.category
            Task { await viewModel.moveTicket(ticket.key, toStatus: columnID, category: category) }
          },
          onRefreshPullRequests: { viewModel.loadPullRequestsIfNeeded(for: ticket.key, force: true) },
          onClose: close
        )
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
    SprintRefreshButton(isLoading: viewModel.state == .loading, accessibilityLabel: "Refresh sprint") {
      Task { await viewModel.load(keepsBoardOnFailure: true) }
    }
  }

  /// What Filters holds: only the search now. The people filter is in the
  /// head, where its selection shows.
  private var activeFilterCount: Int {
    viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1
  }

  private var myAccountID: String? {
    viewModel.assignees.first(where: viewModel.isMe)?.accountId
  }

  @ViewBuilder
  private func peopleStrip(visibleLimit: Int) -> some View {
    let people = SprintPeopleFilter.jira(
      assignees: viewModel.assignees, isMe: viewModel.isMe, unassignedCount: viewModel.unassignedCount)
    if !people.isEmpty {
      SprintPeopleStrip(
        people: people,
        selected: SprintPeopleFilter.selectedKind(viewModel.assigneeFilter, myAccountID: myAccountID),
        visibleLimit: visibleLimit,
        onToggle: togglePerson)
    }
  }

  private func togglePerson(_ kind: SprintPerson.Kind) {
    let filter = SprintPeopleFilter.toggled(kind, current: viewModel.assigneeFilter, myAccountID: myAccountID)
    viewModel.assigneeFilter = filter
    MainThreadStallMonitor.breadcrumb("sprint filter: person \(filter == .everyone ? "off" : "on")")
  }

  private var filtersButton: some View {
    FiltersButton(
      activeCount: activeFilterCount,
      accessibilityIdentifier: "sprint.filters",
      onOpen: { isFiltersOpen = true },
      onClear: clearFilters
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

  /// Clears the search. All | Mine and the people filter stay: both show
  /// their state in the head and undo with one click.
  private func clearFilters() {
    viewModel.searchText = ""
    MainThreadStallMonitor.breadcrumb("sprint filter: clear")
  }

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
}

// MARK: - Failure

/// One state per failure kind, each said once next to its fix: missing acli
/// shows the install command, an auth error Connect, a network error Retry.
private struct JiraSprintFailureView: View {
  let message: String
  @Bindable var viewModel: JiraSprintViewModel

  var body: some View {
    Group {
      switch viewModel.failureKind ?? .other {
      case .cliMissing:
        WBEmptyState(
          systemImage: "terminal",
          title: "Install the Atlassian CLI",
          description: "Sprint reads Jira through acli. Install it, then retry."
        ) {
          VStack(spacing: DesignTokens.Spacing.md) {
            CommandBlock(JiraCLIProcessRunner.installCommand)
              .frame(maxWidth: 760)
            retryButton(style: .secondary)
          }
        }
      case .auth:
        WBEmptyState(
          systemImage: "person.crop.circle.badge.exclamationmark",
          isError: true,
          title: "Connect Jira",
          description: "Sign in to your Atlassian account to load the sprint."
        ) {
          connectButton(isPrimary: true)
        }
      case .network:
        WBEmptyState(
          systemImage: "wifi.exclamationmark",
          isError: true,
          title: "Could not reach Jira",
          description: SprintErrorText.summary(message)
        ) {
          retryButton(style: .primary)
        }
      case .other:
        WBEmptyState(
          systemImage: "exclamationmark.triangle",
          isError: true,
          title: "Could not load Jira",
          description: SprintErrorText.summary(message)
        ) {
          // The message may still be an expired sign-in acli words differently.
          HStack(spacing: DesignTokens.Spacing.sm) {
            retryButton(style: .primary)
            connectButton(isPrimary: false)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func connectButton(isPrimary: Bool) -> some View {
    let title = viewModel.isConnecting ? "Waiting for browser…" : "Connect Jira"
    let button = Button(title) { Task { await viewModel.connect() } }
      .disabled(viewModel.isConnecting)
    if isPrimary {
      button.buttonStyle(.wbPrimary)
    } else {
      button.buttonStyle(.wbSecondary)
    }
  }

  private enum RetryStyle { case primary, secondary }

  @ViewBuilder
  private func retryButton(style: RetryStyle) -> some View {
    // A load swaps this screen for the spinner; the view model also ignores a
    // second load while one runs.
    let button = Button("Retry") { Task { await viewModel.load(keepsBoardOnFailure: true) } }
      .disabled(viewModel.isConnecting)
    switch style {
    case .primary: button.buttonStyle(.wbPrimary)
    case .secondary: button.buttonStyle(.wbSecondary)
    }
  }
}
