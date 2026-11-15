import AgentWorkflowLinear
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Linear view model")
struct LinearViewModelTests {
  private func makeViewModel() -> LinearViewModel {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return LinearViewModel(userDefaults: defaults)
  }

  @Test("A second start for the same issue is refused until the first one ends")
  func startingSessionGuard() {
    let viewModel = makeViewModel()

    #expect(viewModel.beginStartingSession(for: "issue-1"))
    #expect(viewModel.startingIssueIDs.contains("issue-1"))
    // A double-click on Start: the second launch is refused.
    #expect(!viewModel.beginStartingSession(for: "issue-1"))
    // Another issue can still start.
    #expect(viewModel.beginStartingSession(for: "issue-2"))

    viewModel.endStartingSession(for: "issue-1")
    #expect(!viewModel.startingIssueIDs.contains("issue-1"))
    #expect(viewModel.beginStartingSession(for: "issue-1"))
  }

  private func loadedViewModel(
    _ service: MockLinearService, hasAPIKey: @escaping () -> Bool = { true }
  ) async -> LinearViewModel {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("everyone", forKey: AgentHubDefaults.linearAssigneeFilter)
    let viewModel = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: hasAPIKey)
    await viewModel.load(keepsBoardOnFailure: true)
    return viewModel
  }

  @Test("Arrow keys walk the Linear board like the Jira board")
  func keyboardNavigation() async {
    let viewModel = await loadedViewModel(MockLinearService())
    #expect(viewModel.loadState == .loaded)

    viewModel.moveSelection(.down)
    #expect(viewModel.selectedIssueID == "todo-1")
    viewModel.moveSelection(.down)
    #expect(viewModel.selectedIssueID == "todo-2")
    viewModel.moveSelection(.right)
    #expect(viewModel.selectedIssueID == "doing-1")
    viewModel.moveSelection(.left)
    #expect(viewModel.selectedIssueID == "todo-1")
  }

  @Test("A failed refresh keeps the issues; a rejected key shows the connect state")
  func failedRefresh() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)

    await service.setError(LinearAPIError.network("The Internet connection appears to be offline."))
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.issues.count == 3)
    #expect(
      viewModel.refreshError == "Could not refresh Linear: The Internet connection appears to be offline.")

    await service.setError(LinearAPIError.rateLimited)
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.refreshError == LinearViewModel.rateLimitedMessage)

    await service.setError(nil)
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.refreshError == nil)

    await service.setError(LinearAPIError.network("offline"))
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.refreshError != nil)
    await service.setError(LinearAPIError.unauthorized)
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.loadState == .unauthorized)
    // The connect state replaces the board, so the old notice goes.
    #expect(viewModel.refreshError == nil)
  }

  @Test("The legacy board (keep-board off) shows its failure state on a failed refresh")
  func legacyRefreshFailure() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)

    await service.setError(LinearAPIError.network("offline"))
    await viewModel.load()
    #expect(viewModel.loadState == .failed("offline"))
    #expect(viewModel.refreshError == nil)
  }

  @Test("A team switch or a removed key clears a stale refresh notice")
  func refreshErrorClears() async {
    let service = MockLinearService()
    var hasKey = true
    let viewModel = await loadedViewModel(service, hasAPIKey: { hasKey })

    await service.setError(LinearAPIError.network("offline"))
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.refreshError != nil)
    await service.setError(nil)
    await viewModel.selectTeam("t2")
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.refreshError == nil)

    await service.setError(LinearAPIError.network("offline"))
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.refreshError != nil)
    hasKey = false
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.loadState == .noKey)
    #expect(viewModel.refreshError == nil)
  }

  @Test("Two loads at once call Linear once; a later load runs again")
  func loadIsNotReentrant() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    #expect(await service.workflowStateCalls == 1)
    await service.holdWorkflowStates()

    let first = Task { await viewModel.load() }
    while await service.workflowStateCalls < 2 { await Task.yield() }
    await viewModel.load()
    #expect(await service.workflowStateCalls == 2)

    await service.releaseWorkflowStates()
    await first.value
    #expect(viewModel.loadState == .loaded)

    await viewModel.load()
    #expect(await service.workflowStateCalls == 3)
  }

  @Test("The Filters assignee choice scopes the board to my issues and is remembered")
  func assigneeScope() async {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("everyone", forKey: AgentHubDefaults.linearAssigneeFilter)
    let viewModel = LinearViewModel(service: MockLinearService(), userDefaults: defaults, hasAPIKey: { true })
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.filteredIssues.count == 3)

    viewModel.assigneeFilter = .me
    #expect(viewModel.filteredIssues.map(\.id) == ["todo-2"])
    #expect(viewModel.columns.flatMap(\.issues).map(\.id) == ["todo-2"])
    #expect(defaults.string(forKey: AgentHubDefaults.linearAssigneeFilter) == "me")
    #expect(LinearViewModel(userDefaults: defaults).assigneeFilter == .me)

    viewModel.assigneeFilter = .everyone
    #expect(viewModel.filteredIssues.count == 3)
    #expect(LinearViewModel(userDefaults: defaults).assigneeFilter == .everyone)
  }

  @Test("Move To updates the board at once and calls Linear with the state")
  func moveIssue() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    viewModel.openIssue("todo-1")

    await viewModel.moveIssue("todo-1", toStateID: "s-doing")

    #expect(await service.transitions == [TransitionCall(issueID: "todo-1", stateID: "s-doing")])
    #expect(viewModel.issues.first { $0.id == "todo-1" }?.state.id == "s-doing")
    #expect(viewModel.columns.first { $0.id == "s-doing" }?.issues.map(\.id).contains("todo-1") == true)
    #expect(viewModel.selectedIssueID == "todo-1")
    #expect(viewModel.statusNotice == .init(text: "XFA-1 moved to In Progress", isError: false))
  }

  @Test("A refused Move To rolls the issue back and says why")
  func moveIssueRollsBack() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    await service.setTransitionError(LinearAPIError.network("offline"))

    await viewModel.moveIssue("todo-1", toStateID: "s-doing")

    #expect(viewModel.issues.first { $0.id == "todo-1" }?.state.id == "s-todo")
    #expect(viewModel.statusNotice?.isError == true)
    #expect(viewModel.statusNotice?.text == "Could not move XFA-1 to In Progress: offline")
    viewModel.dismissStatusNotice()
    #expect(viewModel.statusNotice == nil)
  }

  @Test("Moving to the current or an unknown state does nothing")
  func moveIssueNoOp() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)

    await viewModel.moveIssue("todo-1", toStateID: "s-todo")
    await viewModel.moveIssue("todo-1", toStateID: "s-missing")
    await viewModel.moveIssue("missing", toStateID: "s-doing")

    #expect(await service.transitions.isEmpty)
    #expect(viewModel.statusNotice == nil)
  }

  // MARK: Project filter

  private func makeDefaults() -> UserDefaults {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("everyone", forKey: AgentHubDefaults.linearAssigneeFilter)
    return defaults
  }

  private func storedProjects(_ defaults: UserDefaults) -> [String: String]? {
    defaults.dictionary(forKey: AgentHubDefaults.linearSelectedProjectIDs) as? [String: String]
  }

  @Test("The team's projects load by name; picking one loads its open issues in the team's columns")
  func selectProjectLoadsProjectIssues() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    #expect(viewModel.projects.map(\.name) == ["Billing", "Onboarding"])
    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.activeCycle?.id == "c1")

    viewModel.openIssue("todo-1")
    await viewModel.selectProject("p1")

    #expect(viewModel.loadState == .loaded)
    #expect(await service.projectIssueCalls == [ProjectIssuesCall(projectID: "p1", teamID: "t1")])
    #expect(viewModel.selectedProject == MockLinearService.onboarding)
    #expect(viewModel.issues.map(\.id) == ["p1-1", "p1-2"])
    #expect(viewModel.issues.allSatisfy { $0.project?.id == "p1" })
    // Regardless of the cycle: no cycle in the title or the detail.
    #expect(viewModel.activeCycle == nil)
    #expect(!viewModel.isMyIssuesFallback)
    #expect(viewModel.selectedIssueID == nil)
    #expect(viewModel.columns.map(\.state.id) == ["s-todo", "s-doing"])
    #expect(viewModel.columns.map { $0.issues.map(\.id) } == [["p1-1"], ["p1-2"]])
    #expect(
      SprintTitle.linear(project: viewModel.selectedProject, cycle: viewModel.activeCycle)
        == SprintTitle(title: "Onboarding", daysLeft: nil))
  }

  @Test("All projects brings the cycle back and forgets the team's project")
  func allProjectsRestoresCycle() async {
    let service = MockLinearService()
    let defaults = makeDefaults()
    let viewModel = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: { true })
    await viewModel.load(keepsBoardOnFailure: true)
    await viewModel.selectProject("p1")
    #expect(storedProjects(defaults) == ["t1": "p1"])

    await viewModel.selectProject(nil)

    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.activeCycle?.id == "c1")
    #expect(viewModel.issues.map(\.id) == ["todo-1", "todo-2", "doing-1"])
    #expect(storedProjects(defaults) == [:])
    #expect(SprintTitle.linear(project: nil, cycle: viewModel.activeCycle)?.title == "Cycle 12")
    #expect(SprintTitle.linear(project: nil, cycle: nil) == nil)
  }

  @Test("The project is saved per team and comes back after a relaunch and a team switch")
  func projectIsSavedPerTeam() async {
    let service = MockLinearService()
    let defaults = makeDefaults()
    let viewModel = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: { true })
    await viewModel.load(keepsBoardOnFailure: true)
    await viewModel.selectProject("p1")

    // A relaunch loads the saved project's issues, not the cycle.
    let relaunched = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: { true })
    await relaunched.load(keepsBoardOnFailure: true)
    #expect(relaunched.selectedProject == MockLinearService.onboarding)
    #expect(relaunched.issues.map(\.id) == ["p1-1", "p1-2"])

    // Another team has its own (here: none yet), then its own pick.
    await relaunched.selectTeam("t2")
    #expect(relaunched.selectedProjectID == nil)
    #expect(relaunched.projects == [MockLinearService.design])
    #expect(relaunched.activeCycle?.id == "c1")
    await relaunched.selectProject("p3")
    #expect(storedProjects(defaults) == ["t1": "p1", "t2": "p3"])

    await relaunched.selectTeam("t1")
    #expect(relaunched.selectedProjectID == "p1")
    #expect(relaunched.issues.map(\.id) == ["p1-1", "p1-2"])
  }

  @Test("A saved project that is gone is cleared and the board shows the cycle")
  func staleProjectIsCleared() async {
    let service = MockLinearService()
    let defaults = makeDefaults()
    defaults.set(["t1": "deleted-project", "t2": "p3"], forKey: AgentHubDefaults.linearSelectedProjectIDs)
    let viewModel = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: { true })
    await viewModel.load(keepsBoardOnFailure: true)

    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.activeCycle?.id == "c1")
    #expect(viewModel.issues.count == 3)
    #expect(await service.projectIssueCalls.isEmpty)
    // Only the stale team's entry goes.
    #expect(storedProjects(defaults) == ["t2": "p3"])

    // A project completed in Linear drops out of the list on the next refresh.
    await viewModel.selectProject("p1")
    await service.setProjects([MockLinearService.billing], team: "t1")
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.issues.count == 3)
    #expect(storedProjects(defaults) == ["t2": "p3"])
  }

  @Test("Picking the current or an unknown project does nothing")
  func selectProjectNoOp() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)

    await viewModel.selectProject(nil)
    await viewModel.selectProject("not-in-team")

    #expect(await service.projectIssueCalls.isEmpty)
    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.issues.count == 3)
  }

  @Test("Mine and search apply on top of the project")
  func mineAndSearchWithProject() async {
    let viewModel = await loadedViewModel(MockLinearService())
    await viewModel.selectProject("p1")

    viewModel.assigneeFilter = .me
    #expect(viewModel.filteredIssues.map(\.id) == ["p1-1"])
    viewModel.assigneeFilter = .everyone
    viewModel.searchText = "other"
    #expect(viewModel.filteredIssues.map(\.id) == ["p1-2"])
    viewModel.searchText = "XFA-10"
    #expect(viewModel.columns.flatMap(\.issues).map(\.id) == ["p1-1"])
  }

  @Test("A failed project load shows the failure; Retry loads the saved project again")
  func projectLoadFailure() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    await service.setProjectIssuesError(LinearAPIError.network("offline"))

    await viewModel.selectProject("p1")
    #expect(viewModel.loadState == .failed("offline"))
    #expect(viewModel.selectedProjectID == "p1")

    await service.setProjectIssuesError(nil)
    await viewModel.load(keepsBoardOnFailure: true)
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.issues.map(\.id) == ["p1-1", "p1-2"])
  }

  @Test("A team switch during a project load wins; the late project answer is dropped")
  func teamSwitchDuringProjectLoad() async {
    let service = MockLinearService()
    let viewModel = await loadedViewModel(service)
    await service.holdProjectIssues()

    let pick = Task { await viewModel.selectProject("p1") }
    while await service.projectIssueCalls.isEmpty { await Task.yield() }
    await viewModel.selectTeam("t2")
    #expect(viewModel.selectedTeamID == "t2")
    #expect(viewModel.loadState == .loaded)

    await service.releaseProjectIssues()
    await pick.value

    #expect(viewModel.selectedTeamID == "t2")
    #expect(viewModel.selectedProjectID == nil)
    #expect(viewModel.projects == [MockLinearService.design])
    #expect(viewModel.issues.map(\.id) == ["todo-1", "todo-2", "doing-1"])
    #expect(viewModel.loadState == .loaded)
  }

  @Test("Without a key the board asks to connect and never calls Linear")
  func noKey() async {
    let service = MockLinearService()
    let viewModel = LinearViewModel(service: service, userDefaults: .standard, hasAPIKey: { false })
    await viewModel.load()
    #expect(viewModel.loadState == .noKey)
    #expect(await service.viewerCalls == 0)
  }
}

