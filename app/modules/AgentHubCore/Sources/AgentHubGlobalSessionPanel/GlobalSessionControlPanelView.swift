//
//  GlobalSessionControlPanelView.swift
//  AgentHub
//

import AgentHubCore
import AgentHubGitHub
import Foundation
import SwiftUI

// MARK: - GlobalSessionControlPanelView

private struct GlobalSessionCleanupDeletionConfirmation: Identifiable {
  let id = UUID()
  let suggestions: [GlobalSessionCleanupSuggestion]

  var message: String {
    suggestions.map { suggestion in
      let pullRequestText = suggestion.mergedPullRequestNumbers
        .map { "#\($0)" }
        .joined(separator: ", ")
      return
        "- \(suggestion.worktreeName) (merged PR \(pullRequestText))\n  \(suggestion.worktreePath)"
    }
    .joined(separator: "\n")
  }
}

private struct GlobalSessionCleanupDeletionFailure: Identifiable, Equatable {
  let id = UUID()
  let suggestion: GlobalSessionCleanupSuggestion
  let message: String
}

private struct GlobalSessionCleanupDeletionResult: Identifiable {
  let id = UUID()
  let deleted: [GlobalSessionCleanupSuggestion]
  let failures: [GlobalSessionCleanupDeletionFailure]

  var title: String {
    failures.isEmpty ? "Deleted Suggested Worktrees" : "Deleted Some Worktrees"
  }

  var message: String {
    var lines: [String] = []
    lines.append("\(deleted.count) deleted.")
    if !failures.isEmpty {
      lines.append("\(failures.count) failed:")
      lines.append(contentsOf: failures.map { "- \($0.suggestion.worktreeName): \($0.message)" })
    }
    return lines.joined(separator: "\n")
  }
}

