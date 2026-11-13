//
//  SessionNavigationModel.swift
//  AgentHub
//
//  Navigation state extracted from MultiProviderSessionsListView so both the
//  legacy and new shell can share selection, history and router consumption.
//

import AgentHubGitHub
import Foundation
import SwiftUI

/// Holds the primary session selection, module landing, workspace focus,
/// workflow comparison state, and session history navigation. Shared between
/// the legacy `MultiProviderSessionsListView` and the new shell.
@MainActor
@Observable
final class SessionNavigationModel {
  // MARK: - Selection State

  /// The id of the session row shown in the detail pane.
  var primarySessionId: String?

  /// When set, the detail pane shows the module landing page instead of a
  /// session card.
  var selectedModuleLandingPath: String?

  /// When set, the detail pane shows the workspace instead of a session card.
  var selectedWorkspaceID: String?

  /// Tracks the scroll-to target after programmatic selection changes.
  var scrollToSessionId: String?

  // MARK: - Workflow Comparison

  var workflowComparisonState = WorkflowComparisonPresentationState()

  // MARK: - GitHub Refresh Scheduling

  /// True while a batch GitHub refresh is running.
  var isRefreshingGitHubStates = false

  /// Set once after the first `scheduleInitialGitHubStateRefreshIfNeeded` call.
  var didScheduleInitialGitHubStateRefresh = false

  // MARK: - Init

  init() {}

  // MARK: - Transient State

  /// Resets navigation state that should not survive the Sessions view leaving
  /// the tree. Selection (`primarySessionId`, `selectedWorkspaceID`,
  /// `selectedModuleLandingPath`) intentionally persists within the window so a
  /// tab-switch round-trip keeps the selection.
  func clearTransientNavigation() {
    scrollToSessionId = nil
    didScheduleInitialGitHubStateRefresh = false
  }

  // MARK: - History Navigation

  /// Moves the primary selection forward or backward through the navigable
  /// session list. Wraps at both ends.
  func navigateSessionHistory(
    direction: SidebarSessionNavigationDirection,
    navigableIDs: [String]
  ) {
    guard
      let nextID = SidebarSessionOrdering.nextID(
        in: navigableIDs,
        currentID: primarySessionId,
        direction: direction
      )
    else {
      return
    }

    if nextID == workflowComparisonState.retainedComparison?.implementation.itemID {
      reopenWorkflowComparison()
      return
    }

    MainThreadStallMonitor.breadcrumb("nav: history \(direction) -> \(nextID.prefix(20))")
    workflowComparisonState.showStandaloneContent()
    selectedModuleLandingPath = nil
    primarySessionId = nextID
    scrollToSessionId = nextID
  }

  // MARK: - Pending → Resolved Swap

  /// When a pending session resolves to a real session id, update the primary
  /// selection so the detail pane follows the same session.
  func handleResolvedSessions(
    _ resolutions: [UUID: String],
    provider: SessionProviderKind,
    viewModel: CLISessionsViewModel
  ) {
    guard let currentPrimary = primarySessionId else { return }
    let providerPrefix = "pending-\(provider.rawValue.lowercased())-"
    guard currentPrimary.hasPrefix(providerPrefix) else { return }
    let uuidString = String(currentPrimary.dropFirst(providerPrefix.count))
    guard let pendingUUID = UUID(uuidString: uuidString),
      let realSessionId = resolutions[pendingUUID]
    else { return }
    let newPrimaryId = "\(provider.rawValue.lowercased())-\(realSessionId)"
    AppLogger.session.info(
      "[PrimarySelection] Resolved: \(currentPrimary.prefix(20), privacy: .public) -> \(newPrimaryId.prefix(20), privacy: .public)"
    )
    primarySessionId = newPrimaryId
    viewModel.resolvedPendingSessions.removeValue(forKey: pendingUUID)
  }

  // MARK: - Router Consumption

