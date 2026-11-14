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

  private func loadedViewModel(_ service: MockLinearService) async -> LinearViewModel {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("everyone", forKey: AgentHubDefaults.linearAssigneeFilter)
    let viewModel = LinearViewModel(service: service, userDefaults: defaults, hasAPIKey: { true })
    await viewModel.load()
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
    await viewModel.load()
    #expect(viewModel.loadState == .loaded)
    #expect(viewModel.issues.count == 3)
    #expect(
      viewModel.refreshError == "Could not refresh Linear: The Internet connection appears to be offline.")

    await service.setError(LinearAPIError.rateLimited)
    await viewModel.load()
    #expect(viewModel.refreshError == LinearViewModel.rateLimitedMessage)

    await service.setError(nil)
    await viewModel.load()
    #expect(viewModel.refreshError == nil)

    await service.setError(LinearAPIError.unauthorized)
    await viewModel.load()
    #expect(viewModel.loadState == .unauthorized)
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

  func workflowStates(teamID: String) async throws -> [LinearWorkflowState] {
    if let error { throw error }
    return [Self.todo, Self.doing]
  }

  func cycleIssues(cycleID: String) async throws -> [LinearIssue] {
    if let error { throw error }
    return [
      LinearIssue(id: "todo-1", identifier: "XFA-1", title: "One", state: Self.todo),
      LinearIssue(id: "todo-2", identifier: "XFA-2", title: "Two", state: Self.todo),
      LinearIssue(id: "doing-1", identifier: "XFA-3", title: "Three", state: Self.doing),
    ]
  }

  func assignedIssues(userID: String) async throws -> [LinearIssue] { [] }

  func issue(id: String) async throws -> LinearIssue {
    throw LinearAPIError.graphQL(["not in mock"])
  }

  func transitionIssue(id: String, stateID: String) async throws {}
}