public struct GlobalSessionControlPanelView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel

  let selectionRouter: GlobalSessionSelectionRouter
  let onClose: () -> Void
  let onSelectSession: () -> Void
  let onDisplayModeChange: (GlobalSessionControlPanelDisplayMode) -> Void
  let onCompactContentHeightChange: (CGFloat) -> Void
  private let defaults: UserDefaults
  private let displayModeToggleRelay: GlobalSessionPanelDisplayModeToggleRelay?

  @State private var gitHubStates: [String: GlobalSessionControlPanelGitHubState] = [:]
  @State private var selectedItemID: String?
  @State private var displayMode: GlobalSessionControlPanelDisplayMode
  @State private var deletionConfirmation: GlobalSessionCleanupDeletionConfirmation?
  @State private var deletionResult: GlobalSessionCleanupDeletionResult?
  @State private var isDeletingSuggestedWorktrees = false
  @FocusState private var isPanelFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    selectionRouter: GlobalSessionSelectionRouter,
    displayModeToggleRelay: GlobalSessionPanelDisplayModeToggleRelay? = nil,
    defaults: UserDefaults = .standard,
    onClose: @escaping () -> Void = {},
    onSelectSession: @escaping () -> Void = {},
    onDisplayModeChange: @escaping (GlobalSessionControlPanelDisplayMode) -> Void = { _ in },
    onCompactContentHeightChange: @escaping (CGFloat) -> Void = { _ in }
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.selectionRouter = selectionRouter
    self.displayModeToggleRelay = displayModeToggleRelay
    self.defaults = defaults
    self.onClose = onClose
    self.onSelectSession = onSelectSession
    self.onDisplayModeChange = onDisplayModeChange
    self.onCompactContentHeightChange = onCompactContentHeightChange
    _displayMode = State(initialValue: GlobalSessionControlPanelDisplayMode.load(from: defaults))
  }

  public var body: some View {
    ZStack(alignment: .top) {
      switch displayMode {
      case .regular:
        regularPanelContent
          .transition(.opacity)
      case .compact:
        compactPanelContent
          .background(
            GeometryReader { proxy in
              // Report the compact layout's intrinsic height so the AppKit
              // window can hug it instead of using a fixed (too-tall) size.
              Color.clear
                .onChange(of: proxy.size.height, initial: true) { _, height in
                  onCompactContentHeightChange(height)
                }
            }
          )
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.wbSurfaceRaised)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.container, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.container, style: .continuous)
        .strokeBorder(Color.wbBorderControl, lineWidth: 0.5)
    )
    .focusable()
    .focusEffectDisabled()
    .focused($isPanelFocused)
    .onKeyPress(.downArrow) { moveSelection(.down) }
    .onKeyPress(.upArrow) { moveSelection(.up) }
    .onKeyPress(.return) { activateSelectedItem() }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    .alert(item: $deletionConfirmation, content: deletionConfirmationAlert)
    .alert(item: $deletionResult, content: deletionResultAlert)
    .onAppear {
      revalidateSelection()
      isPanelFocused = true
    }
    .onChange(of: selectionItemIDs) { _, _ in
      revalidateSelection()
    }
    .onChange(of: displayMode) { _, _ in
      revalidateSelection()
    }
    .onChange(of: displayModeToggleRelay?.toggleRequestCount) { _, _ in
      toggleDisplayMode()
    }
  }

  // The window snaps to its new size in the AppKit presenter (no per-frame
  // relayout, no alpha blink); here we only cross-fade the content between
  // layouts so the swap reads as a clean dissolve rather than a flash.
  private var displayModeCrossfadeAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.18)
  }

  private var regularPanelContent: some View {
    VStack(spacing: 0) {
      header

      Rectangle()
        .fill(Color.wbBorderHairline)
        .frame(height: 1)

      panelContent
    }
  }

  private var panelContent: some View {
    primarySessionsContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var compactPanelContent: some View {
    // Even 8pt inset on all sides (matching the regular list) with a small,
    // balanced gap to the control bar — keeps the featured row's vertical
    // padding symmetric instead of jammed against the top.
    VStack(spacing: DesignTokens.Spacing.xsPlus) {
      compactFeaturedContent
      compactControlBar
    }
    .padding(DesignTokens.Inset.panel)
  }

  @ViewBuilder
  private var compactFeaturedContent: some View {
    if let compactFeaturedItem {
      // Show the full row content (including the worktree/root path lines) so the
      // featured session in compact mode matches a regular-mode row exactly.
      GlobalSessionControlPanelRow(
        item: compactFeaturedItem,
        isSelected: compactFeaturedItem.id == selectedItemID,
        isCleanupCandidate: cleanupCandidateIDs.contains(compactFeaturedItem.id),
        onSelect: { activate(compactFeaturedItem) },
        onGitHubStateChange: { state in
          updateGitHubState(state, for: compactFeaturedItem.id)
        }
      )
    } else {
      compactEmptyState
    }
  }

  private var compactControlBar: some View {
    ZStack {
      IconButton(systemImage: "chevron.down", isSmall: true, accessibilityLabel: "Expand sessions", action: expandPanel)
        .help("Expand")

      HStack {
        Spacer()

        IconButton(systemImage: "xmark", isSmall: true, accessibilityLabel: "Close", action: onClose)
          .help("Close")
      }
    }
  }

  @ViewBuilder
  private var primarySessionsContent: some View {
    if items.isEmpty {
      emptyState
    } else {
      sessionList
    }
  }

  private var sessionList: some View {
    let suggestions = cleanupSuggestions
    let candidateIDs = Set(suggestions.flatMap(\.sessionIDs))
    return ScrollViewReader { proxy in
      ScrollView(showsIndicators: true) {
        LazyVStack(spacing: DesignTokens.Spacing.xxs) {
          if !suggestions.isEmpty {
            GlobalSessionCleanupBanner(
              suggestions: suggestions,
              isDeleting: isDeletingSuggestedWorktrees,
              onDelete: {
                deletionConfirmation = GlobalSessionCleanupDeletionConfirmation(
                  suggestions: suggestions
                )
              }
            )
            .padding(.bottom, DesignTokens.Spacing.xs)
          }

          ForEach(items) { item in
            GlobalSessionControlPanelRow(
              item: item,
              isSelected: item.id == selectedItemID,
              isCleanupCandidate: candidateIDs.contains(item.id),
              onSelect: { activate(item) },
              onGitHubStateChange: { state in
                updateGitHubState(state, for: item.id)
              }
            )
            .id(item.id)
          }
        }
        .padding(DesignTokens.Inset.panel)
      }
      .onChange(of: selectedItemID) { _, newValue in
        guard displayMode == .regular else { return }
        guard let newValue else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
          proxy.scrollTo(newValue)
        }
      }
    }
  }

  private var items: [GlobalSessionControlPanelItem] {
    GlobalSessionControlPanelSnapshotBuilder.makeItems(
      claudePending: claudeViewModel.pendingHubSessions,
      codexPending: codexViewModel.pendingHubSessions,
      claudeMonitored: claudeViewModel.monitoredSessions,
      codexMonitored: codexViewModel.monitoredSessions,
      claudeCustomNames: claudeViewModel.sessionCustomNames,
      codexCustomNames: codexViewModel.sessionCustomNames,
      gitHubStates: gitHubStates
    )
  }

  private var compactFeaturedItem: GlobalSessionControlPanelItem? {
    GlobalSessionControlPanelCompactItemSelector.featuredItem(from: items)
  }

  private var selectionItems: [GlobalSessionControlPanelItem] {
    switch displayMode {
    case .regular:
      return items
    case .compact:
      return compactFeaturedItem.map { [$0] } ?? []
    }
  }

  private var selectionItemIDs: [String] {
    selectionItems.map(\.id)
  }

  private var cleanupSuggestions: [GlobalSessionCleanupSuggestion] {
    GlobalSessionCleanupSuggestionBuilder.makeSuggestions(
      items: items,
      repositories: cleanupRepositories
    )
  }

  private var cleanupRepositories: [SelectedRepository] {
    WorktreeModuleResolver.mergedRepositories(
      claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    )
  }

  // Item IDs whose worktree is a safe-to-delete cleanup candidate (merged PR and
  // quiet state). Used to flag individual rows, consistent with the banner.
  private var cleanupCandidateIDs: Set<String> {
    Set(cleanupSuggestions.flatMap(\.sessionIDs))
  }

  private var header: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Text("Sessions")
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)

      CountBadge(items.count)
        .accessibilityLabel("\(items.count) monitored")

      Spacer()

      KeyCaps(GlobalHotKey.sessionControlPanelDefault.displayString)

      IconButton(systemImage: "chevron.up", isSmall: true, accessibilityLabel: "Compact sessions", action: compactPanel)
        .help("Compact")

      IconButton(systemImage: "xmark", isSmall: true, accessibilityLabel: "Close", action: onClose)
        .help("Close")
    }
    .padding(.leading, DesignTokens.Spacing.md)
    .padding(.trailing, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .contentShape(Rectangle())
  }

  private var compactEmptyState: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      Image(systemName: "terminal")
        .font(.system(size: 13))
        .foregroundStyle(Color.wbTextSecondary)
        .frame(width: DesignTokens.Size.icon, height: DesignTokens.Size.icon)

      Text("No monitored sessions")
        .wbText(.body)
        .foregroundStyle(Color.wbTextPrimary)

      Spacer(minLength: DesignTokens.Spacing.sm)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.md)
  }

  private var emptyState: some View {
    WBEmptyState(
      systemImage: "terminal",
      title: "No monitored sessions",
      description: "Start or select sessions in Workbench to show them here."
    ) {
      EmptyView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func updateGitHubState(_ state: GlobalSessionControlPanelGitHubState?, for itemID: String)
  {
    if let state {
      gitHubStates[itemID] = state
    } else {
      gitHubStates.removeValue(forKey: itemID)
    }
  }

  private func compactPanel() {
    setDisplayMode(.compact)
  }

  private func expandPanel() {
    setDisplayMode(.regular)
  }

  private func setDisplayMode(_ mode: GlobalSessionControlPanelDisplayMode) {
    guard displayMode != mode else { return }
    mode.persist(to: defaults)

    // Snap the window to its new size immediately (the presenter resizes without
    // animating the frame), then cross-fade the content for a clean dissolve.
    onDisplayModeChange(mode)
    withAnimation(displayModeCrossfadeAnimation) {
      displayMode = mode
    }
  }

  private func toggleDisplayMode() {
    setDisplayMode(displayMode == .regular ? .compact : .regular)
  }

  private func moveSelection(_ direction: GlobalSessionListNavigationDirection) -> KeyPress.Result {
    guard !selectionItemIDs.isEmpty else { return .ignored }
    selectedItemID = GlobalSessionPanelNavigator.nextSelection(
      currentID: selectedItemID,
      direction: direction,
      itemIDs: selectionItemIDs
    )
    return .handled
  }

  private func activateSelectedItem() -> KeyPress.Result {
    guard
      let selectedItemID,
      let item = selectionItems.first(where: { $0.id == selectedItemID })
    else { return .ignored }
    activate(item)
    return .handled
  }

  private func activate(_ item: GlobalSessionControlPanelItem) {
    selectedItemID = item.id
    selectionRouter.select(
      providerKind: item.providerKind,
      sessionId: item.session.id,
      projectPath: item.session.projectPath,
      itemId: item.id,
      session: item.isPending ? nil : item.session
    )
    onSelectSession()
  }

  private func revalidateSelection() {
    selectedItemID = GlobalSessionPanelNavigator.validatedSelection(
      currentID: selectedItemID,
      itemIDs: selectionItemIDs
    )
  }

  private func deletionConfirmationAlert(_ confirmation: GlobalSessionCleanupDeletionConfirmation)
    -> Alert
  {
    Alert(
      title: Text("Delete Suggested Worktrees?"),
      message: Text(confirmation.message),
      primaryButton: .destructive(Text("Delete Worktrees")) {
        Task {
          await deleteSuggestedWorktrees(confirmation.suggestions)
        }
      },
      secondaryButton: .cancel()
    )
  }

  private func deletionResultAlert(_ result: GlobalSessionCleanupDeletionResult) -> Alert {
    Alert(
      title: Text(result.title),
      message: Text(result.message),
      dismissButton: .default(Text("OK"))
    )
  }

  private func deleteSuggestedWorktrees(_ suggestions: [GlobalSessionCleanupSuggestion]) async {
    guard !isDeletingSuggestedWorktrees else { return }
    isDeletingSuggestedWorktrees = true

    var deleted: [GlobalSessionCleanupSuggestion] = []
    var failures: [GlobalSessionCleanupDeletionFailure] = []

    for suggestion in suggestions {
      let viewModel = deletionViewModel(for: suggestion)
      let worktree =
        matchingWorktree(at: suggestion.worktreePath)
        ?? WorktreeBranch(
          name: suggestion.worktreeName,
          path: suggestion.worktreePath,
          isWorktree: true
        )
      let succeeded = await viewModel.deleteWorktree(worktree, force: false)

      if succeeded {
        deleted.append(suggestion)
        removeFromSidebars(worktreePath: suggestion.worktreePath)
      } else {
        failures.append(
          GlobalSessionCleanupDeletionFailure(
            suggestion: suggestion,
            message: viewModel.worktreeDeletionError?.message
              ?? "The worktree could not be deleted."
          ))
        viewModel.clearWorktreeDeletionError()
      }
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
    isDeletingSuggestedWorktrees = false
    deletionResult = GlobalSessionCleanupDeletionResult(deleted: deleted, failures: failures)
  }

  private func deletionViewModel(for suggestion: GlobalSessionCleanupSuggestion)
    -> CLISessionsViewModel
  {
    if containsWorktree(at: suggestion.worktreePath, in: claudeViewModel) {
      return claudeViewModel
    }
    if containsWorktree(at: suggestion.worktreePath, in: codexViewModel) {
      return codexViewModel
    }
    if suggestion.providerKinds.contains(.codex), !suggestion.providerKinds.contains(.claude) {
      return codexViewModel
    }
    return claudeViewModel
  }

  private func matchingWorktree(at path: String) -> WorktreeBranch? {
    for viewModel in [claudeViewModel, codexViewModel] {
      for repository in viewModel.selectedRepositories {
        if let worktree = repository.worktrees.first(where: {
          WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
        }) {
          return worktree
        }
      }
    }
    return nil
  }

  private func containsWorktree(at path: String, in viewModel: CLISessionsViewModel) -> Bool {
    viewModel.selectedRepositories.contains { repository in
      repository.worktrees.contains {
        WorktreeModuleResolver.normalizedDirectoryPath($0.path) == path
      }
    }
  }

  private func removeFromSidebars(worktreePath: String) {
    for viewModel in [claudeViewModel, codexViewModel] {
      viewModel.archiveMonitoredSessions(inWorktreePath: worktreePath)
      viewModel.forgetOwnedWorktreePath(worktreePath)
    }
  }
}

// MARK: - GlobalSessionControlPanelRow

private struct GlobalSessionCleanupBanner: View {
  let suggestions: [GlobalSessionCleanupSuggestion]
  let isDeleting: Bool
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      Image(systemName: "flag.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.wbStatusAttentionText)
        .frame(width: DesignTokens.Size.icon, height: DesignTokens.Size.icon)

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
        Text(title)
          .wbText(.bodyEmphasis)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)

        Text(summary)
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer(minLength: DesignTokens.Spacing.sm)

      Button(isDeleting ? "Deleting…" : "Delete", action: onDelete)
        .buttonStyle(WBDestructiveButtonStyle())
        .disabled(isDeleting)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      Color.wbStatusAttentionTint,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    )
  }

  private var title: String {
    let noun = suggestions.count == 1 ? "worktree" : "worktrees"
    return "\(suggestions.count) merged \(noun) can be deleted"
  }

  private var summary: String {
    let names = suggestions.prefix(2).map(\.worktreeName)
    let remaining = suggestions.count - names.count
    if remaining > 0 {
      return names.joined(separator: ", ") + " +\(remaining) more"
    }
    return names.joined(separator: ", ")
  }
}

