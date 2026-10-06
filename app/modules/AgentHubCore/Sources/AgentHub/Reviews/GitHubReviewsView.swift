//
//  GitHubReviewsView.swift
//  AgentHub
//

import AgentHubGitHub
import AppKit
import SwiftUI

struct GitHubReviewSessionCommandContext: Identifiable {
  let pullRequest: GitHubProjectPullRequest
  let link: GitHubReviewSessionLink

  var id: String { "\(pullRequest.id)-\(link.id)" }
}

private struct GitHubReviewSessionCommandFeedback: Equatable {
  let message: String
  let isError: Bool
}

struct GitHubReviewsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @Bindable private var viewModel: GitHubReviewsViewModel
  @Bindable private var claudeSessionsViewModel: CLISessionsViewModel
  @Bindable private var codexSessionsViewModel: CLISessionsViewModel
  @Bindable private var promptLibrary: GitHubPromptLibrary
  private let onReview:
    (GitHubProjectPullRequest, SessionProviderKind, GitHubPromptTemplate) async -> Void
  private let onOpenSession: (GitHubReviewSessionLink) -> Void
  @State private var recoveryFeedbackMessage: String?
  @State private var recoveryFeedbackIsError = false
  @State private var searchText = ""
  @State private var reloadTask: Task<Void, Never>?
  @State private var sessionCommandContext: GitHubReviewSessionCommandContext?
  @State private var sessionCommandFeedback: GitHubReviewSessionCommandFeedback?
  @State private var sessionCommandFeedbackTask: Task<Void, Never>?
  @State private var sortOrder = [
    KeyPathComparator(\GitHubReviewTableRow.prioritySortValue, order: .forward),
    KeyPathComparator(\GitHubReviewTableRow.updatedSortValue, order: .forward),
  ]

  init(
    viewModel: GitHubReviewsViewModel,
    claudeSessionsViewModel: CLISessionsViewModel,
    codexSessionsViewModel: CLISessionsViewModel,
    promptLibrary: GitHubPromptLibrary = .shared,
    onReview:
      @escaping (
        GitHubProjectPullRequest,
        SessionProviderKind,
        GitHubPromptTemplate
      ) async -> Void,
    onOpenSession: @escaping (GitHubReviewSessionLink) -> Void
  ) {
    self.viewModel = viewModel
    self.claudeSessionsViewModel = claudeSessionsViewModel
    self.codexSessionsViewModel = codexSessionsViewModel
    self.promptLibrary = promptLibrary
    self.onReview = onReview
    self.onOpenSession = onOpenSession
  }

  var body: some View {
    NavigationSplitView {
      reviewSidebar
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      reviewQueue
    }
    .navigationSplitViewStyle(.balanced)
    .tint(Color.brandPrimary(from: runtimeTheme))
    .background(workspaceBackground.ignoresSafeArea())
    .task {
      await viewModel.load()
      await recoverAndRestoreReviewSessions()
    }
    .sheet(item: $sessionCommandContext) { context in
      GitHubReviewSessionCommandSheet(
        context: context,
        onCancel: { sessionCommandContext = nil },
        onSend: { command in
          sessionCommandContext = nil
          sendCustomCommand(command, context: context)
        }
      )
    }
    .onDisappear {
      sessionCommandFeedbackTask?.cancel()
    }
  }

  private var reviewSidebar: some View {
    VStack(spacing: 0) {
      sidebarHeader
      Divider()
      sidebarControls
      Spacer(minLength: 0)
      Divider()
      sidebarFooter
    }
    .background(panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Pull request review filters")
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.md) {
        VStack(alignment: .leading, spacing: 2) {
          Text("PULL REQUEST REVIEWS")
            .font(.geist(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Text("From a saved GitHub Project view")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if viewModel.isRefreshing {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          toggleRefresh()
        } label: {
          Image(systemName: viewModel.isRefreshing ? "xmark.circle" : "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help(
          viewModel.isRefreshing ? "Stop refreshing" : "Reload GitHub Projects and pull requests"
        )
        .accessibilityLabel(
          viewModel.isRefreshing
            ? "Stop refreshing GitHub review queue" : "Reload GitHub review queue"
        )
      }
    }
    .padding(DesignTokens.Spacing.md)
  }

  private var sidebarControls: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("PROJECT")
          .font(.geist(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
        Picker("Project", selection: projectBinding) {
          if viewModel.projects.isEmpty {
            Text("No projects available").tag(String?.none)
          } else {
            ForEach(viewModel.projects) { project in
              Text(project.displayName).tag(Optional(project.id))
            }
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
      }

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("VIEW")
          .font(.geist(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
        Picker("View", selection: viewBinding) {
          if viewModel.availableViews.isEmpty {
            Text("No views available").tag(String?.none)
          } else {
            ForEach(viewModel.availableViews) { view in
              Text(view.name).tag(Optional(view.id))
            }
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
      }

      if let project = viewModel.selectedProject,
        let url = URL(string: project.url)
      {
        Link(destination: url) {
          Label("Open project", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
      }

      if !viewModel.activeFilter.isEmpty {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          Text("FILTER")
            .font(.geist(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
          Text(viewModel.activeFilter)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(5)
            .textSelection(.enabled)
        }
      }

      if let errorMessage = viewModel.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.secondaryCaption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let recoveryIssue = viewModel.recoveryIssue {
        sidebarRecoveryView(recoveryIssue)
      }

      if let sessionLinkErrorMessage = viewModel.sessionLinkErrorMessage {
        Label(sessionLinkErrorMessage, systemImage: "externaldrive.badge.exclamationmark")
          .font(.secondaryCaption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(DesignTokens.Spacing.md)
  }

  private var sidebarFooter: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Label("\(viewModel.pullRequests.count) pull requests", systemImage: "arrow.triangle.pull")
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
      if viewModel.isShowingCachedPullRequests {
        Text("·")
          .foregroundStyle(.tertiary)
        Label("Saved locally", systemImage: "internaldrive")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(DesignTokens.Spacing.md)
  }

  private var reviewQueue: some View {
    VStack(spacing: 0) {
      queueHeader
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var queueHeader: some View {
    HStack(spacing: DesignTokens.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(viewModel.selectedView?.name ?? "Code review")
          .font(.primaryDefault)
        Text(viewModel.selectedProject?.displayName ?? "Select a GitHub Project view")
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let sessionCommandFeedback {
        Label(
          sessionCommandFeedback.message,
          systemImage: sessionCommandFeedback.isError
            ? "exclamationmark.triangle" : "paperplane.fill"
        )
        .font(.secondaryCaption)
        .foregroundStyle(sessionCommandFeedback.isError ? .red : .secondary)
        .lineLimit(1)
        .transition(.opacity)
      }
      Button {
        applySuggestedOrder()
      } label: {
        Label("Suggested order", systemImage: "list.number")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help("Urgent pull requests first, then the least recently updated")
      reviewSearchField
      Text(reviewCountLabel)
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(height: AgentHubLayout.topBarHeight)
  }

  private var reviewSearchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField("Search pull requests", text: $searchText)
        .textFieldStyle(.plain)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 8)
    .frame(width: 230, height: 28)
    .background(Color.themedControlBackground(theme: runtimeTheme))
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
  }

  @ViewBuilder
  private var content: some View {
    if let recoveryIssue = viewModel.recoveryIssue, viewModel.pullRequests.isEmpty {
      recoveryContent(recoveryIssue)
    } else if viewModel.isLoadingProjects, viewModel.projects.isEmpty {
      ContentUnavailableView {
        Label("Loading GitHub Projects", systemImage: "rectangle.3.group")
      } description: {
        Text("Reading projects and saved views through your GitHub CLI login.")
      }
    } else if viewModel.selectedProject == nil {
      ContentUnavailableView {
        Label("No GitHub Projects found", systemImage: "rectangle.3.group")
      } description: {
        Text("Make sure `gh` is authenticated with the `project` scope.")
      }
    } else if viewModel.selectedView == nil {
      ContentUnavailableView {
        Label("No project view selected", systemImage: "line.3.horizontal.decrease.circle")
      } description: {
        Text("Choose a saved view whose filter describes the review queue.")
      }
    } else if viewModel.isLoadingPullRequests, viewModel.pullRequests.isEmpty {
      ContentUnavailableView {
        Label("Loading review queue", systemImage: "arrow.triangle.pull")
      } description: {
        Text("Applying the selected project view filter.")
      }
    } else if viewModel.pullRequests.isEmpty {
      ContentUnavailableView(
        "No pull requests to review",
        systemImage: "checkmark.circle",
        description: Text("The selected GitHub Project view contains no matching non-draft PRs.")
      )
    } else {
      pullRequestTable
    }
  }

  private func sidebarRecoveryView(_ issue: GitHubReviewRecoveryIssue) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      Label(issue.title, systemImage: recoveryIcon(for: issue.kind))
        .font(.geist(size: 11, weight: .semibold))

      Text(issue.message)
        .font(.secondaryCaption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      recoveryButtons(for: issue, compact: true)

      recoveryFeedback
    }
    .padding(DesignTokens.Spacing.sm)
    .background(panelBackground.opacity(0.88))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(issue.title)
  }

  private func recoveryContent(_ issue: GitHubReviewRecoveryIssue) -> some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      ContentUnavailableView {
        Label(issue.title, systemImage: recoveryIcon(for: issue.kind))
      } description: {
        Text(issue.message)
      } actions: {
        recoveryButtons(for: issue, compact: false)
      }

      recoveryFeedback

      if let technicalDetails = issue.technicalDetails, !technicalDetails.isEmpty {
        DisclosureGroup("Technical details") {
          ScrollView {
            Text(technicalDetails)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, DesignTokens.Spacing.xs)
          }
          .frame(maxHeight: 150)
        }
        .font(.secondaryCaption)
        .frame(maxWidth: 560)
      }
    }
    .padding(DesignTokens.Spacing.lg)
  }

  @ViewBuilder
  private func recoveryButtons(
    for issue: GitHubReviewRecoveryIssue,
    compact: Bool
  ) -> some View {
    let layout =
      compact
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(
        HStackLayout(spacing: DesignTokens.Spacing.sm)
      )

    layout {
      Button(issue.primaryActionTitle) {
        performRecoveryAction(issue.primaryAction)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)

      if let secondaryAction = issue.secondaryAction,
        let secondaryTitle = issue.secondaryActionTitle
      {
        Button(secondaryTitle) {
          performRecoveryAction(secondaryAction)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private var recoveryFeedback: some View {
    if let recoveryFeedbackMessage {
      Label(
        recoveryFeedbackMessage,
        systemImage: recoveryFeedbackIsError ? "exclamationmark.triangle" : "info.circle"
      )
      .font(.secondaryCaption)
      .foregroundStyle(recoveryFeedbackIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: 560, alignment: .leading)
    }
  }

  private func performRecoveryAction(_ action: GitHubReviewRecoveryIssue.Action) {
    if action == .retry {
      recoveryFeedbackMessage = nil
      Task {
        await viewModel.reloadProjects()
        guard viewModel.recoveryIssue == nil else { return }
        await recoverAndRestoreReviewSessions()
      }
      return
    }

    if let error = GitHubAuthenticationRecoveryLauncher.perform(action) {
      recoveryFeedbackIsError = true
      recoveryFeedbackMessage = error.localizedDescription
      return
    }

    recoveryFeedbackIsError = false
    switch action {
    case .reconnectWithProjectAccess, .signIn:
      recoveryFeedbackMessage =
        "Finish the GitHub authorization in Terminal and your browser, then choose Try again."
    case .installCLI:
      recoveryFeedbackMessage =
        "The GitHub CLI website was opened. Install it, then choose Try again."
    case .retry:
      break
    }
  }

  private func toggleRefresh() {
    if viewModel.isRefreshing {
      viewModel.cancelRefresh()
      reloadTask?.cancel()
      reloadTask = nil
      return
    }

    reloadTask = Task {
      await viewModel.reloadProjects()
      guard !Task.isCancelled, viewModel.recoveryIssue == nil else { return }
      await recoverAndRestoreReviewSessions()
      reloadTask = nil
    }
  }

  private func recoveryIcon(for kind: GitHubReviewRecoveryIssue.Kind) -> String {
    switch kind {
    case .projectPermissionRequired:
      return "person.badge.key"
    case .authenticationRequired:
      return "link.badge.plus"
    case .cliNotInstalled:
      return "terminal"
    case .requestFailed:
      return "exclamationmark.triangle"
    }
  }

  private var pullRequestTable: some View {
    let inventories = reviewSessionInventories

    return Table(sortedReviewRows(inventories: inventories), sortOrder: $sortOrder) {
      TableColumn("Pull request", value: \.title) { row in
        let pullRequest = row.pullRequest
        VStack(alignment: .leading, spacing: 2) {
          Link(pullRequest.title, destination: URL(string: pullRequest.url)!)
            .font(.primaryDefault)
            .lineLimit(2)
          Text("#\(pullRequest.number)")
            .font(.secondaryCaption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
      }
      .width(min: 320, ideal: 520)

      TableColumn("Status", value: \.status) { row in
        statusCell(row.pullRequest.projectStatus)
      }
      .width(min: 105, ideal: 135)

      TableColumn("Priority", value: \.prioritySortValue) { row in
        priorityCell(row.pullRequest.projectPriority)
      }
      .width(min: 90, ideal: 120)

      TableColumn("Repository", value: \.repository) { row in
        let pullRequest = row.pullRequest
        Text(pullRequest.repositoryNameWithOwner)
          .font(.secondaryDefault)
          .lineLimit(1)
      }
      .width(min: 190, ideal: 240)

      TableColumn("Author", value: \.author) { row in
        let pullRequest = row.pullRequest
        Text(pullRequest.authorLogin.map { "@\($0)" } ?? "Unknown")
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
      }
      .width(min: 100, ideal: 140)

      TableColumn("Updated", value: \.updatedSortValue) { row in
        let pullRequest = row.pullRequest
        if let updatedAt = pullRequest.updatedAt {
          Text(updatedAt, style: .relative)
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        } else {
          Text("Unknown")
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 80, ideal: 110)

      TableColumn("Session", value: \.sessionSortValue) { row in
        reviewSessionsCell(row.sessionLinks, pullRequest: row.pullRequest)
      }
      .width(min: 190, ideal: 240)

      TableColumn("Review") { pullRequest in
        let pullRequest = pullRequest.pullRequest
        HStack(spacing: DesignTokens.Spacing.xs) {
          promptMenu(provider: .codex, pullRequest: pullRequest)
          promptMenu(provider: .claude, pullRequest: pullRequest)
        }
      }
      .width(min: 145, ideal: 160)
    }
    .scrollContentBackground(.hidden)
    .background(workspaceBackground)
  }

  private var workspaceBackground: Color {
    Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
  }

  private var panelBackground: Color {
    Color.themedPanelBackground(for: colorScheme, theme: runtimeTheme)
  }

  private func promptMenu(
    provider: SessionProviderKind,
    pullRequest: GitHubProjectPullRequest
  ) -> some View {
    Menu {
      ForEach(promptLibrary.templates) { template in
        Button(template.name) {
          Task { await onReview(pullRequest, provider, template) }
        }
      }
    } label: {
      Text(provider.rawValue)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Choose a prompt to run with \(provider.rawValue)")
  }

  private func sortedReviewRows(
    inventories: [GitHubReviewSessionInventory]
  ) -> [GitHubReviewTableRow] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let rows = viewModel.pullRequests.map { pullRequest in
      GitHubReviewTableRow(
        pullRequest: pullRequest,
        sessionLinks: GitHubReviewSessionLinker.links(
          for: pullRequest,
          launches: viewModel.reviewSessionLaunches(for: pullRequest),
          inventories: inventories
        )
      )
    }
    let filtered = rows.filter { row in
      guard !query.isEmpty else { return true }
      return row.title.localizedCaseInsensitiveContains(query)
        || String(row.pullRequest.number).localizedCaseInsensitiveContains(query)
        || row.repository.localizedCaseInsensitiveContains(query)
        || row.author.localizedCaseInsensitiveContains(query)
        || row.status.localizedCaseInsensitiveContains(query)
        || row.priority.localizedCaseInsensitiveContains(query)
        || row.sessionSearchText.localizedCaseInsensitiveContains(query)
    }
    return filtered.sorted(using: sortOrder)
  }

  private var reviewCountLabel: String {
    let total = viewModel.pullRequests.count
    guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "\(total) pull requests"
    }
    let visible = sortedReviewRows(inventories: reviewSessionInventories).count
    return "\(visible) of \(total) pull requests"
  }

  @ViewBuilder
  private func statusCell(_ status: String?) -> some View {
    if let status, !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Text(status)
        .font(.secondaryDefault)
        .lineLimit(1)
        .help(status)
    } else {
      Text("Not set")
        .font(.secondaryDefault)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func priorityCell(_ priority: String?) -> some View {
    if let priority, !priority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Label(
        priority,
        systemImage: GitHubReviewRecommendation.isUrgent(priority)
          ? "exclamationmark.circle.fill" : "flag"
      )
      .font(.secondaryDefault)
      .foregroundStyle(
        GitHubReviewRecommendation.isUrgent(priority)
          ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
      )
      .lineLimit(1)
    } else {
      Text("Not set")
        .font(.secondaryDefault)
        .foregroundStyle(.tertiary)
    }
  }

  private func applySuggestedOrder() {
    sortOrder = [
      KeyPathComparator(\GitHubReviewTableRow.prioritySortValue, order: .forward),
      KeyPathComparator(\GitHubReviewTableRow.updatedSortValue, order: .forward),
    ]
  }

  @ViewBuilder
  private func reviewSessionsCell(
    _ links: [GitHubReviewSessionLink],
    pullRequest: GitHubProjectPullRequest
  ) -> some View {
    if links.isEmpty {
      Text("No linked session")
        .font(.secondaryCaption)
        .foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        ForEach(links) { link in
          HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
              onOpenSession(link)
            } label: {
              HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: link.isPending ? "hourglass" : "terminal")
                  .foregroundStyle(link.isPending ? .secondary : .primary)

                VStack(alignment: .leading, spacing: 1) {
                  Text("\(link.provider.rawValue) · \(link.displayName)")
                    .font(.secondaryDefault)
                    .lineLimit(1)
                  HStack(spacing: 3) {
                    Text(link.statusText)
                    Text("·")
                    Text(link.session.lastActivityAt, style: .relative)
                  }
                  .font(.secondaryCaption)
                  .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                  .font(.system(size: 9, weight: .semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(link.provider.rawValue) session \(link.displayName)")
            .accessibilityLabel(
              "Open \(link.provider.rawValue) session \(link.displayName), \(link.statusText)"
            )

            if canSendCommand(to: link) {
              Menu {
                Button("Pull & review again") {
                  sendPullAndReviewAgain(to: link, pullRequest: pullRequest)
                }

                Button("Send command…") {
                  sessionCommandContext = GitHubReviewSessionCommandContext(
                    pullRequest: pullRequest,
                    link: link
                  )
                }
              } label: {
                Image(systemName: "paperplane")
                  .frame(width: 20, height: 20)
                  .contentShape(Rectangle())
              }
              .menuStyle(.borderlessButton)
              .menuIndicator(.hidden)
              .fixedSize()
              .help("Send a follow-up command to this open session")
              .accessibilityLabel(
                "Send command to \(link.provider.rawValue) session \(link.displayName)"
              )
            }
          }
        }
      }
      .padding(.vertical, DesignTokens.Spacing.xs)
    }
  }

  private func canSendCommand(to link: GitHubReviewSessionLink) -> Bool {
    GitHubReviewSessionCommandPolicy.canSend(isPending: link.isPending)
  }

  private func sessionsViewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    provider == .claude ? claudeSessionsViewModel : codexSessionsViewModel
  }

  private func sendPullAndReviewAgain(
    to link: GitHubReviewSessionLink,
    pullRequest: GitHubProjectPullRequest
  ) {
    sendCommand(
      GitHubReviewFollowUpPromptBuilder.pullAndReviewAgain(pullRequest),
      to: link
    )
  }

  private func sendCustomCommand(
    _ command: String,
    context: GitHubReviewSessionCommandContext
  ) {
    guard
      let prompt = GitHubReviewFollowUpPromptBuilder.custom(
        command,
        pullRequest: context.pullRequest
      )
    else { return }
    sendCommand(prompt, to: context.link)
  }

  private func sendCommand(_ prompt: String, to link: GitHubReviewSessionLink) {
    guard canSendCommand(to: link) else {
      showSessionCommandFeedback(
        "Session is still starting",
        isError: true
      )
      return
    }

    let didSend = sessionsViewModel(for: link.provider).sendAutomatedPrompt(
      to: link.session,
      prompt: prompt
    )
    showSessionCommandFeedback(
      didSend ? "Sent to \(link.provider.rawValue)" : "Could not send command",
      isError: !didSend
    )
  }

  private func showSessionCommandFeedback(_ message: String, isError: Bool) {
    sessionCommandFeedbackTask?.cancel()
    withAnimation(.easeInOut(duration: 0.15)) {
      sessionCommandFeedback = GitHubReviewSessionCommandFeedback(
        message: message,
        isError: isError
      )
    }
    sessionCommandFeedbackTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.15)) {
        sessionCommandFeedback = nil
      }
    }
  }

  private var reviewSessionInventories: [GitHubReviewSessionInventory] {
    [
      GitHubReviewSessionInventory(
        provider: .claude,
        sessions: claudeSessionsViewModel.allSessions,
        pendingSessions: claudeSessionsViewModel.pendingHubSessions,
        resolvedPendingSessionIDs: claudeSessionsViewModel.resolvedPendingSessionHistory,
        customNames: claudeSessionsViewModel.sessionCustomNames,
        statuses: claudeSessionsViewModel.sessionStatuses
      ),
      GitHubReviewSessionInventory(
        provider: .codex,
        sessions: codexSessionsViewModel.allSessions,
        pendingSessions: codexSessionsViewModel.pendingHubSessions,
        resolvedPendingSessionIDs: codexSessionsViewModel.resolvedPendingSessionHistory,
        customNames: codexSessionsViewModel.sessionCustomNames,
        statuses: codexSessionsViewModel.sessionStatuses
      ),
    ]
  }

  private func recoverAndRestoreReviewSessions() async {
    await viewModel.resolveReviewLaunches(
      claudeSessionsViewModel.resolvedPendingSessionHistory,
      provider: .claude
    )
    await viewModel.resolveReviewLaunches(
      codexSessionsViewModel.resolvedPendingSessionHistory,
      provider: .codex
    )
    applyReviewSessionTitles()

    if viewModel.shouldRecoverLegacySessionLinks {
      async let claudeResults = claudeSessionsViewModel.githubReviewSessionSearchResults()
      async let codexResults = codexSessionsViewModel.githubReviewSessionSearchResults()
      let (resolvedClaudeResults, resolvedCodexResults) = await (claudeResults, codexResults)

      await viewModel.recoverReviewSessions(
        provider: .claude,
        searchResults: resolvedClaudeResults
      )
      await viewModel.recoverReviewSessions(
        provider: .codex,
        searchResults: resolvedCodexResults
      )
      viewModel.finishLegacySessionRecovery()
    }

    let references = viewModel.linkedSessionReferences
    async let restoreClaude: Void = claudeSessionsViewModel.restoreWorkspaceSessions(references)
    async let restoreCodex: Void = codexSessionsViewModel.restoreWorkspaceSessions(references)
    _ = await (restoreClaude, restoreCodex)
  }

  private func applyReviewSessionTitles() {
    for (sessionID, title) in viewModel.linkedSessionTitles(provider: .claude) {
      claudeSessionsViewModel.setCustomName(title, forSessionId: sessionID)
    }
    for (sessionID, title) in viewModel.linkedSessionTitles(provider: .codex) {
      codexSessionsViewModel.setCustomName(title, forSessionId: sessionID)
    }
  }

  private var projectBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedProjectID },
      set: { id in
        if let id { viewModel.selectProject(id: id) }
      }
    )
  }

  private var viewBinding: Binding<String?> {
    Binding(
      get: { viewModel.selectedViewID },
      set: { id in
        if let id { viewModel.selectView(id: id) }
      }
    )
  }
}

private struct GitHubReviewTableRow: Identifiable {
  let pullRequest: GitHubProjectPullRequest
  let sessionLinks: [GitHubReviewSessionLink]

  var id: String { pullRequest.id }
  var title: String { pullRequest.title }
  var repository: String { pullRequest.repositoryNameWithOwner }
  var author: String { pullRequest.authorLogin ?? "" }
  var status: String { pullRequest.projectStatus ?? "" }
  var priority: String { pullRequest.projectPriority ?? "" }
  var prioritySortValue: Int {
    GitHubReviewRecommendation.priorityRank(pullRequest.projectPriority)
  }
  var updatedSortValue: TimeInterval { pullRequest.updatedAt?.timeIntervalSince1970 ?? 0 }
  var sessionSortValue: String { sessionLinks.first?.displayName ?? "" }
  var sessionSearchText: String {
    sessionLinks
      .map { "\($0.provider.rawValue) \($0.displayName) \($0.statusText)" }
      .joined(separator: " ")
  }
}
