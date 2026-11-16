import AgentHubGitHub
import AppKit
import Foundation

@MainActor
@Observable
final class SessionAttentionModel {
  private(set) var items: [SessionAttentionItem] = []
  private(set) var snapshots: [String: GitHubPRObservationSnapshot] = [:]
  private var inputs: [SessionAttentionInput] = []
  private var records: [String: SessionResult] = [:]
  private let announce: (String) -> Void

  init(announce: ((String) -> Void)? = nil) {
    self.announce = announce ?? Self.postAnnouncement
  }

  static func inputs(agentHub: AgentHubProvider) -> [SessionAttentionInput] {
    ShellSessionItems.items(
      claude: agentHub.claudeSessionsViewModel, codex: agentHub.codexSessionsViewModel
    ).map { item in
      let vm =
        item.providerKind == .claude
        ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
      return SessionAttentionInput(
        id: item.id, title: vm.displayName(for: item.session), provider: item.providerKind,
        sessionID: item.session.id, projectPath: item.session.projectPath, status: item.status,
        isPending: item.isPending, pendingToolName: item.pendingToolName,
        lastActivityAt: vm.monitorStates[item.session.id]?.lastActivityAt,
        branchName: item.session.branchName)
    }
  }

  func update(inputs: [SessionAttentionInput], records: [String: SessionResult]) {
    self.inputs = inputs
    self.records = records
    snapshots = snapshots.filter { id, snapshot in
      inputs.contains { $0.id == id && Self.matches(snapshot: snapshot, input: $0) }
    }
    rebuild()
  }

  static func matches(snapshot: GitHubPRObservationSnapshot, input: SessionAttentionInput) -> Bool {
    guard case .session(let path, let branch, _) = snapshot.target else { return false }
    return path == input.projectPath && branch == input.branchName
  }

  func receive(_ snapshot: GitHubPRObservationSnapshot, itemID: String) {
    guard inputs.contains(where: { $0.id == itemID && Self.matches(snapshot: snapshot, input: $0) })
    else { return }
    snapshots[itemID] = snapshot
    rebuild()
  }

  private func rebuild() {
    var failures: [String: String] = [:]
    for (id, snapshot) in snapshots where snapshot.ciSummary.failed > 0 {
      guard let pr = snapshot.pullRequest, pr.stateKind == .open,
        let input = inputs.first(where: { $0.id == id }),
        input.branchName == pr.headRefName
      else { continue }
      if snapshot.isStale {
        failures[id] = "Check failure · status unavailable"
      } else if snapshot.state == .ready {
        failures[id] = "Review failed checks"
      } else if snapshot.state == .refreshing, snapshot.lastRefreshedAt != nil {
        // Refresh retains earlier evidence; removing it would reorder the queue on every poll.
        failures[id] = "Check failure · refreshing status"
      }
    }
    items = SessionAttentionProjection.project(
      inputs: inputs, records: records,
      failedChecks: failures, previous: items)
  }

  func checksLabel(for id: String) -> String {
    guard let snapshot = snapshots[id] else { return "Checks not loaded" }
    if snapshot.isStale { return "Checks unavailable · showing earlier evidence" }
    guard snapshot.state == .ready else { return "Check status not verified" }
    guard snapshot.pullRequest != nil else { return "No pull request checks" }
    let checks = snapshot.ciSummary
    if checks.failed > 0 { return "\(checks.failed) checks failed" }
    if checks.pending > 0 { return "\(checks.pending) checks pending" }
    if checks.total == 0 { return "No checks recorded" }
    return "\(checks.passed) checks passed · \(checks.skipped) skipped"
  }

  func openNext(
    agentHub: AgentHubProvider, navigationModel: SessionNavigationModel,
    shellModel: WorkbenchShellModel, coordinator: SessionsActionCoordinator,
    detailState: SessionDetailStateModel? = nil
  ) {
    update(inputs: Self.inputs(agentHub: agentHub), records: agentHub.sessionResultLibrary.records)
    navigateNext(after: navigationModel.primarySessionId, shellModel: shellModel) { item in
      open(
        item, agentHub: agentHub, navigationModel: navigationModel, shellModel: shellModel,
        coordinator: coordinator, detailState: detailState)
    }
  }

  /// Navigation and speech share one target, including workspace-owned sessions.
  func navigateNext(
    after selectedID: String?, shellModel: WorkbenchShellModel,
    open: (SessionAttentionItem) -> Void
  ) {
    let next = SessionAttentionProjection.next(
      after: selectedID ?? shellModel.attentionTargetID, in: items)
    shellModel.showNeedsYou(targetID: next?.id)
    guard let next else {
      announce("No sessions need you")
      return
    }
    open(next)
    announce(next.accessibilityLabel)
  }

