//
//  LinearViewModel.swift
//  AgentHub
//
//  Linear board: team's active cycle issues by workflow state, or "My issues"
//  fallback when there is no cycle, or one project's open issues when a
//  project is picked. Mirrors JiraSprintViewModel's patterns.
//

import AgentWorkflowLinear
import Foundation
import Observation

@MainActor
@Observable
public final class LinearViewModel {
  public enum LoadState: Equatable {
    case idle
    case noKey
    case loading
    case loaded
    case unauthorized
    case rateLimited
    case failed(String)
  }

  public enum AssigneeFilter: Hashable {
    case everyone
    case me
  }

  public struct BoardColumn: Identifiable, Equatable {
    public let state: LinearWorkflowState
    public let issues: [LinearIssue]
    public var id: String { state.id }
  }

  // MARK: - State

  public private(set) var loadState: LoadState = .idle
  public private(set) var viewer: LinearUser?
  public private(set) var teams: [LinearTeam] = []
  public private(set) var selectedTeamID: String?
  public private(set) var activeCycle: LinearCycle?
  /// The selected team's open projects, by name.
  public private(set) var projects: [LinearProject] = []
  /// The project filter. Nil shows all projects: the active cycle, or my
  /// issues without one. Saved per team (`linearSelectedProjectIDs`).
  public private(set) var selectedProjectID: String?
  public private(set) var workflowStates: [LinearWorkflowState] = []
  public private(set) var issues: [LinearIssue] = []
  public private(set) var selectedIssueID: String?
  public private(set) var issueDetail: LinearIssue?
  public private(set) var isLoadingDetail = false
  public private(set) var isStartingSession = false
  /// Issue ids with a session launch in flight (prevents double starts).
  public private(set) var startingIssueIDs = Set<String>()
  /// A refresh failed while issues were on screen; the board stays.
  public private(set) var refreshError: String?

  /// The result of a Move To, shown above the board until dismissed.
  public struct StatusNotice: Equatable {
    public let text: String
    public let isError: Bool
  }

  public private(set) var statusNotice: StatusNotice?

  public var searchText = ""

  public var assigneeFilter: AssigneeFilter {
    didSet {
      userDefaults.set(
        assigneeFilter == .everyone ? "everyone" : "me",
        forKey: AgentHubDefaults.linearAssigneeFilter
      )
    }
  }

  /// Whether to move an issue to "started" when a session begins.
  public var moveToStartedOnLaunch: Bool {
    didSet {
      userDefaults.set(moveToStartedOnLaunch, forKey: AgentHubDefaults.linearMoveToStarted)
    }
  }

  /// Local repository path new issue sessions start in.
  public var repositoryPath: String? {
    didSet { userDefaults.set(repositoryPath, forKey: AgentHubDefaults.linearRepositoryPath) }
  }

  @ObservationIgnored private let service: any LinearService
  @ObservationIgnored private let userDefaults: UserDefaults
  /// Whether a key is stored. Injected so tests never read the Keychain.
  @ObservationIgnored private let hasAPIKey: () -> Bool
  @ObservationIgnored private var detailTask: Task<Void, Never>?
  /// Bumped by every team-data load, team or project switch and disconnect.
  /// A load whose generation is no longer current drops its result, so a
  /// slow answer for an old team or project never overwrites a newer one.
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored let sessionLinker = LinearSessionLinker()

  /// Names for sessions started from the board, applied once the pending session
  /// resolves to a real one (keyed by pending id).
  @ObservationIgnored private var pendingSessionNames: [UUID: String] = [:]

