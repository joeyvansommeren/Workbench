//
//  ReviewsDestinationView.swift
//  AgentHub
//
//  The Reviews destination of the new shell (`ReviewsView` in the prototype):
//  a fixed 400 pt pull request list, a hairline, then the detail.
//
//  Layout-loop rules (CLAUDE.md, plan section 4): a plain `HStack` with a
//  fixed list width. No split views, no geometry-driven widths, and nothing
//  takes focus on appear. The legacy `GitHubReviewsView` stays for the
//  flag-off path.
//

import AgentHubGitHub
import SwiftUI

enum ReviewsLayout {
  static let listWidth: CGFloat = 400
  /// Must fit the shell's minimum: sidebar 288 + list 400 + hairline 1 +
  /// detail 200 + panel inset 8 = 897 ≤ `ShellLayout.windowMinWidth` (900).
  static let detailMinWidth: CGFloat = 200
}

struct ReviewsDestinationView: View {
  let agentHub: AgentHubProvider
  let actions: WorkspaceLaunchActions

  @AppStorage(AgentHubDefaults.reviewsAgent)
  private var agentRaw = SessionProviderKind.claude.rawValue
  @State private var customMessageContext: GitHubReviewCustomMessageContext?

  private var viewModel: GitHubReviewsViewModel { agentHub.gitHubReviewsViewModel }
  private var support: ReviewSessionSupport { ReviewSessionSupport(agentHub: agentHub) }