  /// Consumes a pending `GlobalSessionSelectionRouter.selectionRequest`, if any,
  /// and updates the selection state. Returns true if a request was consumed.
  @discardableResult
  func consumeGlobalSessionSelectionIfNeeded(
    router: GlobalSessionSelectionRouter?,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    workspaceViewModel: AgentWorkspacesViewModel,
    selectedSessionItems: () -> [SessionItemSnapshot],
    colorScheme: ColorScheme,
    setAuxiliaryShellVisible: (Bool) -> Void,
    selectedProviderRawSetter: (String) -> Void
  ) -> Bool {
    guard let router, let request = router.selectionRequest else {
      return false
    }

    let viewModel = request.providerKind == .claude ? claudeViewModel : codexViewModel
    if let session = request.session,
      session.id == request.sessionId,
      !viewModel.isMonitoring(sessionId: session.id)
    {
      viewModel.startMonitoring(session: session)
    }
    if request.providerKind == .codex {
      viewModel.ensureLiveMonitoring(sessionId: request.sessionId)
    }

    // Evaluate after monitoring starts so newly-monitored sessions are visible.
    guard let item = selectedSessionItems().first(where: { $0.id == request.itemId }) else {
      return false
    }

    selectedModuleLandingPath = nil
    selectedProviderRawSetter(request.providerKind.rawValue)
    workflowComparisonState.showStandaloneContent()
    if !item.isPending,
      let workspaceID = workspaceViewModel.focusWorkspaceSession(
        provider: item.providerKind,
        sessionId: item.sessionId,
        isDark: colorScheme == .dark
      )
    {
      primarySessionId = nil
      selectedWorkspaceID = workspaceID
      setAuxiliaryShellVisible(false)
    } else {
      selectedWorkspaceID = nil
      primarySessionId = request.itemId
    }
    scrollToSessionId = request.itemId
    MainThreadStallMonitor.breadcrumb("nav: consumed selection \(request.itemId.prefix(20))")
    router.markConsumed(request)
    return true
  }

  /// Consumes a pending `GlobalSessionSelectionRouter.comparisonRequest`, if
  /// any, and updates selection and comparison state.
  @discardableResult
  func consumeGlobalWorkflowComparisonIfNeeded(
    router: GlobalSessionSelectionRouter?,
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    availableItemIDs: () -> Set<String>
  ) -> Bool {
    guard let router,
      let request = router.comparisonRequest ?? router.activeComparison
    else {
      return false
    }

    if workflowComparisonState.retainedComparison?.id == request.id {
      if router.comparisonRequest?.id == request.id {
        workflowComparisonState.retainAndPresent(request)
        selectedWorkspaceID = nil
        selectedModuleLandingPath = nil
        primarySessionId = request.implementation.itemID
        scrollToSessionId = request.implementation.itemID
        router.markConsumed(request)
      }
      return true
    }

    for target in [request.implementation, request.review] {
      let viewModel = target.providerKind == .claude ? claudeViewModel : codexViewModel
      if !viewModel.isMonitoring(sessionId: target.session.id) {
        viewModel.startMonitoring(session: target.session)
      }
      if target.providerKind == .codex {
        viewModel.ensureLiveMonitoring(sessionId: target.session.id)
      }
    }

    // Evaluate after monitoring starts so newly-monitored sessions are visible.
    let ids = availableItemIDs()
    guard ids.contains(request.implementation.itemID),
      ids.contains(request.review.itemID)
    else {
      return false
    }

    selectedWorkspaceID = nil
    selectedModuleLandingPath = nil
    workflowComparisonState.retainAndPresent(request)
    primarySessionId = request.implementation.itemID
    scrollToSessionId = request.implementation.itemID
    MainThreadStallMonitor.breadcrumb("nav: consumed comparison \(request.id)")
    router.markConsumed(request)
    return true
  }

  // MARK: - Ensure Primary Selection

  /// If no module landing or workspace is selected, and no valid primary
  /// session is set, picks the first available session.
  func ensurePrimarySelection(
    items: [SessionItemSnapshot],
    hasRouterRequest: Bool
  ) {
    guard selectedModuleLandingPath == nil, selectedWorkspaceID == nil else {
      primarySessionId = nil
      return
    }

    if hasRouterRequest {
      primarySessionId = nil
      return
    }
    guard !items.isEmpty else {
      primarySessionId = nil
      return
    }
    if let current = primarySessionId, items.contains(where: { $0.id == current }) {
      return
    }
    primarySessionId = items.first?.id
  }

  // MARK: - Workflow Comparison Helpers

  func closeWorkflowComparison(router: GlobalSessionSelectionRouter?) {
    let comparison = workflowComparisonState.close()
    router?.closeComparison(comparison)
  }

  func reopenWorkflowComparison() {
    guard let comparison = workflowComparisonState.presentRetainedComparison() else { return }
    selectedWorkspaceID = nil
    selectedModuleLandingPath = nil
    primarySessionId = comparison.implementation.itemID
    scrollToSessionId = comparison.implementation.itemID
  }