  public init(
    service: any LinearService = LinearAPIClient(),
    userDefaults: UserDefaults = .standard,
    hasAPIKey: @escaping () -> Bool = { LinearKeychainStore.apiKey() != nil }
  ) {
    self.service = service
    self.userDefaults = userDefaults
    self.hasAPIKey = hasAPIKey
    assigneeFilter = userDefaults.string(forKey: AgentHubDefaults.linearAssigneeFilter) == "everyone"
      ? .everyone : .me
    moveToStartedOnLaunch = userDefaults.object(forKey: AgentHubDefaults.linearMoveToStarted) as? Bool ?? true
    repositoryPath = userDefaults.string(forKey: AgentHubDefaults.linearRepositoryPath)
    let teamID = userDefaults.string(forKey: AgentHubDefaults.linearSelectedTeamID)
    selectedTeamID = teamID
    selectedProjectID = teamID.flatMap { Self.storedProjectID(for: $0, in: userDefaults) }
  }

  // MARK: - Derived

  public var selectedTeam: LinearTeam? { teams.first { $0.id == selectedTeamID } }

  public var selectedProject: LinearProject? {
    guard let selectedProjectID else { return nil }
    return projects.first { $0.id == selectedProjectID }
  }

  public var selectedIssue: LinearIssue? {
    if let issueDetail, issueDetail.id == selectedIssueID { return issueDetail }
    return issues.first { $0.id == selectedIssueID }
  }

  /// Visible states: backlog, unstarted, started, completed. Canceled is hidden.
  private var visibleStates: [LinearWorkflowState] {
    workflowStates
      .filter { $0.type != "canceled" }
      .sorted(by: LinearWorkflowState.displayOrder)
  }

