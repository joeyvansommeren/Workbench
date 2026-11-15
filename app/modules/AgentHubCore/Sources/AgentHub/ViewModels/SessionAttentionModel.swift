import AgentHubGitHub
import AppKit
import Foundation

@MainActor
@Observable
final class SessionAttentionModel {
  private(set) var items: [SessionAttentionItem] = []
  private(set) var snapshots: [String: GitHubPRObservationSnapshot] = [:]
  private var inputs: [SessionAttentionInput] = []
  private var cursors: [ObjectIdentifier: String] = [:]
  private var records: [String: SessionResult] = [:]

  static func inputs(agentHub: AgentHubProvider) -> [SessionAttentionInput] {
    ShellSessionItems.items(claude: agentHub.claudeSessionsViewModel, codex: agentHub.codexSessionsViewModel).map { item in
      let vm = item.providerKind == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
      return SessionAttentionInput(id: item.id, title: vm.displayName(for: item.session), provider: item.providerKind,
        sessionID: item.session.id, projectPath: item.session.projectPath, status: item.status,
        isPending: item.isPending, pendingToolName: item.pendingToolName,
        lastActivityAt: vm.monitorStates[item.session.id]?.lastActivityAt, branchName: item.session.branchName)
    }
  }

  func update(inputs: [SessionAttentionInput], records: [String: SessionResult]) {
    self.inputs = inputs; self.records = records
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
    guard inputs.contains(where: { $0.id == itemID && Self.matches(snapshot: snapshot, input: $0) }) else { return }
    snapshots[itemID] = snapshot
    rebuild()
  }

  private func rebuild() {
    var failures: [String: String] = [:]
    for (id, snapshot) in snapshots where snapshot.pullRequest != nil && snapshot.ciSummary.failed > 0 {
      if snapshot.isStale { failures[id] = "Check failure · status unavailable" }
      else if snapshot.state == .ready { failures[id] = "Review failed checks" }
    }
    items = SessionAttentionProjection.project(inputs: inputs, records: records,
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

  func openNext(agentHub: AgentHubProvider, navigationModel: SessionNavigationModel,
    shellModel: WorkbenchShellModel, coordinator: SessionsActionCoordinator,
    detailState: SessionDetailStateModel? = nil) {
    update(inputs: Self.inputs(agentHub: agentHub), records: agentHub.sessionResultLibrary.records)
    guard let next = SessionAttentionProjection.next(after: navigationModel.primarySessionId ?? cursors[ObjectIdentifier(navigationModel)], in: items) else {
      announce("No sessions need you"); return
    }
    open(next, agentHub: agentHub, navigationModel: navigationModel, shellModel: shellModel, coordinator: coordinator, detailState: detailState)
  }

  func open(_ item: SessionAttentionItem, agentHub: AgentHubProvider, navigationModel: SessionNavigationModel,
    shellModel: WorkbenchShellModel, coordinator: SessionsActionCoordinator,
    detailState: SessionDetailStateModel? = nil) {
    guard let session = ShellSessionItems.items(claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel).first(where: { $0.id == item.id }) else { return }
    cursors[ObjectIdentifier(navigationModel)] = item.id
    let node = SessionNode(id: session.id, session: session.session, providerKind: session.providerKind,
      isPending: session.isPending, status: session.status, pendingID: session.pendingID,
      pendingToolName: session.pendingToolName)
    SidebarTreeActions(agentHub: agentHub, shellModel: shellModel,
      navigationModel: navigationModel, coordinator: coordinator, detailState: detailState).open(node)
    if !shellModel.sidebarVisible { shellModel.toggleSidebar() }
    announce("\(item.title), \(item.reason)")
  }

  private func announce(_ text: String) {
    guard let window = NSApp.keyWindow else { return }
    NSAccessibility.post(element: window, notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }
}
