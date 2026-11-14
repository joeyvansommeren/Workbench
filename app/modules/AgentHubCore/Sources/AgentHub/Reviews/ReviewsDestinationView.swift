//
//  ReviewsDestinationView.swift
//  AgentHub
//
//  The Reviews destination of the new shell: the scope and Filters bar, then
//  the pull request table. Clicking a row opens the detail as a fixed-width
//  trailing panel; the table stays visible next to it.
//
//  Layout-loop rules (CLAUDE.md, plan section 4): plain `HStack`/`VStack`
//  with fixed widths. No split views, no `.inspector`, no geometry-driven
//  widths, and nothing takes focus on appear. The legacy `GitHubReviewsView`
//  stays for the flag-off path.
//

import AgentHubGitHub
import SwiftUI

/// Reviews widths. Their sum, with the shell sidebar and panel inset, must fit
/// `ShellLayout.windowMinWidth` (checked by `ReviewsLayoutTests`).
enum ReviewsLayout {
  static let tableMinWidth: CGFloat = ReviewsTableLayout.minimumWidth
  static let hairlineWidth: CGFloat = 1
  static let detailWidth: CGFloat = DesignTokens.Width.sidePanel
  /// The prototype's `.list-head`, shared with Sprint (`SprintListHead`).
  static let barHeight: CGFloat = 56

  /// The narrowest content panel Reviews fits in, with the detail open.
  static var minimumContentWidth: CGFloat { tableMinWidth + hairlineWidth + detailWidth }
}

struct ReviewsDestinationView: View {
  let agentHub: AgentHubProvider
  let actions: WorkspaceLaunchActions

  @AppStorage(AgentHubDefaults.reviewsAgent)
  private var agentRaw = SessionProviderKind.claude.rawValue
  @State private var customMessageContext: GitHubReviewCustomMessageContext?
  @State private var sessionCommandContext: GitHubReviewSessionCommandContext?
  @State private var sessionFeedback: String?
  /// The pull request whose detail was closed while it stays selected. Any
  /// other selection (a click, a jump from a session) opens the detail.
  @State private var closedDetailID: String?
  @State private var pendingBulkLaunch: GitHubReviewBulkLaunch?
  @State private var pendingFollowUp: GitHubReviewBulkFollowUp?
  /// "Sent to 3 of 4 sessions" after a bulk follow-up, shown in the bar.
  @State private var bulkFeedback: String?
  /// A running "Start for N" launch: its progress in the bar, and the task
  /// Stop cancels. The id tells a finished launch from a newer one.
  @State private var bulkProgress: ReviewsBulkLaunchProgress?
  @State private var bulkLaunchTask: Task<Void, Never>?
  @State private var bulkLaunchID: UUID?
  @State private var isFiltersOpen = false
  @State private var linkCache = ReviewsSessionLinkCache()

  private var viewModel: GitHubReviewsViewModel { agentHub.gitHubReviewsViewModel }
  private var support: ReviewSessionSupport { ReviewSessionSupport(agentHub: agentHub) }