private actor MockLinearService: LinearIssueReading, LinearIssueTransitioning {
  private var error: Error?
  private(set) var viewerCalls = 0

  func setError(_ value: Error?) { error = value }

  static let todo = LinearWorkflowState(id: "s-todo", name: "Todo", type: "unstarted", position: 0, color: "")
  static let doing = LinearWorkflowState(id: "s-doing", name: "In Progress", type: "started", position: 1, color: "")

  func viewer() async throws -> LinearUser {
    viewerCalls += 1
    if let error { throw error }
    return LinearUser(id: "me", name: "Joey")
  }

  func teams() async throws -> [LinearTeam] { [LinearTeam(id: "t1", name: "XFA", key: "XFA")] }

  func activeCycle(teamID: String) async throws -> LinearCycle? {
    if let error { throw error }
    return LinearCycle(id: "c1", number: 12, name: nil, startsAt: Date(), endsAt: Date().addingTimeInterval(86_400))
  }

  private(set) var workflowStateCalls = 0
  private var holdsWorkflowStates = false
  private var workflowStatesHold: CheckedContinuation<Void, Never>?

  func holdWorkflowStates() { holdsWorkflowStates = true }

  func releaseWorkflowStates() {
    holdsWorkflowStates = false
    workflowStatesHold?.resume()
    workflowStatesHold = nil
  }

  func workflowStates(teamID: String) async throws -> [LinearWorkflowState] {
    workflowStateCalls += 1
    if holdsWorkflowStates { await withCheckedContinuation { workflowStatesHold = $0 } }
    if let error { throw error }
    return [Self.todo, Self.doing]
  }

  func cycleIssues(cycleID: String) async throws -> [LinearIssue] {
    if let error { throw error }
    return [
      LinearIssue(id: "todo-1", identifier: "XFA-1", title: "One", state: Self.todo),
      LinearIssue(
        id: "todo-2", identifier: "XFA-2", title: "Two", state: Self.todo,
        assignee: LinearUser(id: "me", name: "Joey")),
      LinearIssue(id: "doing-1", identifier: "XFA-3", title: "Three", state: Self.doing),
    ]
  }

  func assignedIssues(userID: String) async throws -> [LinearIssue] { [] }

  // MARK: Projects

  static let onboarding = LinearProject(id: "p1", name: "Onboarding")
  static let billing = LinearProject(id: "p2", name: "Billing")
  static let design = LinearProject(id: "p3", name: "Design system")

  private var projectsByTeam: [String: [LinearProject]] = [
    "t1": [MockLinearService.billing, MockLinearService.onboarding],
    "t2": [MockLinearService.design],
  ]
  private(set) var projectIssueCalls: [ProjectIssuesCall] = []
  private var projectIssuesError: Error?
  private var holdsProjectIssues = false
  private var projectIssuesHold: CheckedContinuation<Void, Never>?

  func setProjects(_ projects: [LinearProject], team: String) { projectsByTeam[team] = projects }
  func setProjectIssuesError(_ value: Error?) { projectIssuesError = value }
  func holdProjectIssues() { holdsProjectIssues = true }

  func releaseProjectIssues() {
    holdsProjectIssues = false
    projectIssuesHold?.resume()
    projectIssuesHold = nil
  }

  func projects(teamID: String) async throws -> [LinearProject] {
    if let error { throw error }
    return LinearProject.sortedByName(projectsByTeam[teamID] ?? [])
  }

  func projectIssues(projectID: String, teamID: String) async throws -> [LinearIssue] {
    projectIssueCalls.append(ProjectIssuesCall(projectID: projectID, teamID: teamID))
    if holdsProjectIssues { await withCheckedContinuation { projectIssuesHold = $0 } }
    if let projectIssuesError { throw projectIssuesError }
    let project = [Self.onboarding, Self.billing, Self.design].first { $0.id == projectID }
    return [
      LinearIssue(
        id: "\(projectID)-1", identifier: "XFA-10", title: "Project mine", state: Self.todo,
        assignee: LinearUser(id: "me", name: "Joey"), project: project),
      LinearIssue(
        id: "\(projectID)-2", identifier: "XFA-11", title: "Project other", state: Self.doing,
        assignee: LinearUser(id: "someone", name: "Sam"), project: project),
    ]
  }

  func issue(id: String) async throws -> LinearIssue {
    throw LinearAPIError.graphQL(["not in mock"])
  }

  private(set) var transitions: [TransitionCall] = []
  private var transitionError: Error?

  func setTransitionError(_ value: Error?) { transitionError = value }

  func transitionIssue(id: String, stateID: String) async throws {
    if let transitionError { throw transitionError }
    transitions.append(TransitionCall(issueID: id, stateID: stateID))
  }
}

private struct ProjectIssuesCall: Equatable, Sendable {
  let projectID: String
  let teamID: String
}

private struct TransitionCall: Equatable, Sendable {
  let issueID: String
  let stateID: String
}
