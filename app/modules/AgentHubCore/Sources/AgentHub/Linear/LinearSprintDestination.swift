//
//  LinearSprintDestination.swift
//  AgentHub
//
//  The Linear side of the shell's Sprint destination: the team's active cycle
//  (or your open issues when there is none) on the shared Sprint board.
//

import AgentWorkflowLinear
import SwiftUI

struct LinearSprintDestination: View {
  @Bindable var viewModel: LinearViewModel
  @Binding var tracker: SprintTracker
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
      SprintListHead(tracker: $tracker, scope: scope) {
        if viewModel.loadState == .loaded || viewModel.loadState == .loading {
          refreshButton
          filtersButton
        }
      }
    } content: {
      content
    } detail: {
      detail
    }
    .task {
      if viewModel.loadState == .idle || viewModel.loadState == .noKey {
        await viewModel.load()
      }
    }
    .onDisappear { viewModel.closeIssue() }
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    switch viewModel.loadState {
    case .noKey:
      LinearConnectState(viewModel: viewModel, errorMessage: nil)
    case .unauthorized:
      LinearConnectState(viewModel: viewModel, errorMessage: "The Linear API key is invalid or revoked.")
    case .rateLimited:
      LinearRetryState(
        viewModel: viewModel, message: "Linear asked Workbench to slow down. Try again in a moment.")
    case .failed(let message):
      LinearRetryState(viewModel: viewModel, message: message)
    case .idle, .loading, .loaded:
      if viewModel.loadState != .loaded && viewModel.issues.isEmpty {
        SprintLoadingView()
      } else if viewModel.issues.isEmpty {
        WBEmptyState(
          systemImage: "tray",
          title: viewModel.isMyIssuesFallback ? "No open issues assigned to you" : "No issues in this cycle"
        )
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
        status: sessionStatus
      ),
      selectedTicketID: viewModel.selectedIssueID,
      actions: SprintBoardActions(
        onOpen: open,
        onStart: { start($0, provider: nil) },
        onOpenSession: { id in
          if let session = preferredSession(forIssueID: id) { onOpenSession(session) }
        },
        onMove: nil,
        browseURL: { id in
          viewModel.issues.first { $0.id == id }.flatMap { URL(string: $0.url) }
        }
      )
    )
    .focusable()
    .focused($isBoardFocused)
    .focusEffectDisabled()
    .onKeyPress(.escape) {
      guard viewModel.selectedIssueID != nil else { return .ignored }
      close()
      return .handled
    }
    .overlay {
      if viewModel.filteredIssues.isEmpty {
        WBEmptyState(
          systemImage: "line.3.horizontal.decrease",
          title: "No matching issues",
          description: "Switch to All or clear the filters."
        )
        .allowsHitTesting(false)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let issue = viewModel.selectedIssue {
      LinearIssueDetailView(
        issue: issue,
        cycleName: viewModel.activeCycle?.displayName,
        isLoadingDetail: viewModel.isLoadingDetail,
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        linkedSessions: linkedSessions[issue.identifier] ?? [],
        isClaudeAvailable: isClaudeAvailable,
        isCodexAvailable: isCodexAvailable,
        onStart: { provider in start(issue.id, provider: provider) },
        onOpenSession: onOpenSession,
        onClose: close
      )
    }
  }

  // MARK: List head

  private var scope: Binding<SprintAssigneeScope> {
    Binding(
      get: { viewModel.assigneeFilter == .me ? .mine : .all },
      set: { scope in
        viewModel.assigneeFilter = scope == .mine ? .me : .everyone
        MainThreadStallMonitor.breadcrumb("sprint filter: \(scope.rawValue)")
      }
    )
  }

  private var refreshButton: some View {
    IconButton(
      systemImage: "arrow.clockwise",
      accessibilityLabel: "Refresh issues",
      accessibilityIdentifier: "sprint.refresh"
    ) {
      Task { await viewModel.load() }
    }
    .disabled(viewModel.loadState == .loading)
    .help("Refresh issues  ⌘R")
    .keyboardShortcut("r", modifiers: .command)
  }

  private var filtersButton: some View {
    FiltersButton(
      activeCount: viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : 1,
      accessibilityIdentifier: "sprint.filters",
      onOpen: { isFiltersOpen = true },
      onClear: {
        viewModel.searchText = ""
        MainThreadStallMonitor.breadcrumb("sprint filter: clear")
      }
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

  private func preferredSession(forIssueID id: String) -> LinearLinkedSession? {
    guard let identifier = viewModel.issues.first(where: { $0.id == id })?.identifier else { return nil }
    let sessions = linkedSessions[identifier] ?? []
    return sessions.first { $0.isMonitored && !$0.isPending }
      ?? sessions.filter { !$0.isPending }.max { $0.lastActivityAt < $1.lastActivityAt }
  }

  /// Starts a session, or opens the detail when no project or agent is picked yet.
  private func start(_ id: String, provider: SessionProviderKind?) {
    guard
      let issue = viewModel.selectedIssue?.id == id
        ? viewModel.selectedIssue : viewModel.issues.first(where: { $0.id == id }),
      let path = viewModel.repositoryPath,
      let provider = provider
        ?? SprintStartProvider.preferred(
          isClaudeAvailable: isClaudeAvailable, isCodexAvailable: isCodexAvailable)
    else {
      open(id)
      return
    }
    MainThreadStallMonitor.breadcrumb("sprint ticket: start \(issue.identifier)")
    Task { await onStart(issue, provider, path) }
  }
}

// MARK: - Filters popover

private struct LinearSprintFiltersPopover: View {
  @Bindable var viewModel: LinearViewModel

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
      Toggle("Move issues to started when a session begins", isOn: $viewModel.moveToStartedOnLaunch)
        .wbText(.callout)
      Button("Disconnect Linear") { viewModel.disconnect() }
        .buttonStyle(.wbDestructive)
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: DesignTokens.Width.popover)
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
  let errorMessage: String?

  @State private var apiKey = ""
  @State private var isConnecting = false

  private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        ErrorBanner(errorMessage)
          .padding(.horizontal, DesignTokens.Spacing.lg)
      }
      WBEmptyState(
        systemImage: "key",
        title: "Connect Linear",
        description: "Paste a personal API key from Linear's security settings."
      ) {
        VStack(spacing: DesignTokens.Spacing.md) {
          SecureField("API key", text: $apiKey)
            .textFieldStyle(.plain)
            .wbText(.body)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(width: 300, height: DesignTokens.Size.control)
            .background(Color.wbSurfaceField, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.item))
            .onSubmit(connect)
          HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Connect", action: connect)
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
  }

  private func connect() {
    let key = trimmedKey
    guard !key.isEmpty else { return }
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
    VStack(spacing: 0) {
      ErrorBanner(message)
        .padding(.horizontal, DesignTokens.Spacing.lg)
      WBEmptyState(systemImage: "exclamationmark.triangle", isError: true, title: "Could not load Linear") {
        Button("Retry") { Task { await viewModel.load() } }
          .buttonStyle(.wbSecondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