  var body: some View {
    let visible = viewModel.visiblePullRequests
    let tileColors = tileColorsByRepositoryName
    // Relinked only when the pull requests, launches or session inventory
    // change; a status tick only refreshes the statuses on the cached links.
    let cachedLinks = linkCache.links(key: support.linkKey(for: visible)) {
      let inventories = support.inventories
      return Dictionary(
        visible.map { ($0.id, support.links(for: $0, inventories: inventories)) },
        uniquingKeysWith: { first, _ in first }
      )
    }
    let links = ReviewsSessionLinkCache.applyingStatuses(cachedLinks, statuses: support.statuses)
    let rows = ReviewsTableRows.make(pullRequests: visible, links: links, sort: viewModel.tableSort)
    let detailPullRequest = openDetailPullRequest(in: visible)
    let bulkActions = ReviewsBulkActions(rows: rows, viewModel: viewModel)

    VStack(spacing: 0) {
      ReviewsBar(
        viewModel: viewModel,
        isFiltersOpen: $isFiltersOpen,
        feedback: bulkFeedback,
        onRetry: { await support.recoverAndRestoreSessions() }
      ) {
        if let bulkProgress {
          ReviewsBulkLaunchProgressView(progress: bulkProgress, onStop: stopBulkLaunch)
        } else if !bulkActions.isEmpty {
          ReviewsBulkActionsMenu(
            actions: bulkActions,
            templates: GitHubPromptLibrary.shared.templates,
            isAgentAvailable: isAgentAvailable,
            isStarting: !viewModel.startingReviewPRIDs.isEmpty,
            onLaunch: { launch in
              MainThreadStallMonitor.breadcrumb("reviews bulk: start \(launch.pullRequests.count)")
              pendingBulkLaunch = launch
            },
            onFollowUp: { followUp in
              MainThreadStallMonitor.breadcrumb("reviews bulk: follow-up \(followUp.targets.count)")
              pendingFollowUp = followUp
            }
          )
        }
      }
      Color.wbBorderHairline.frame(height: 1)
      HStack(spacing: 0) {
        ReviewsQueueContent(
          viewModel: viewModel,
          isEmpty: visible.isEmpty,
          onRetry: { await support.recoverAndRestoreSessions() },
          onOpenFilters: { isFiltersOpen = true }
        ) {
          table(rows: rows, links: links, tileColors: tileColors)
        }
        .frame(minWidth: ReviewsLayout.tableMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .clipped()

        if let detailPullRequest {
          Color.wbBorderHairline
            .frame(width: ReviewsLayout.hairlineWidth)
          detail(detailPullRequest, links: links[detailPullRequest.id] ?? [], tileColors: tileColors)
            // Outside the detail's `.id`: the entrance runs when the panel
            // opens, not on every row change (selection is instant).
            .wbPanelEntrance()
            .frame(width: ReviewsLayout.detailWidth)
            .frame(maxHeight: .infinity)
            .clipped()
        }
      }
    }
    .onExitCommand { closeDetail() }
    .task {
      agentHub.claudeSessionsViewModel.refreshCLIAvailability()
      agentHub.codexSessionsViewModel.refreshCLIAvailability()
      await viewModel.load()
      await support.recoverAndRestoreSessions()
    }
    .task(id: viewModel.selectedPullRequestID) {
      sessionFeedback = nil
      guard viewModel.selectedPullRequestID != nil else { return }
      await viewModel.loadSelectedDetail()
    }
    .task(id: sessionFeedback) {
      guard sessionFeedback != nil else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      sessionFeedback = nil
    }
    .task(id: bulkFeedback) {
      guard bulkFeedback != nil else { return }
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      bulkFeedback = nil
    }
    // These notices go away after a few seconds; VoiceOver users hear them.
    .onChange(of: sessionFeedback) { _, text in announce(text) }
    .onChange(of: bulkFeedback) { _, text in announce(text) }
    .confirmationDialog(
      pendingBulkLaunch?.title ?? "",
      isPresented: Binding(
        get: { pendingBulkLaunch != nil },
        set: { if !$0 { pendingBulkLaunch = nil } }
      ),
      presenting: pendingBulkLaunch
    ) { launch in
      Button(launch.confirmTitle) { runBulkLaunch(launch) }
      Button("Cancel", role: .cancel) { pendingBulkLaunch = nil }
    } message: { launch in
      Text(launch.message)
    }
    .confirmationDialog(
      pendingFollowUp?.title ?? "",
      isPresented: Binding(
        get: { pendingFollowUp != nil },
        set: { if !$0 { pendingFollowUp = nil } }
      ),
      presenting: pendingFollowUp
    ) { followUp in
      Button("Send to \(ReviewsCopy.count(followUp.targets.count, "session"))") {
        runFollowUp(followUp)
      }
      Button("Cancel", role: .cancel) { pendingFollowUp = nil }
    } message: { followUp in
      Text(followUp.message)
    }
    .sheet(item: $customMessageContext) { context in
      GitHubReviewCustomMessageSheet(
        context: context,
        onCancel: { customMessageContext = nil },
        onStart: { message, includeContext in
          customMessageContext = nil
          startReview(
            context.pullRequest,
            provider: context.provider,
            template: GitHubPromptLibrary.customMessageTemplate(
              message: message, includePullRequestContext: includeContext)
          )
        }
      )
    }
    .sheet(item: $sessionCommandContext) { context in
      GitHubReviewSessionCommandSheet(
        context: context,
        onCancel: { sessionCommandContext = nil },
        onSend: { command in
          sessionCommandContext = nil
          guard
            let prompt = GitHubReviewFollowUpPromptBuilder.custom(
              command, pullRequest: context.pullRequest)
          else { return }
          sendCommand(prompt, to: context.link)
        }
      )
    }
  }

  // MARK: - Table

  private func table(
    rows: [GitHubReviewTableRow],
    links: [String: [GitHubReviewSessionLink]],
    tileColors: [String: RepositoryTileColor]
  ) -> some View {
    let now = Date()
    let presentations = rows.map {
      ReviewsTableRowPresentation(row: $0, checks: viewModel.checksByPullRequestID[$0.id], now: now)
    }
    let pullRequestsByID = Dictionary(
      rows.map { ($0.id, $0.pullRequest) }, uniquingKeysWith: { first, _ in first })
    let ids = presentations.map(\.id)
    return ReviewsTableView(
      rows: presentations,
      selectedID: viewModel.selectedPullRequestID,
      sort: viewModel.tableSort,
      context: { id in
        let pullRequest = pullRequestsByID[id]
        let link = links[id]?.first
        return ReviewsTableRowContext(
          tileColor: pullRequest.map { tileColor(for: $0, in: tileColors) } ?? .teal,
          review: pullRequest.map(reviewControl(for:)) ?? emptyReviewControl,
          onOpenSession: link.map { link in { openSession(link) } }
        )
      },
      onSort: sortBy,
      onSelect: { id in
        guard let pullRequest = pullRequestsByID[id] else { return }
        select(pullRequest)
      },
      onMoveSelection: { delta in moveSelection(by: delta, in: ids, pullRequests: pullRequestsByID) },
      isDetailOpen: isDetailOpen,
      onOpenDetail: openDetail,
      onCloseDetail: closeDetail
    )
  }

  private func sortBy(_ column: ReviewsTableColumn) {
    viewModel.tableSort = ReviewsTableSort.next(
      after: viewModel.tableSort, clicking: column, checks: viewModel.checksByPullRequestID)
    MainThreadStallMonitor.breadcrumb("reviews sort: \(column.rawValue)")
  }

  private func select(_ pullRequest: GitHubProjectPullRequest) {
    let wasOpen = isDetailOpen
    closedDetailID = nil
    if viewModel.selectedPullRequestID != pullRequest.id {
      viewModel.selectedPullRequestID = pullRequest.id
      MainThreadStallMonitor.breadcrumb("reviews pr: \(pullRequest.repositoryName)#\(pullRequest.number)")
    }
    if !wasOpen { MainThreadStallMonitor.breadcrumb("reviews detail: open") }
  }

  /// ↑/↓ moves the selection. An open detail follows it; a closed one stays closed.
  private func moveSelection(
    by delta: Int, in ids: [String], pullRequests: [String: GitHubProjectPullRequest]
  ) {
    let wasOpen = isDetailOpen
    guard
      let id = ReviewsTableSelection.moved(
        from: viewModel.selectedPullRequestID, in: ids, by: delta),
      id != viewModel.selectedPullRequestID, let pullRequest = pullRequests[id]
    else { return }
    viewModel.selectedPullRequestID = id
    closedDetailID = wasOpen ? nil : id
    MainThreadStallMonitor.breadcrumb("reviews pr: \(pullRequest.repositoryName)#\(pullRequest.number)")
  }

  private var isDetailOpen: Bool {
    guard let selected = viewModel.selectedPullRequestID else { return false }
    return selected != closedDetailID
  }

  private func openDetail() {
    guard viewModel.selectedPullRequestID != nil, !isDetailOpen else { return }
    closedDetailID = nil
    MainThreadStallMonitor.breadcrumb("reviews detail: open")
  }

  private func closeDetail() {
    guard isDetailOpen else { return }
    closedDetailID = viewModel.selectedPullRequestID
    MainThreadStallMonitor.breadcrumb("reviews detail: close")
  }

  private func openDetailPullRequest(in visible: [GitHubProjectPullRequest]) -> GitHubProjectPullRequest? {
    guard isDetailOpen else { return nil }
    return visible.first { $0.id == viewModel.selectedPullRequestID }
  }

  // MARK: - Detail

  private func detail(
    _ pullRequest: GitHubProjectPullRequest,
    links: [GitHubReviewSessionLink],
    tileColors: [String: RepositoryTileColor]
  ) -> some View {
    PullRequestDetailView(
      pullRequest: pullRequest,
      detail: viewModel.selectedDetail,
      isLoadingDetail: viewModel.isLoadingDetail,
      detailError: viewModel.detailError,
      detailUpdatedAt: viewModel.detailUpdatedAt,
      tileColor: tileColor(for: pullRequest, in: tileColors),
      viewerLogin: viewModel.viewerLogin,
      sessionLinks: links,
      sessionFeedback: sessionFeedback,
      review: reviewControl(for: pullRequest),
      onOpenSession: openSession,
      onFollowUp: { link, followUp in
        switch followUp {
        case .pullAndReviewAgain:
          sendCommand(GitHubReviewFollowUpPromptBuilder.pullAndReviewAgain(pullRequest), to: link)
        case .sendCommand:
          sessionCommandContext = GitHubReviewSessionCommandContext(pullRequest: pullRequest, link: link)
        }
      },
      onRefresh: {
        MainThreadStallMonitor.breadcrumb("reviews detail: refresh")
        Task { await viewModel.loadSelectedDetail() }
      },
      onClose: closeDetail
    )
    .id(pullRequest.id)
  }

  private func openSession(_ link: GitHubReviewSessionLink) {
    MainThreadStallMonitor.breadcrumb("reviews open session: \(link.itemID)")
    actions.openReviewSession(link)
  }

  private func sendCommand(_ prompt: String, to link: GitHubReviewSessionLink) {
    guard GitHubReviewSessionCommandPolicy.canSend(isPending: link.isPending) else {
      sessionFeedback = "Session is still starting"
      return
    }
    let sessions =
      link.provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
    let didSend = sessions.sendAutomatedPrompt(to: link.session, prompt: prompt)
    MainThreadStallMonitor.breadcrumb("reviews session command: \(link.provider.rawValue)")
    sessionFeedback =
      didSend
      ? "Sent to \(PullRequestReviewControl.displayName(link.provider))" : "Could not send command"
  }

  // MARK: - Bulk actions

  /// Sequential, as in the legacy header: each launch registers its session
  /// link before the next starts. The bar shows "Starting 3 of 40" and a
  /// Stop button until the last one has started.
  private func runBulkLaunch(_ launch: GitHubReviewBulkLaunch) {
    pendingBulkLaunch = nil
    bulkLaunchTask?.cancel()
    let launchID = UUID()
    bulkLaunchID = launchID
    bulkProgress = ReviewsBulkLaunchProgress(total: launch.pullRequests.count)
    bulkLaunchTask = Task {
      for pullRequest in launch.pullRequests {
        if Task.isCancelled { break }
        if viewModel.beginStartingReview(for: pullRequest.id) {
          await actions.startReview(pullRequest, provider: launch.provider, template: launch.template)
          viewModel.endStartingReview(for: pullRequest.id)
        }
        guard bulkLaunchID == launchID else { return }
        bulkProgress?.advance()
      }
      guard bulkLaunchID == launchID else { return }
      bulkProgress = nil
      bulkLaunchTask = nil
      bulkLaunchID = nil
    }
  }

  private func stopBulkLaunch() {
    MainThreadStallMonitor.breadcrumb("reviews bulk: stop")
    bulkLaunchTask?.cancel()
    if let bulkProgress {
      bulkFeedback = "Stopped after \(ReviewsCopy.count(bulkProgress.started, "session"))"
    }
    bulkLaunchTask = nil
    bulkProgress = nil
    bulkLaunchID = nil
  }

  private func announce(_ text: String?) {
    guard let text else { return }
    AccessibilityNotification.Announcement(text).post()
  }

  private func runFollowUp(_ followUp: GitHubReviewBulkFollowUp) {
    pendingFollowUp = nil
    var sent = 0
    for target in followUp.targets
    where GitHubReviewSessionCommandPolicy.canSend(isPending: target.link.isPending) {
      let sessions =
        target.link.provider == .claude
        ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
      if sessions.sendAutomatedPrompt(to: target.link.session, prompt: followUp.prompt(for: target)) {
        sent += 1
      }
    }
    bulkFeedback = "Sent to \(sent) of \(ReviewsCopy.count(followUp.targets.count, "session"))"
  }

  // MARK: - Review

  private var agent: SessionProviderKind {
    SessionProviderKind(rawValue: agentRaw) ?? .claude
  }

  private func isAgentAvailable(_ provider: SessionProviderKind) -> Bool {
    (provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel)
      .isCLIAvailable
  }

  private func reviewControl(for pullRequest: GitHubProjectPullRequest) -> PullRequestReviewControl {
    PullRequestReviewControl(
      agent: agent,
      templates: GitHubPromptLibrary.shared.templates,
      isStarting: viewModel.startingReviewPRIDs.contains(pullRequest.id),
      isAgentAvailable: isAgentAvailable,
      onSelectAgent: { provider in
        agentRaw = provider.rawValue
        MainThreadStallMonitor.breadcrumb("reviews agent: \(provider.rawValue)")
      },
      onReview: { provider, template in
        startReview(pullRequest, provider: provider, template: template)
      },
      onWriteOwnMessage: { provider in
        customMessageContext = GitHubReviewCustomMessageContext(
          pullRequest: pullRequest, provider: provider)
      }
    )
  }

  /// Never shown: every row id maps to a pull request.
  private var emptyReviewControl: PullRequestReviewControl {
    PullRequestReviewControl(
      agent: agent, templates: [], isStarting: true, isAgentAvailable: { _ in false },
      onSelectAgent: { _ in }, onReview: { _, _ in }, onWriteOwnMessage: { _ in })
  }

  private func startReview(
    _ pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    template: GitHubPromptTemplate
  ) {
    guard viewModel.beginStartingReview(for: pullRequest.id) else { return }
    MainThreadStallMonitor.breadcrumb("reviews start review: \(provider.rawValue)")
    Task {
      defer { viewModel.endStartingReview(for: pullRequest.id) }
      await actions.startReview(pullRequest, provider: provider, template: template)
    }
  }

  // MARK: - Tile colours

  /// Tiles match the sidebar when the repository is open locally (colour from
  /// its path); otherwise the colour comes from `owner/name`.
  private var tileColorsByRepositoryName: [String: RepositoryTileColor] {
    let repositories = ShellSessionItems.repositories(
      claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel
    )
    var colors: [String: RepositoryTileColor] = [:]
    for repository in repositories {
      colors[repository.name.lowercased()] = RepositoryTileColor.forPath(repository.path)
    }
    return colors
  }

  private func tileColor(
    for pullRequest: GitHubProjectPullRequest,
    in colors: [String: RepositoryTileColor]
  ) -> RepositoryTileColor {
    colors[pullRequest.repositoryName.lowercased()]
      ?? RepositoryTileColor.forPath(pullRequest.repositoryNameWithOwner)
  }
}

// MARK: - Bar

/// The scope (Requested / Mine / All), the bulk actions and the Filters
/// popover, above the table.
private struct ReviewsBar<Actions: View>: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  /// Lifted, so the "Choose a project view" state can open Filters too.
  @Binding var isFiltersOpen: Bool
  let feedback: String?
  let onRetry: () async -> Void
  @ViewBuilder let actions: () -> Actions