private struct GlobalSessionControlPanelRow: View {
  let item: GlobalSessionControlPanelItem
  let isSelected: Bool
  var showsPathLines = true
  var isCleanupCandidate = false
  let onSelect: () -> Void
  let onGitHubStateChange: (GlobalSessionControlPanelGitHubState?) -> Void

  @State private var isHovered = false
  @State private var gitHubViewModel = SessionGitHubQuickAccessViewModel()
  @State private var resolvedRootPath: String?
  @Environment(\.agentHub) private var agentHub

  private var gitHubObservationTaskID: String {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: item.session.projectPath,
      branchName: item.session.branchName,
      linkedPullRequests: item.linkedPullRequests
    )
    return "\(item.id)|\(repositoryKey)|\(item.isPending)|\(agentHub != nil)"
  }

  private var gitHubSignature: String {
    let pullRequest = gitHubViewModel.currentBranchPR
    let prNumber = pullRequest?.number ?? 0
    let summary = gitHubViewModel.ciSummary
    return [
      "\(prNumber)",
      pullRequest?.state ?? "",
      pullRequest?.mergeable ?? "",
      pullRequest?.reviewDecision ?? "",
      "\(summary.overallStatus.rawValue)",
      "\(summary.passed)",
      "\(summary.failed)",
      "\(summary.pending)",
      "\(summary.total)",
      gitHubViewModel.blockers.map(\.rawValue).sorted().map(String.init).joined(separator: ","),
      "\(gitHubViewModel.observationState.isUnavailable)",
      "\(gitHubViewModel.observationState.isRefreshing)",
    ].joined(separator: "|")
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.smPlus) {
        StatusGlyph(status: item.status, isPending: item.isPending)
          .fixedSize()
          .padding(.top, 3)

        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          topLine
          detailLine
          gitHubLine
          if showsPathLines {
            pathLines
          }
        }

        Spacer(minLength: DesignTokens.Spacing.sm)

        Image(systemName: "arrow.up.forward")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(isHovered || isSelected ? Color.wbTextSecondary : Color.wbTextTertiary)
          .padding(.top, 3)
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .padding(.vertical, DesignTokens.Spacing.smPlus)
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
      .background(
        rowBackgroundColor,
        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .task(id: gitHubObservationTaskID) {
      await observeGitHubIfAvailable()
      publishGitHubState()
    }
    .task(id: item.session.projectPath) {
      await resolveRootPath()
    }
    .onDisappear {
      gitHubViewModel.stopPolling()
      onGitHubStateChange(nil)
    }
    .onChange(of: item.timestamp) { _, newValue in
      Task {
        await gitHubViewModel.notifySessionActivity(at: newValue)
      }
    }
    .onChange(of: gitHubSignature) { _, _ in
      publishGitHubState()
    }
  }

  private var topLine: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(item.displayName)
        .wbText(.bodyEmphasis)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(item.providerKind.rawValue)
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .fixedSize(horizontal: true, vertical: false)

      if isCleanupCandidate {
        cleanupBadge
      }

      Spacer(minLength: DesignTokens.Spacing.xs)

      Text(item.timestamp.timeAgoDisplay())
        .wbText(.callout)
        .foregroundStyle(Color.wbTextTertiary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var cleanupBadge: some View {
    Text("Cleanup")
      .wbText(.subheadline)
      .fontWeight(.medium)
      .foregroundStyle(Color.wbStatusAttentionText)
      .padding(.horizontal, DesignTokens.Spacing.xsPlus)
      .padding(.vertical, 1)
      .background(Color.wbStatusAttentionTint, in: Capsule())
      .fixedSize()
      .help("This worktree's PR is merged — safe to clean up")
  }

  private var detailLine: some View {
    HStack(spacing: DesignTokens.Spacing.xsPlus) {
      Text(statusPresentation.word)
        .wbText(.callout)
        .foregroundStyle(statusPresentation.textColor)
        .lineLimit(1)
        .truncationMode(.tail)

      Text("·")
        .wbText(.callout)
        .foregroundStyle(Color.wbTextTertiary)

      Text(projectText)
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var gitHubLine: some View {
    if let pullRequest = gitHubViewModel.currentBranchPR {
      HStack(spacing: DesignTokens.Spacing.xs) {
        Image(systemName: gitHubStatusIcon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(ciColor)
          .frame(width: DesignTokens.Size.iconSmall, height: DesignTokens.Size.iconSmall)

        Text("PR #\(pullRequest.number)")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)

        if pullRequest.stateKind == .merged {
          prStateBadge("Merged", text: Color.wbTextOnAccent, fill: Color.wbTileViolet)
        } else if pullRequest.stateKind == .closed {
          prStateBadge("Closed", text: Color.wbStatusErrorText, fill: Color.wbStatusErrorTint)
        }

        Text("·")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextTertiary)

        Text(ciText)
          .wbText(.callout)
          .foregroundStyle(ciColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .transition(.opacity)
    }
  }

  private func prStateBadge(_ title: String, text: Color, fill: Color) -> some View {
    Text(title)
      .wbText(.subheadline)
      .fontWeight(.medium)
      .foregroundStyle(text)
      .padding(.horizontal, DesignTokens.Spacing.xsPlus)
      .padding(.vertical, 1)
      .background(fill, in: Capsule())
      .fixedSize()
  }

  private var pathLines: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
      if item.session.isWorktree {
        pathRow(icon: "arrow.triangle.branch", label: "Worktree", path: item.session.projectPath)
      }
      pathRow(icon: "house", label: "Root", path: rootPath)
    }
  }

  private func pathRow(icon: String, label: String, path: String) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.wbTextTertiary)
        .frame(width: DesignTokens.Size.iconSmall, height: DesignTokens.Size.iconSmall)

      Text(displayPath(path))
        .wbText(.codeSmall)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .help("\(label): \(path)")
  }

  private var rootPath: String {
    resolvedRootPath ?? item.session.projectPath
  }

  private func displayPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  private func resolveRootPath() async {
    let path = item.session.projectPath
    let resolved = await Task.detached(priority: .utility) {
      GitWorktreeDetector.mainRepoPath(forWorktreeAt: path)
    }.value
    resolvedRootPath = resolved
  }

  private var statusPresentation: SessionStatusPresentation {
    SessionStatusPresentation(status: item.status, isPending: item.isPending)
  }

  private var rowBackgroundColor: Color {
    if isSelected { return .wbSurfaceSelected }
    if isHovered { return .wbSurfaceHover }
    return .clear
  }

  private var projectText: String {
    if let branchName = item.session.branchName, !branchName.isEmpty {
      return "\(item.session.projectName) · \(branchName)"
    }
    return item.session.projectName
  }

  private var ciColor: Color {
    if !gitHubViewModel.blockers.isEmpty { return .wbStatusErrorText }
    if gitHubViewModel.observationState.isUnavailable { return .wbStatusAttentionText }
    switch gitHubViewModel.ciSummary.overallStatus {
    case .success: return .wbStatusReadyText
    case .failure: return .wbStatusErrorText
    case .pending: return .wbStatusAttentionText
    case .none: return .wbTextSecondary
    }
  }

  private var ciText: String {
    if gitHubViewModel.observationState.isUnavailable {
      return gitHubViewModel.hasStaleObservation
        ? "Last known: \(gitHubStatusText)"
        : "GitHub unavailable"
    }
    return gitHubStatusText
  }

  private var gitHubStatusText: String {
    let blockers = gitHubViewModel.blockers.sorted { $0.rawValue < $1.rawValue }
    if blockers.count == 1, let blocker = blockers.first {
      return blocker.displayName
    }
    if blockers.count > 1 {
      return "\(blockers.count) PR blockers"
    }

    let summary = gitHubViewModel.ciSummary
    switch summary.overallStatus {
    case .success:
      return summary.total > 0 ? "CI passing \(summary.passed)/\(summary.total)" : "CI passing"
    case .failure:
      return summary.failed == 1 ? "1 check failing" : "\(summary.failed) checks failing"
    case .pending:
      return summary.pending == 1 ? "1 check pending" : "\(summary.pending) checks pending"
    case .none:
      // `.none` means the commit's check rollup is empty — i.e. no CI checks
      // exist for it, not that the status failed to load.
      return summary.total > 0 ? "Checks skipped" : "No checks"
    }
  }

  private var gitHubStatusIcon: String {
    if !gitHubViewModel.blockers.isEmpty {
      return "exclamationmark.triangle.fill"
    }
    if gitHubViewModel.observationState.isUnavailable {
      return "exclamationmark.triangle.fill"
    }
    return gitHubViewModel.ciSummary.overallStatus.icon
  }

  private func observeGitHubIfAvailable() async {
    guard !item.isPending, let observationService = agentHub?.gitHubPRObservationService else {
      gitHubViewModel.stopPolling()
      onGitHubStateChange(nil)
      return
    }

    await gitHubViewModel.load(
      projectPath: item.session.projectPath,
      branchName: item.session.branchName,
      linkedPullRequests: item.linkedPullRequests,
      observationService: observationService,
      refreshOnSubscribe: false,
      recordInitialActivity: false,
      forceRefreshLinkedPullRequest: !item.linkedPullRequests.isEmpty
    )
    await gitHubViewModel.notifySessionActivity(at: item.timestamp)
  }

  private func publishGitHubState() {
    guard let pullRequest = gitHubViewModel.currentBranchPR else {
      onGitHubStateChange(nil)
      return
    }

    onGitHubStateChange(
      GlobalSessionControlPanelGitHubState(
        hasPullRequest: true,
        ciStatus: gitHubViewModel.ciSummary.overallStatus,
        isRefreshing: gitHubViewModel.observationState.isRefreshing,
        pullRequestNumber: pullRequest.number,
        pullRequestState: pullRequest.stateKind,
        pullRequestMergeability: pullRequest.mergeabilityKind,
        blockers: gitHubViewModel.blockers
      ))
  }
}