  public var filteredIssues: [LinearIssue] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return issues.filter { issue in
      matchesAssignee(issue)
        && (query.isEmpty
          || issue.identifier.localizedCaseInsensitiveContains(query)
          || issue.title.localizedCaseInsensitiveContains(query))
    }
  }

  public var columns: [BoardColumn] {
    let visible = filteredIssues
    return visibleStates.map { state in
      BoardColumn(
        state: state,
        issues: visible.filter { $0.state.id == state.id }
      )
    }
  }

  /// Team keys known from the loaded teams. Used for session linking.
  public var knownTeamKeys: Set<String> {
    Set(teams.map(\.key))
  }

  /// My open issues: the Linear tab's badge.
  public var myOpenIssueCount: Int {
    guard let viewerID = viewer?.id else { return 0 }
    return issues.filter {
      $0.assignee?.id == viewerID
        && $0.state.type != "completed"
        && $0.state.type != "canceled"
    }.count
  }

  /// Whether the board is showing "My issues" fallback (no active cycle).
  public var isMyIssuesFallback: Bool {
    selectedProjectID == nil && activeCycle == nil && loadState == .loaded
  }

  private func matchesAssignee(_ issue: LinearIssue) -> Bool {
    switch assigneeFilter {
    case .everyone: return true
    case .me:
      guard let viewerID = viewer?.id else { return false }
      return issue.assignee?.id == viewerID
    }
  }

  // MARK: - Loading

  /// - Parameter keepsBoardOnFailure: The new shell's board passes true: a
  ///   refresh that fails while issues are on screen keeps the board and sets
  ///   `refreshError`. A rejected or missing key still shows the connect
  ///   state. The legacy board keeps its failure states.
  public func load(keepsBoardOnFailure: Bool = false) async {
    // Fast clicks on Retry or Refresh must not start parallel loads.
    guard loadState != .loading else { return }
    guard hasAPIKey() else {
      refreshError = nil
      loadState = .noKey
      return
    }
    loadState = .loading
    let generation = nextLoadGeneration()
    do {
      if viewer == nil { viewer = try await service.viewer() }
      if teams.isEmpty { teams = try await service.teams() }
      if selectedTeam == nil { selectedTeamID = teams.first?.id }
      let teamID = selectedTeamID
      let data = try await fetchTeamData(teamID: teamID)
      guard generation == loadGeneration else { return }
      apply(data, teamID: teamID)
      loadState = .loaded
      refreshError = nil
    } catch {
      guard generation == loadGeneration else { return }
      let failure = Self.mapError(error)
      let keepsBoard = keepsBoardOnFailure && !issues.isEmpty
      switch failure {
      case .failed(let message) where keepsBoard:
        loadState = .loaded
        refreshError = "Could not refresh Linear: \(SprintErrorText.summary(message))"
      case .rateLimited where keepsBoard:
        loadState = .loaded
        refreshError = Self.rateLimitedMessage
      default:
        // The failure state replaces the board, so a refresh notice is stale.
        refreshError = nil
        loadState = failure
      }
    }
  }

  static let rateLimitedMessage = "Linear asked Workbench to slow down. Try again in a moment."

  public func dismissRefreshError() {
    refreshError = nil
  }

  public func loadIfNeeded() async {
    if loadState == .idle || loadState == .noKey { await load() }
  }

  public func selectTeam(_ teamID: String) async {
    guard teamID != selectedTeamID else { return }
    selectedTeamID = teamID
    userDefaults.set(teamID, forKey: AgentHubDefaults.linearSelectedTeamID)
    closeIssue()
    // The old team's projects do not apply; this team's saved project shows
    // in the head while its data loads.
    projects = []
    selectedProjectID = Self.storedProjectID(for: teamID, in: userDefaults)
    await reloadTeamData()
  }

  /// Filters the board to one project, or nil for all projects. Saved for
  /// the selected team. With a project the board shows its open issues in
  /// this team, whatever the cycle; All | Mine and search still apply.
  public func selectProject(_ projectID: String?) async {
    guard projectID != selectedProjectID, let teamID = selectedTeamID else { return }
    if let projectID, !projects.contains(where: { $0.id == projectID }) { return }
    selectedProjectID = projectID
    storeProjectID(projectID, for: teamID)
    closeIssue()
    // The old list is not this filter's: show the spinner, not stale cards.
    issues = []
    await reloadTeamData()
  }

  /// Loads the selected team's data after a team or project switch. A
  /// failure shows its state (as a team switch always did).
  private func reloadTeamData() async {
    loadState = .loading
    let generation = nextLoadGeneration()
    let teamID = selectedTeamID
    do {
      let data = try await fetchTeamData(teamID: teamID)
      guard generation == loadGeneration else { return }
      apply(data, teamID: teamID)
      loadState = .loaded
      refreshError = nil
    } catch {
      guard generation == loadGeneration else { return }
      refreshError = nil
      loadState = Self.mapError(error)
    }
  }

  private func nextLoadGeneration() -> Int {
    loadGeneration += 1
    return loadGeneration
  }

  /// One team's board, fetched before any of it is shown.
  private struct TeamData {
    var workflowStates: [LinearWorkflowState] = []
    var projects: [LinearProject] = []
    /// The saved project when it is still one of `projects`, else nil.
    var projectID: String?
    var activeCycle: LinearCycle?
    var issues: [LinearIssue] = []
  }

  private func fetchTeamData(teamID: String?) async throws -> TeamData {
    guard let teamID else { return TeamData() }
    var data = TeamData()
    data.workflowStates = try await service.workflowStates(teamID: teamID)
    data.projects = try await service.projects(teamID: teamID)
    let storedID = Self.storedProjectID(for: teamID, in: userDefaults)
    data.projectID = data.projects.contains { $0.id == storedID } ? storedID : nil
    if let projectID = data.projectID {
      data.issues = try await service.projectIssues(projectID: projectID, teamID: teamID)
      return data
    }
    data.activeCycle = try await service.activeCycle(teamID: teamID)
    if let cycle = data.activeCycle {
      data.issues = try await service.cycleIssues(cycleID: cycle.id)
    } else if let viewerID = viewer?.id {
      // Fallback: my assigned issues not completed.
      data.issues = try await service.assignedIssues(userID: viewerID)
    }
    return data
  }

  private func apply(_ data: TeamData, teamID: String?) {
    workflowStates = data.workflowStates
    projects = data.projects
    activeCycle = data.activeCycle
    issues = data.issues
    selectedProjectID = data.projectID
    // A saved project that was completed, canceled or deleted, or left the
    // team: forget it, so the board stays on all projects.
    if let teamID, data.projectID == nil, Self.storedProjectID(for: teamID, in: userDefaults) != nil {
      storeProjectID(nil, for: teamID)
    }
  }

  private static func storedProjectID(for teamID: String, in defaults: UserDefaults) -> String? {
    let stored = defaults.dictionary(forKey: AgentHubDefaults.linearSelectedProjectIDs) as? [String: String]
    return stored?[teamID]
  }

  private func storeProjectID(_ projectID: String?, for teamID: String) {
    var stored =
      userDefaults.dictionary(forKey: AgentHubDefaults.linearSelectedProjectIDs) as? [String: String] ?? [:]
    stored[teamID] = projectID
    userDefaults.set(stored, forKey: AgentHubDefaults.linearSelectedProjectIDs)
  }

  /// Saves a new API key and reloads.
  public func connect(apiKey: String) async {
    LinearKeychainStore.setApiKey(apiKey)
    viewer = nil
    teams = []
    await load()
  }

  /// Removes the API key and resets state.
  public func disconnect() {
    LinearKeychainStore.deleteApiKey()
    // A load still in flight must not fill the board again.
    _ = nextLoadGeneration()
    viewer = nil
    teams = []
    issues = []
    workflowStates = []
    activeCycle = nil
    projects = []
    selectedProjectID = nil
    selectedTeamID = nil
    refreshError = nil
    statusNotice = nil
    closeIssue()
    loadState = .noKey
  }

  /// Keyboard navigation over the visible board (`SprintBoardNavigation`).
  public func moveSelection(_ direction: SprintMoveDirection) {
    let next = SprintBoardNavigation.target(
      columns: columns.map { $0.issues.map(\.id) }, selected: selectedIssueID, direction: direction)
    if let next { openIssue(next) }
  }

  // MARK: - Issue detail

  public func openIssue(_ id: String) {
    selectedIssueID = id
    issueDetail = nil
    isLoadingDetail = true
    detailTask?.cancel()
    detailTask = Task { [service] in
      let detail = try? await service.issue(id: id)
      guard !Task.isCancelled, self.selectedIssueID == id else { return }
      self.issueDetail = detail
      self.isLoadingDetail = false
    }
  }

  public func closeIssue() {
    detailTask?.cancel()
    selectedIssueID = nil
    issueDetail = nil
    isLoadingDetail = false
  }

  // MARK: - Session launch

  /// Returns true if the issue was not already in flight and is now marked.
  /// Returns false if a launch is already in progress for this issue.
  public func beginStartingSession(for issueID: String) -> Bool {
    startingIssueIDs.insert(issueID).inserted
  }

  /// Clears the in-flight state for an issue.
  public func endStartingSession(for issueID: String) {
    startingIssueIDs.remove(issueID)
  }

  static func sessionName(for issue: LinearIssue) -> String {
    let title = issue.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let shortened = title.count > 70 ? String(title.prefix(69)) + "\u{2026}" : title
    return "\(issue.identifier): \(shortened)"
  }

  public func registerPendingSession(_ pendingID: UUID, for issue: LinearIssue) {
    pendingSessionNames[pendingID] = Self.sessionName(for: issue)
  }

  public func takeSessionNames(resolved: [UUID: String]) -> [(sessionID: String, name: String)] {
    var names: [(sessionID: String, name: String)] = []
    for (pendingID, sessionID) in resolved {
      if let name = pendingSessionNames.removeValue(forKey: pendingID) {
        names.append((sessionID, name))
      }
    }
    return names
  }

  /// Builds the agent prompt for an issue.
  public func launchPrompt(for issue: LinearIssue) async -> String {
    if issue.description != nil { return Self.prompt(for: issue) }
    let detailed = (try? await service.issue(id: issue.id)) ?? issue
    return Self.prompt(for: detailed)
  }

  static func prompt(for issue: LinearIssue) -> String {
    var lines = ["Pick up Linear issue \(issue.identifier): \(issue.title)"]
    lines.append("Priority: \(issue.priorityLabel)")
    lines.append("State: \(issue.state.name)")
    if !issue.labels.isEmpty {
      lines.append("Labels: \(issue.labels.map(\.name).joined(separator: ", "))")
    }
    if let description = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines),
      !description.isEmpty
    {
      lines.append("")
      lines.append("Description:")
      lines.append(description)
    }
    lines.append("")
    lines.append(
      "Work on a branch named after the issue identifier "
        + "(for example `\(issue.identifier.lowercased())-short-description`), implement the change, "
        + "and run the relevant tests before you finish."
    )
    return lines.joined(separator: "\n")
  }

  /// Moves an issue to the team's first "started" state.
  public func markStartedIfNeeded(_ issueID: String) async {
    guard moveToStartedOnLaunch else { return }
    guard let issue = issues.first(where: { $0.id == issueID }) ?? issueDetail,
      issue.state.type == "unstarted" || issue.state.type == "backlog"
    else { return }
    guard let startedState = workflowStates
      .filter({ $0.type == "started" })
      .sorted(by: { $0.position < $1.position })
      .first
    else { return }
    do {
      try await service.transitionIssue(id: issueID, stateID: startedState.id)
      // Update locally so the board reflects the change.
      issues = issues.map { i in
        i.id == issueID ? withState(i, startedState) : i
      }
      if issueDetail?.id == issueID {
        issueDetail = withState(issueDetail!, startedState)
      }
    } catch {
      // Best effort: the session still starts.
    }
  }

  // MARK: - Move To

  /// Moves an issue to another workflow state (the board's and the detail's
  /// Move To). The board updates at once and rolls back if Linear refuses,
  /// as Jira's `moveTicket` does.
  public func moveIssue(_ issueID: String, toStateID stateID: String) async {
    guard
      let original = issues.first(where: { $0.id == issueID })
        ?? (issueDetail?.id == issueID ? issueDetail : nil),
      original.state.id != stateID,
      let target = workflowStates.first(where: { $0.id == stateID })
    else { return }
    let originalDetail = issueDetail
    applyState(target, to: issueID)
    do {
      try await service.transitionIssue(id: issueID, stateID: stateID)
      statusNotice = StatusNotice(text: "\(original.identifier) moved to \(target.name)", isError: false)
    } catch {
      applyState(original.state, to: issueID)
      if originalDetail?.id == issueID { issueDetail = originalDetail }
      statusNotice = StatusNotice(
        text: "Could not move \(original.identifier) to \(target.name): \(Self.moveFailureMessage(error))",
        isError: true)
    }
  }

  public func dismissStatusNotice() {
    statusNotice = nil
  }

  private func applyState(_ state: LinearWorkflowState, to issueID: String) {
    issues = issues.map { $0.id == issueID ? withState($0, state) : $0 }
    if let issueDetail, issueDetail.id == issueID {
      self.issueDetail = withState(issueDetail, state)
    }
  }

  private static func moveFailureMessage(_ error: Error) -> String {
    switch mapError(error) {
    case .failed(let message): return SprintErrorText.summary(message)
    case .rateLimited: return rateLimitedMessage
    case .unauthorized, .noKey: return "Linear did not accept the API key."
    case .idle, .loading, .loaded: return error.localizedDescription
    }
  }

  private func withState(_ issue: LinearIssue, _ state: LinearWorkflowState) -> LinearIssue {
    LinearIssue(
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      priorityLabel: issue.priorityLabel,
      state: state,
      assignee: issue.assignee,
      labels: issue.labels,
      url: issue.url,
      createdAt: issue.createdAt,
      project: issue.project
    )
  }

  private static func mapError(_ error: Error) -> LoadState {
    switch error as? LinearAPIError {
    case .missingKey: return .noKey
    case .unauthorized: return .unauthorized
    case .rateLimited: return .rateLimited
    case .network(let message): return .failed(message)
    case .decoding(let message): return .failed("Could not read Linear's response: \(message)")
    case .graphQL(let messages): return .failed(messages.joined(separator: "; "))
    case nil: return .failed(error.localizedDescription)
    }
  }
}