  // MARK: - GitHub Refresh Scheduling

  func scheduleInitialGitHubStateRefreshIfNeeded(
    canRefresh: Bool,
    observationService: (any GitHubPRObservationServiceProtocol)?,
    targets: @Sendable @escaping @MainActor () -> [GitHubPRObservationTarget]
  ) {
    guard !didScheduleInitialGitHubStateRefresh, canRefresh else {
      return
    }

    // Mark only after we confirm the delayed task will actually run.
    didScheduleInitialGitHubStateRefresh = true
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      let resolvedTargets = targets()
      guard !resolvedTargets.isEmpty else {
        // Nothing to refresh — allow a future mount to retry.
        didScheduleInitialGitHubStateRefresh = false
        return
      }
      scheduleGitHubStateRefresh(
        limit: 12,
        showsIndicator: false,
        observationService: observationService,
        targets: { resolvedTargets }
      )
    }
  }

  func scheduleGitHubStateRefresh(
    limit: Int?,
    showsIndicator: Bool,
    observationService: (any GitHubPRObservationServiceProtocol)?,
    targets: () -> [GitHubPRObservationTarget]
  ) {
    guard !isRefreshingGitHubStates,
      let observationService
    else {
      return
    }

    let targetList = Array(targets().prefix(limit ?? Int.max))
    guard !targetList.isEmpty else { return }

    isRefreshingGitHubStates = true
    Task { @MainActor in
      defer { isRefreshingGitHubStates = false }
      for target in targetList {
        await observationService.refresh(target)
        try? await Task.sleep(for: .milliseconds(120))
      }
      if showsIndicator {
        try? await Task.sleep(for: .milliseconds(350))
      }
    }
  }

  // MARK: - Selection Helpers

  /// Select a module landing page, clearing other selections.
  func selectEmptyModule(_ path: String) {
    MainThreadStallMonitor.breadcrumb("nav: selectEmptyModule")
    workflowComparisonState.showStandaloneContent()
    selectedWorkspaceID = nil
    selectedModuleLandingPath = path
    primarySessionId = nil
  }

  /// Select a session row, clearing the module landing and workspace focus.
  func selectSession(_ itemID: String) {
    MainThreadStallMonitor.breadcrumb("nav: select \(itemID.prefix(20))")
    workflowComparisonState.showStandaloneContent()
    selectedWorkspaceID = nil
    selectedModuleLandingPath = nil
    primarySessionId = itemID
  }

  /// Selects the session a launch just created, then clears the view model's
  /// one-shot `lastCreatedPendingId`. Safe to call at any time, so a launch
  /// started while Sessions is off screen (Sprint, Reviews) is still selected.
  /// Returns false when there is nothing to consume.
  @discardableResult
  func consumeCreatedPendingSession(
    provider: SessionProviderKind,
    viewModel: CLISessionsViewModel
  ) -> Bool {
    guard let pendingID = viewModel.lastCreatedPendingId else { return false }
    selectPendingSession(provider: provider, pendingID: pendingID)
    viewModel.lastCreatedPendingId = nil
    return true
  }

  /// React to a newly created pending session.
  func selectPendingSession(provider: SessionProviderKind, pendingID: UUID) {
    MainThreadStallMonitor.breadcrumb("nav: selectPending \(provider.rawValue)")
    workflowComparisonState.showStandaloneContent()
    selectedWorkspaceID = nil
    primarySessionId = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
  }
}

// MARK: - SessionItemSnapshot

/// A lightweight snapshot of a session item, used by `SessionNavigationModel`
/// to avoid depending on the view-private `SelectedSessionItem`.
struct SessionItemSnapshot {
  let id: String
  let providerKind: SessionProviderKind
  let sessionId: String
  let isPending: Bool
}

// MARK: - Binding helper

extension SessionNavigationModel {
  /// Two-way binding for the workflow comparison, wired to the given router for
  /// close bookkeeping.
  func workflowComparisonBinding(
    router: GlobalSessionSelectionRouter?
  ) -> Binding<WorkflowSessionComparisonRequest?> {
    Binding(
      get: { [weak self] in self?.workflowComparisonState.presentedComparison },
      set: { [weak self] comparison in
        guard let self else { return }
        if let comparison {
          self.workflowComparisonState.retainAndPresent(comparison)
        } else {
          self.closeWorkflowComparison(router: router)
        }
      }
    )
  }
}