  @State private var reloadTask: Task<Void, Never>?

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      WorkbenchSegmentedControl(
        selection: Binding(
          get: { viewModel.reviewScope },
          set: { viewModel.setReviewScope($0) }
        ),
        showCounts: { viewModel.count(for: $0) },
        accessibilityIdentifier: "reviews.scope"
      )
      .fixedSize()
      Spacer(minLength: 0)
      if let feedback {
        Text(feedback)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
          .lineLimit(1)
      }
      actions()
      refreshButton
      FiltersButton(
        activeCount: isSearching ? 1 : 0,
        accessibilityIdentifier: "reviews.filters",
        onOpen: {
          isFiltersOpen = true
          MainThreadStallMonitor.breadcrumb("reviews filters: open")
        },
        onClear: { viewModel.searchText = "" }
      )
      .fixedSize()
      .popover(isPresented: $isFiltersOpen, arrowEdge: .bottom) {
        ReviewsFiltersPopover(viewModel: viewModel, onStop: stopRefresh)
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: ReviewsLayout.barHeight)
    .onDisappear {
      reloadTask?.cancel()
      reloadTask = nil
    }
  }

  private var isSearching: Bool {
    !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// ⌘R, as in Jira and Linear. While a refresh runs, a spinner takes its
  /// place (same size); Stop is in the Filters popover.
  @ViewBuilder
  private var refreshButton: some View {
    if viewModel.isRefreshing {
      ProgressView()
        .controlSize(.small)
        .frame(width: DesignTokens.Size.control, height: DesignTokens.Size.control)
        .accessibilityLabel("Refreshing pull requests")
    } else {
      IconButton(
        systemImage: "arrow.clockwise",
        accessibilityLabel: "Refresh pull requests",
        accessibilityIdentifier: "reviews.refresh",
        action: refresh
      )
      .help("Refresh pull requests  ⌘R")
      .keyboardShortcut("r", modifiers: .command)
    }
  }

  private func stopRefresh() {
    viewModel.cancelRefresh()
    reloadTask?.cancel()
    reloadTask = nil
    MainThreadStallMonitor.breadcrumb("reviews refresh: stop")
  }

  private func refresh() {
    guard !viewModel.isRefreshing else { return }
    MainThreadStallMonitor.breadcrumb("reviews refresh")
    reloadTask = Task {
      await viewModel.reloadProjects()
      guard !Task.isCancelled, viewModel.recoveryIssue == nil else { return }
      await onRetry()
      reloadTask = nil
    }
  }
}

