//
//  LinearViewModel.swift
//  AgentHub
//
//  Linear board: team's active cycle issues by workflow state, or "My issues"
//  fallback when there is no cycle. Mirrors JiraSprintViewModel's patterns.
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
  }

  // MARK: - Derived

  public var selectedTeam: LinearTeam? { teams.first { $0.id == selectedTeamID } }

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
    activeCycle == nil && loadState == .loaded
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
    do {
      if viewer == nil { viewer = try await service.viewer() }
      if teams.isEmpty { teams = try await service.teams() }
      if selectedTeam == nil { selectedTeamID = teams.first?.id }
      try await loadTeamData()
      loadState = .loaded
      refreshError = nil
    } catch {
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
    loadState = .loading
    do {
      try await loadTeamData()
      loadState = .loaded
      refreshError = nil
    } catch {
      refreshError = nil
      loadState = Self.mapError(error)
    }
  }

  private func loadTeamData() async throws {
    guard let teamID = selectedTeamID else {
      activeCycle = nil
      workflowStates = []
      issues = []
      return
    }
    workflowStates = try await service.workflowStates(teamID: teamID)
    activeCycle = try await service.activeCycle(teamID: teamID)
    if let cycle = activeCycle {
      issues = try await service.cycleIssues(cycleID: cycle.id)
    } else if let viewerID = viewer?.id {
      // Fallback: my assigned issues not completed.
      issues = try await service.assignedIssues(userID: viewerID)
    } else {
      issues = []
    }
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
    viewer = nil
    teams = []
    issues = []
    workflowStates = []
    activeCycle = nil
    selectedTeamID = nil
    refreshError = nil
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
      createdAt: issue.createdAt
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