  func open(
    _ item: SessionAttentionItem, agentHub: AgentHubProvider,
    navigationModel: SessionNavigationModel,
    shellModel: WorkbenchShellModel, coordinator: SessionsActionCoordinator,
    detailState: SessionDetailStateModel? = nil, routeToReason: Bool = true
  ) {
    guard
      let session = ShellSessionItems.items(
        claude: agentHub.claudeSessionsViewModel,
        codex: agentHub.codexSessionsViewModel
      ).first(where: { $0.id == item.id })
    else { return }
    let node = SessionNode(
      id: session.id, session: session.session, providerKind: session.providerKind,
      isPending: session.isPending, status: session.status, pendingID: session.pendingID,
      pendingToolName: session.pendingToolName)
    SidebarTreeActions(
      agentHub: agentHub, shellModel: shellModel,
      navigationModel: navigationModel, coordinator: coordinator, detailState: detailState
    ).open(node)
    if routeToReason {
      let linkedPullRequests =
        item.category == .checks
        ? checksReferences(
          session: session.session, provider: session.providerKind, agentHub: agentHub)
        : []
      routeReason(
        item, projectPath: session.session.projectPath, branchName: session.session.branchName,
        session: session.session, provider: session.providerKind,
        linkedPullRequests: linkedPullRequests,
        navigationModel: navigationModel,
        shellModel: shellModel, coordinator: coordinator,
        detailState: detailState)
    }
    shellModel.showNeedsYou(targetID: item.id)
  }

  func checksReferences(
    session: CLISession, provider: SessionProviderKind, agentHub: AgentHubProvider
  ) -> [GitHubPullRequestURLReference] {
    let viewModel =
      provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
    let linked = SessionCardEffects.linkedPullRequests(
      session: session, state: viewModel.monitorStates[session.id],
      providerKind: provider, hubProvider: agentHub)
    let itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: session.id)
    let observed: GitHubPullRequestURLReference?
    if let snapshot = snapshots[itemID],
      case .session(let path, let branch, _) = snapshot.target,
      path == session.projectPath, branch == session.branchName,
      let pullRequest = snapshot.pullRequest, pullRequest.headRefName == branch
    {
      observed = GitHubPullRequestURLReference(urlString: pullRequest.url)
    } else {
      observed = nil
    }
    return Self.checksReferences(linked: linked, observed: observed)
  }

  static func checksReferences(
    linked: [GitHubPullRequestURLReference], observed: GitHubPullRequestURLReference?
  ) -> [GitHubPullRequestURLReference] {
    guard let observed else { return linked }
    return linked.filter { $0 != observed } + [observed]
  }

  func routeReason(
    _ item: SessionAttentionItem, projectPath: String, branchName: String? = nil,
    session: CLISession? = nil, provider: SessionProviderKind? = nil,
    linkedPullRequests: [GitHubPullRequestURLReference] = [],
    navigationModel: SessionNavigationModel, shellModel: WorkbenchShellModel,
    coordinator: SessionsActionCoordinator, detailState: SessionDetailStateModel?
  ) {
    if item.category == .question || item.category == .permission {
      // Pending request metadata can arrive before the provider's approval status.
      detailState?.setShowsResult(false, for: item.id)
      detailState?.setContentMode(.terminal, for: item.id, defaultProjectPath: projectPath)
    } else if item.category == .checks, let detailState {
      if navigationModel.selectedWorkspaceID != nil {
        coordinator.gitHubSheetItem = GitHubSheetItem(
          projectPath: projectPath, branchName: branchName, session: session, provider: provider,
          workspaceID: navigationModel.selectedWorkspaceID, linkedPullRequests: linkedPullRequests)
      } else {
        detailState.setSidePanelSegment(.gitHub, for: item.id)
        if !shellModel.sidePanelVisible { shellModel.toggleSidePanel() }
      }
    } else if item.category == .checks {
      coordinator.gitHubSheetItem = GitHubSheetItem(
        projectPath: projectPath, branchName: branchName, session: session, provider: provider,
        workspaceID: navigationModel.selectedWorkspaceID, linkedPullRequests: linkedPullRequests)
    } else if item.category == .result {
      if navigationModel.selectedWorkspaceID != nil {
        coordinator.attentionResultRequestID = item.id
      } else {
        detailState?.setShowsResult(true, for: item.id)
      }
    }
  }

  private static func postAnnouncement(_ text: String) {
    guard let window = NSApp.keyWindow else { return }
    NSAccessibility.post(
      element: window, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}