// MARK: - Queue content

/// The table, or the state that replaces it: loading, empty, no matches, or a
/// recovery step (gh missing, signed out, missing scope, rate limited).
private struct ReviewsQueueContent<Table: View>: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  let isEmpty: Bool
  let onRetry: () async -> Void
  let onOpenFilters: () -> Void
  @ViewBuilder let table: () -> Table

  @State private var recoveryFeedback: String?

  var body: some View {
    VStack(spacing: 0) {
      banners
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  @ViewBuilder
  private var banners: some View {
    // A failed refresh with saved rows on screen: the rows stay, and this
    // says they are the saved list and offers the way out.
    if let issue = viewModel.recoveryIssue, !viewModel.pullRequests.isEmpty {
      ReviewsRecoveryBanner(
        title: issue.title,
        detail: recoveryFeedback ?? "Showing the saved list.",
        actionTitle: issue.primaryActionTitle,
        isActionDisabled: issue.primaryAction == .retry && viewModel.isRefreshing,
        action: { perform(issue.primaryAction) }
      )
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.top, DesignTokens.Spacing.sm)
    }
    if let message = viewModel.errorMessage ?? viewModel.sessionLinkErrorMessage {
      ErrorBanner(message)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.sm)
    }
  }

  private var isSearching: Bool {
    !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var content: some View {
    if let issue = viewModel.recoveryIssue, viewModel.pullRequests.isEmpty {
      recoveryState(issue)
    } else if viewModel.isLoadingProjects, viewModel.projects.isEmpty {
      ReviewsLoadingView()
    } else if viewModel.selectedProject == nil {
      state(
        "rectangle.3.group", title: "No GitHub Projects",
        description: "Sign in to gh with the project scope.")
    } else if viewModel.selectedView == nil {
      state("line.3.horizontal.decrease", title: "Choose a project view") {
        Button("Open Filters", action: onOpenFilters).buttonStyle(.wbSecondary)
      }
    } else if viewModel.isLoadingPullRequests, viewModel.pullRequests.isEmpty {
      ReviewsLoadingView()
    } else if isEmpty {
      if isSearching {
        state("magnifyingglass", title: "No matches") {
          Button("Clear search") { viewModel.searchText = "" }.buttonStyle(.wbSecondary)
        }
      } else if viewModel.reviewScope == .mine, viewModel.viewerLogin == nil {
        // Mine needs your GitHub login (offline, signed out).
        state("person.crop.circle.badge.questionmark", title: "Can't tell which pull requests are yours") {
          Button("Try again") { perform(.retry) }
            .buttonStyle(.wbSecondary)
            .disabled(viewModel.isRefreshing)
        }
      } else {
        state("checkmark.circle", title: "No pull requests")
      }
    } else {
      table()
    }
  }

  private func state<Actions: View>(
    _ icon: WBEmptyStateIcon,
    title: String,
    description: String? = nil,
    isError: Bool = false,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) -> some View {
    // Centred, as in every other destination.
    WBEmptyState(
      icon: icon, isError: isError, title: title, description: description,
      actions: actions
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func recoveryState(_ issue: GitHubReviewRecoveryIssue) -> some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      state("exclamationmark.triangle", title: issue.title, description: issue.message, isError: true) {
        Button(issue.primaryActionTitle) { perform(issue.primaryAction) }
          .buttonStyle(.wbPrimary)
          .disabled(issue.primaryAction == .retry && viewModel.isRefreshing)
        if let secondary = issue.secondaryAction, let title = issue.secondaryActionTitle {
          Button(title) { perform(secondary) }
            .buttonStyle(.wbSecondary)
            .disabled(secondary == .retry && viewModel.isRefreshing)
        }
      }
      if let recoveryFeedback {
        Text(recoveryFeedback)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 300)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func perform(_ action: GitHubReviewRecoveryIssue.Action) {
    MainThreadStallMonitor.breadcrumb("reviews recovery: \(action)")
    if action == .retry {
      guard !viewModel.isRefreshing else { return }
      recoveryFeedback = nil
      Task {
        await viewModel.reloadProjects()
        guard viewModel.recoveryIssue == nil else { return }
        await onRetry()
      }
      return
    }
    if let error = GitHubAuthenticationRecoveryLauncher.perform(action) {
      recoveryFeedback = error.localizedDescription
    } else {
      switch action {
      case .reconnectWithProjectAccess, .signIn:
        recoveryFeedback = "Finish signing in in Terminal and your browser, then choose Try again."
      case .installCLI:
        recoveryFeedback = "Install the GitHub CLI, then choose Try again."
      case .retry:
        break
      }
    }
    if let recoveryFeedback {
      AccessibilityNotification.Announcement(recoveryFeedback).post()
    }
  }
}

/// A failed refresh above saved rows: the issue, "Showing the saved list."
/// and the issue's first action (Try again, Sign in, Install). Looks like
/// `ErrorBanner`, plus the action.
private struct ReviewsRecoveryBanner: View {
  let title: String
  let detail: String
  let actionTitle: String
  let isActionDisabled: Bool
  let action: () -> Void

  var body: some View {
    // In a narrow table (detail open at the window minimum) the action goes
    // under the text instead of squeezing it.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        icon
        message.frame(maxWidth: .infinity, alignment: .leading)
        actionButton
      }
      HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
        icon
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          message
          actionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(Color.wbStatusErrorTint, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reviews.recoveryBanner")
  }

  private var icon: some View {
    Image(systemName: "exclamationmark.triangle.fill")
      .font(.system(size: 13))
      .foregroundStyle(Color.wbStatusErrorFill)
      .accessibilityHidden(true)
  }

  private var message: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbStatusErrorText)
        .fixedSize(horizontal: false, vertical: true)
      Text(detail)
        .wbText(.callout)
        .foregroundStyle(Color.wbStatusErrorText)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var actionButton: some View {
    Button(actionTitle, action: action)
      .buttonStyle(.wbSecondary)
      .fixedSize()
      .disabled(isActionDisabled)
  }
}

/// A centred spinner while the queue loads, as `SprintLoadingView` does for
/// the boards.
private struct ReviewsLoadingView: View {
  var body: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel("Loading pull requests")
  }
}
