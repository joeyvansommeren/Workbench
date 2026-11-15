//
//  LinearSprintDestination.swift
//  AgentHub
//
//  The shell's Linear destination: the team's active cycle
//  (or your open issues when there is none), or one project's open issues,
//  on the shared Sprint board.
//

import AgentWorkflowLinear
import SwiftUI

struct LinearSprintDestination: View {
  @Bindable var viewModel: LinearViewModel
  let repositories: [SelectedRepository]
  let linkedSessions: [String: [LinearLinkedSession]]
  let isClaudeAvailable: Bool
  let isCodexAvailable: Bool
  let sessionStatus: (SessionProviderKind, String) -> SessionStatus?
  let onStart: (LinearIssue, SessionProviderKind, String) async -> Void
  let onOpenSession: (LinearLinkedSession) -> Void

  @State private var isFiltersOpen = false
  @FocusState private var isBoardFocused: Bool

  var body: some View {
    SprintDestinationLayout(isDetailVisible: viewModel.selectedIssueID != nil) {
      SprintListHead(
        title: SprintTitle.linear(project: viewModel.selectedProject, cycle: viewModel.activeCycle),
        scope: scope
      ) { isCompact in
        projectMenu(isCompact: isCompact)
      } trailing: {
        if viewModel.loadState == .loaded || viewModel.loadState == .loading {
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
    .task {
      if viewModel.loadState == .idle || viewModel.loadState == .noKey {
        await viewModel.load(keepsBoardOnFailure: true)
      }
    }
    .onDisappear { viewModel.closeIssue() }
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    switch viewModel.loadState {
    case .noKey:
      LinearConnectState(viewModel: viewModel, isKeyRejected: false)
    case .unauthorized:
      LinearConnectState(viewModel: viewModel, isKeyRejected: true)
    case .rateLimited:
      LinearRetryState(viewModel: viewModel, message: LinearViewModel.rateLimitedMessage)
    case .failed(let message):
      LinearRetryState(viewModel: viewModel, message: SprintErrorText.summary(message))
    case .idle, .loading, .loaded:
      if viewModel.loadState != .loaded && viewModel.issues.isEmpty {
        WBLoadingState("Loading sprint")
      } else if viewModel.issues.isEmpty {
        WBEmptyState(systemImage: "tray", title: emptyTitle)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        board
      }
    }
  }

  private var board: some View {
    SprintBoardView(
      columns: SprintBoardItems.linear(
        columns: viewModel.columns,
        linkedSessions: linkedSessions,
        startingIDs: viewModel.startingIssueIDs,
        status: sessionStatus
      ),
      selectedTicketID: viewModel.selectedIssueID,
      isFocused: isBoardFocused,
      actions: SprintBoardActions(
        onOpen: open,
        onStart: { start($0, provider: nil) },
        onOpenSession: { id in
          guard let identifier = viewModel.issues.first(where: { $0.id == id })?.identifier else {
            return
          }
          if let session = SprintBoardItems.sessionToOpen(linkedSessions[identifier] ?? []) {
            onOpenSession(session)
          }
        },
        onMove: { id, stateID in
          MainThreadStallMonitor.breadcrumb("sprint ticket: move \(id)")
          Task { await viewModel.moveIssue(id, toStateID: stateID) }
        },
        browseURL: { id in
          viewModel.issues.first { $0.id == id }.flatMap { URL(string: $0.url) }
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
      guard viewModel.selectedIssueID != nil else { return .ignored }
      close()
      return .handled
    }
    .overlay {
      if viewModel.filteredIssues.isEmpty {
        SprintNoMatchesView(
          title: "No matching issues",
          onClearFilters: isSearching ? clearSearch : nil,
          onShowAll: viewModel.assigneeFilter == .me ? { viewModel.assigneeFilter = .everyone } : nil)
      }
    }
  }

  private func move(_ direction: SprintMoveDirection) -> KeyPress.Result {
    viewModel.moveSelection(direction)
    if let id = viewModel.selectedIssueID {
      MainThreadStallMonitor.breadcrumb("sprint ticket: open \(id)")
    }
    return .handled
  }

  /// Return on the board: open the first issue, or start the open one.
  private func startSelected() -> KeyPress.Result {
    guard let id = viewModel.selectedIssueID else { return move(.down) }
    guard let issue = viewModel.issues.first(where: { $0.id == id }),
      issue.state.type != "completed", (linkedSessions[issue.identifier] ?? []).isEmpty
    else { return .ignored }
    start(id, provider: nil)
    return .handled
  }

  private var emptyTitle: String {
    if let project = viewModel.selectedProject { return "No open issues in \(project.name)" }
    return viewModel.isMyIssuesFallback ? "No open issues assigned to you" : "No issues in this cycle"
  }

  private var isSearching: Bool {
    !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func clearSearch() {
    viewModel.searchText = ""
    MainThreadStallMonitor.breadcrumb("sprint filter: clear")
  }

  @ViewBuilder
  private var detail: some View {
    if let issue = viewModel.selectedIssue {
      let links = linkedSessions[issue.identifier] ?? []
      TicketDetailView(
        detail: TicketDetailPresentation.linear(
          issue: issue,
          cycleName: viewModel.activeCycle?.displayName,
          isLoadingDetail: viewModel.isLoadingDetail,
          linkedSessions: links,
          moveStates: viewModel.columns.map(\.state),
          status: sessionStatus
        ),
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        isStarting: viewModel.startingIssueIDs.contains(issue.id),
        isClaudeAvailable: isClaudeAvailable,
        isCodexAvailable: isCodexAvailable,
        actions: TicketDetailActions(
          onStart: { provider in start(issue.id, provider: provider) },
          onOpenSession: { id in
            guard let link = links.first(where: { $0.id == id }) else { return }
            MainThreadStallMonitor.breadcrumb("sprint ticket: open session")
            onOpenSession(link)
          },
          onMove: { stateID in
            Task { await viewModel.moveIssue(issue.id, toStateID: stateID) }
          },
          onRefreshPullRequests: {},
          onClose: close
        )
      )
    }
  }

  // MARK: List head

  private var scope: Binding<SprintAssigneeScope> {
    SprintAssigneeScope.binding(
      isMine: { viewModel.assigneeFilter == .me },
      setMine: { viewModel.assigneeFilter = $0 ? .me : .everyone }
    )
  }

  /// Shown once the team's projects are known; a team without open
  /// projects has nothing to filter by.
  @ViewBuilder
  private func projectMenu(isCompact: Bool) -> some View {
    if !viewModel.projects.isEmpty {
      SprintProjectMenu(
        projects: viewModel.projects,
        selected: viewModel.selectedProject,
        isCompact: isCompact
      ) { projectID in
        MainThreadStallMonitor.breadcrumb("sprint filter: project \(projectID == nil ? "all" : "one")")
        Task { await viewModel.selectProject(projectID) }
      }
    }
  }

  private var refreshButton: some View {
    SprintRefreshButton(isLoading: viewModel.loadState == .loading, accessibilityLabel: "Refresh issues") {
      Task { await viewModel.load(keepsBoardOnFailure: true) }
    }
  }

  private var filtersButton: some View {
    FiltersButton(
      activeCount: isSearching ? 1 : 0,
      accessibilityIdentifier: "sprint.filters",
      onOpen: { isFiltersOpen = true },
      onClear: clearSearch
    )
    .popover(isPresented: $isFiltersOpen, arrowEdge: .bottom) {
      LinearSprintFiltersPopover(viewModel: viewModel)
    }
  }

  // MARK: Actions

  private func open(_ id: String) {
    viewModel.openIssue(id)
    isBoardFocused = true
    MainThreadStallMonitor.breadcrumb("sprint ticket: open \(id)")
  }

  private func close() {
    viewModel.closeIssue()
    MainThreadStallMonitor.breadcrumb("sprint ticket: close")
  }

  /// Starts a session, or opens the detail when no project or agent is picked yet.
  private func start(_ id: String, provider: SessionProviderKind?) {
    guard
      let issue = viewModel.selectedIssue?.id == id
        ? viewModel.selectedIssue : viewModel.issues.first(where: { $0.id == id }),
      let path = viewModel.repositoryPath,
      let provider = SprintStartProvider.resolve(
        provider, isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable)
    else {
      open(id)
      return
    }
    // A double-click on Start must not launch two sessions.
    guard viewModel.beginStartingSession(for: id) else { return }
    MainThreadStallMonitor.breadcrumb("sprint ticket: start \(issue.identifier)")
    Task {
      defer { viewModel.endStartingSession(for: id) }
      await onStart(issue, provider, path)
    }
  }
}

// MARK: - Filters popover

private struct LinearSprintFiltersPopover: View {
  @Bindable var viewModel: LinearViewModel

  @State private var isConfirmingDisconnect = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      WorkbenchField("Search issues", text: $viewModel.searchText, systemImage: "magnifyingglass")
      if viewModel.teams.count > 1 {
        SprintFilterSection(title: "Team") {
          Picker("Team", selection: teamSelection) {
            ForEach(viewModel.teams) { team in
              Text(team.name).tag(team.id)
            }
          }
          .labelsHidden()
        }
      }
      // The list head hides All | Mine in narrow windows; this keeps it reachable.
      SprintFilterSection(title: "Assignee") {
        Picker("Assignee", selection: assigneeSelection) {
          Text("Everyone").tag(LinearViewModel.AssigneeFilter.everyone)
          Text("Mine").tag(LinearViewModel.AssigneeFilter.me)
        }
        .labelsHidden()
        .accessibilityIdentifier("sprint.filters.assignee")
      }
      Toggle("Move issues to started when a session begins", isOn: $viewModel.moveToStartedOnLaunch)
        .wbText(.callout)
      // Deletes the key from the Keychain, so it asks first.
      Button("Disconnect Linear") { isConfirmingDisconnect = true }
        .buttonStyle(.wbDestructive)
        .confirmationDialog(
          "Disconnect Linear?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible
        ) {
          Button("Disconnect", role: .destructive) {
            viewModel.disconnect()
            MainThreadStallMonitor.breadcrumb("sprint linear: disconnect")
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("You need to paste your API key again to reconnect.")
        }
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Width.popover)
  }

  private var assigneeSelection: Binding<LinearViewModel.AssigneeFilter> {
    Binding(
      get: { viewModel.assigneeFilter },
      set: { filter in
        viewModel.assigneeFilter = filter
        MainThreadStallMonitor.breadcrumb("sprint filter: assignee")
      }
    )
  }

  private var teamSelection: Binding<String> {
    Binding(
      get: { viewModel.selectedTeamID ?? "" },
      set: { id in
        MainThreadStallMonitor.breadcrumb("sprint filter: team")
        Task { await viewModel.selectTeam(id) }
      }
    )
  }
}

// MARK: - Connect and failure states

/// No key yet, or a rejected key: ask for an API key.
private struct LinearConnectState: View {
  @Bindable var viewModel: LinearViewModel
  /// Linear refused the stored key; said once, in the description.
  let isKeyRejected: Bool

  @State private var apiKey = ""
  @State private var isConnecting = false

  private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    WBEmptyState(
      systemImage: "key",
      isError: isKeyRejected,
      title: "Connect Linear",
      description: isKeyRejected
        ? "Linear rejected the API key. Paste a new one from Linear's security settings."
        : "Paste a personal API key from Linear's security settings."
    ) {
      VStack(spacing: DesignTokens.Spacing.md) {
        SecureField("API key", text: $apiKey)
          .textFieldStyle(.plain)
          .wbText(.body)
          // Same inset as `WorkbenchField`.
          .padding(.horizontal, DesignTokens.Spacing.smPlus)
          .frame(width: 300, height: DesignTokens.Size.control)
          .background(
            Color.wbSurfaceField,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item, style: .continuous)
          )
          .onSubmit(connect)
        HStack(spacing: DesignTokens.Spacing.sm) {
          Button(isConnecting ? "Connecting…" : "Connect", action: connect)
            .buttonStyle(.wbPrimary)
            .disabled(trimmedKey.isEmpty || isConnecting)
          if let url = URL(string: "https://linear.app/settings/account/security") {
            Link("Create a key", destination: url)
              .wbText(.callout)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func connect() {
    let key = trimmedKey
    // Return in the field skips the button's disabled state.
    guard !key.isEmpty, !isConnecting else { return }
    isConnecting = true
    Task {
      await viewModel.connect(apiKey: key)
      isConnecting = false
    }
  }
}

private struct LinearRetryState: View {
  @Bindable var viewModel: LinearViewModel
  let message: String

  var body: some View {
    WBEmptyState(
      systemImage: "exclamationmark.triangle",
      isError: true,
      title: "Could not load Linear",
      description: message
    ) {
      // A load swaps this screen for the spinner; the view model also ignores
      // a second load while one runs.
      Button("Retry") { Task { await viewModel.load(keepsBoardOnFailure: true) } }
        .buttonStyle(.wbPrimary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