  var body: some View {
    // Built once per render and handed down, as in the legacy view.
    let inventories = support.inventories
    let visible = viewModel.visiblePullRequests
    let tileColors = tileColorsByRepositoryName
    let links = Dictionary(
      visible.map { ($0.id, support.links(for: $0, inventories: inventories)) },
      uniquingKeysWith: { first, _ in first }
    )

    HStack(spacing: 0) {
      ReviewsListColumn(
        viewModel: viewModel,
        visiblePullRequests: visible,
        tileColor: { tileColor(for: $0, in: tileColors) },
        sessionLinks: links,
        onRetry: { await support.recoverAndRestoreSessions() }
      )
      .frame(width: ReviewsLayout.listWidth)

      Color.wbBorderHairline
        .frame(width: 1)

      // The detail sits in an overlay so its content can never widen the
      // row: near the window minimum it clips instead of pushing the list
      // over (child minimums must fit the window, CLAUDE.md layout loop).
      Color.clear
        .frame(minWidth: ReviewsLayout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
          detail(visible: visible, links: links, tileColors: tileColors)
        }
        .clipped()
    }
    .task {
      agentHub.claudeSessionsViewModel.refreshCLIAvailability()
      agentHub.codexSessionsViewModel.refreshCLIAvailability()
      await viewModel.load()
      await support.recoverAndRestoreSessions()
    }
    .task(id: viewModel.selectedPullRequestID) {
      guard viewModel.selectedPullRequestID != nil else { return }
      await viewModel.loadSelectedDetail()
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
  }

  // MARK: - Detail

  @ViewBuilder
  private func detail(
    visible: [GitHubProjectPullRequest],
    links: [String: [GitHubReviewSessionLink]],
    tileColors: [String: RepositoryTileColor]
  ) -> some View {
    if let pullRequest = visible.first(where: { $0.id == viewModel.selectedPullRequestID }) {
      PullRequestDetailView(
        pullRequest: pullRequest,
        detail: viewModel.selectedDetail,
        isLoadingDetail: viewModel.isLoadingDetail,
        detailError: viewModel.detailError,
        tileColor: tileColor(for: pullRequest, in: tileColors),
        viewerLogin: viewModel.viewerLogin,
        sessionLink: links[pullRequest.id]?.first,
        review: reviewControl(for: pullRequest),
        onOpenSession: { link in
          MainThreadStallMonitor.breadcrumb("reviews open session: \(link.itemID)")
          actions.openReviewSession(link)
        }
      )
      .id(pullRequest.id)
    } else if !visible.isEmpty {
      WBEmptyState(systemImage: "arrow.triangle.pull", title: "No pull request selected")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Color.clear
    }
  }

  private var agent: SessionProviderKind {
    SessionProviderKind(rawValue: agentRaw) ?? .claude
  }

  private func reviewControl(for pullRequest: GitHubProjectPullRequest) -> PullRequestReviewControl {
    PullRequestReviewControl(
      agent: agent,
      templates: GitHubPromptLibrary.shared.templates,
      isStarting: viewModel.startingReviewPRIDs.contains(pullRequest.id),
      isAgentAvailable: { provider in
        (provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel)
          .isCLIAvailable
      },
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

// MARK: - List column

private struct ReviewsListColumn: View {
  @Bindable var viewModel: GitHubReviewsViewModel
  let visiblePullRequests: [GitHubProjectPullRequest]
  let tileColor: (GitHubProjectPullRequest) -> RepositoryTileColor
  let sessionLinks: [String: [GitHubReviewSessionLink]]
  let onRetry: () async -> Void

  @State private var isFiltersOpen = false
  @State private var reloadTask: Task<Void, Never>?
  @State private var recoveryFeedback: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      banners
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onDisappear {
      reloadTask?.cancel()
      reloadTask = nil
    }
  }

  private var header: some View {
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
        ReviewsFiltersPopover(viewModel: viewModel, onReload: toggleReload)
      }
    }
    .padding(.leading, DesignTokens.Spacing.lg)
    .padding(.trailing, DesignTokens.Spacing.md)
    .frame(height: 56)
  }

  private var isSearching: Bool {
    !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var banners: some View {
    if let message = viewModel.errorMessage ?? viewModel.sessionLinkErrorMessage {
      ErrorBanner(message)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let issue = viewModel.recoveryIssue, viewModel.pullRequests.isEmpty {
      recoveryState(issue)
    } else if viewModel.isLoadingProjects, viewModel.projects.isEmpty {
      state("arrow.triangle.pull", title: "Loading pull requests")
    } else if viewModel.selectedProject == nil {
      state(
        "rectangle.3.group", title: "No GitHub Projects",
        description: "Sign in to gh with the project scope.")
    } else if viewModel.selectedView == nil {
      state("line.3.horizontal.decrease", title: "Choose a project view") {
        Button("Filters") { isFiltersOpen = true }.buttonStyle(.wbSecondary)
      }
    } else if viewModel.isLoadingPullRequests, viewModel.pullRequests.isEmpty {
      state("arrow.triangle.pull", title: "Loading pull requests")
    } else if visiblePullRequests.isEmpty {
      if isSearching {
        state("magnifyingglass", title: "No matches") {
          Button("Clear search") { viewModel.searchText = "" }.buttonStyle(.wbSecondary)
        }
      } else {
        state("checkmark.circle", title: "No pull requests")
      }
    } else {
      rows
    }
  }

  private var rows: some View {
    ScrollView {
      LazyVStack(spacing: DesignTokens.Spacing.xxs) {
        ForEach(visiblePullRequests) { pullRequest in
          let link = sessionLinks[pullRequest.id]?.first
          PullRequestRow(
            presentation: PullRequestRowPresentation(
              pullRequest: pullRequest,
              checks: viewModel.checksByPullRequestID[pullRequest.id]
            ),
            tileColor: tileColor(pullRequest),
            sessionStatus: link.map {
              SessionStatusPresentation(status: $0.status, isPending: $0.isPending)
            },
            isSelected: viewModel.selectedPullRequestID == pullRequest.id,
            onSelect: { select(pullRequest) }
          )
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.bottom, DesignTokens.Spacing.sm)
    }
    .accessibilityIdentifier("reviews.list")
  }

  private func select(_ pullRequest: GitHubProjectPullRequest) {
    guard viewModel.selectedPullRequestID != pullRequest.id else { return }
    viewModel.selectedPullRequestID = pullRequest.id
    MainThreadStallMonitor.breadcrumb("reviews pr: \(pullRequest.repositoryName)#\(pullRequest.number)")
  }

  // MARK: - States

  private func state<Actions: View>(
    _ systemImage: String,
    title: String,
    description: String? = nil,
    isError: Bool = false,
    @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
  ) -> some View {
    WBEmptyState(
      systemImage: systemImage, isError: isError, title: title, description: description,
      actions: actions
    )
    .padding(.top, 64)
    .frame(maxWidth: .infinity)
  }

  /// gh missing, signed out, missing project scope, rate limited or failing.
  private func recoveryState(_ issue: GitHubReviewRecoveryIssue) -> some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      state("exclamationmark.triangle", title: issue.title, description: issue.message, isError: true) {
        Button(issue.primaryActionTitle) { perform(issue.primaryAction) }
          .buttonStyle(.wbPrimary)
        if let secondary = issue.secondaryAction, let title = issue.secondaryActionTitle {
          Button(title) { perform(secondary) }.buttonStyle(.wbSecondary)
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
  }

  private func perform(_ action: GitHubReviewRecoveryIssue.Action) {
    MainThreadStallMonitor.breadcrumb("reviews recovery: \(action)")
    if action == .retry {
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
      return
    }
    switch action {
    case .reconnectWithProjectAccess, .signIn:
      recoveryFeedback = "Finish signing in in Terminal and your browser, then choose Try again."
    case .installCLI:
      recoveryFeedback = "Install the GitHub CLI, then choose Try again."
    case .retry:
      break
    }
  }

  private func toggleReload() {
    if viewModel.isRefreshing {
      viewModel.cancelRefresh()
      reloadTask?.cancel()
      reloadTask = nil
      return
    }
    MainThreadStallMonitor.breadcrumb("reviews refresh")
    reloadTask = Task {
      await viewModel.reloadProjects()
      guard !Task.isCancelled, viewModel.recoveryIssue == nil else { return }
      await onRetry()
      reloadTask = nil
    }
  }
}
