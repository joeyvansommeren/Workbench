import AgentWorkflowJiraCLI
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint tracker")
struct SprintTrackerTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "SprintTrackerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("Without a saved tracker, Sprint opens on Jira when acli is installed")
  func defaultsToJiraWithACLI() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    #expect(model.sprintTracker == .jira)
  }

  @Test("Without a saved tracker, Sprint opens on Linear when acli is missing")
  func defaultsToLinearWithoutACLI() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { false })
    #expect(model.sprintTracker == .linear)
  }

  @Test("A saved tracker wins over the default rule, and acli is not checked")
  func savedTrackerWins() {
    let defaults = makeDefaults()
    defaults.set("jira", forKey: AgentHubDefaults.sprintTracker)
    var checked = false
    let model = WorkbenchShellModel(
      defaults: defaults,
      isJiraCLIAvailable: {
        checked = true
        return false
      })
    #expect(model.sprintTracker == .jira)
    #expect(!checked)
  }

  @Test("Switching the tracker persists it for the next window")
  func persistence() {
    let defaults = makeDefaults()
    let model = WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true })
    model.setSprintTracker(.linear)
    #expect(defaults.string(forKey: AgentHubDefaults.sprintTracker) == "linear")
    #expect(
      WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true }).sprintTracker == .linear)

    model.setSprintTracker(.jira)
    #expect(
      WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { false }).sprintTracker == .jira)
  }

  @Test("The Sprint count is your open tickets on the selected tracker")
  func counts() async {
    let jira = JiraSprintViewModel(service: CountingJiraService(), userDefaults: makeDefaults())
    let linear = LinearViewModel(userDefaults: makeDefaults())
    await jira.load()

    // XFA-1 is mine and open; XFA-2 is mine but done; XFA-3 is someone else's.
    #expect(SprintTracker.jira.myOpenCount(jira: jira, linear: linear) == 1)
    // Linear has not loaded a viewer, so nothing is "mine" yet.
    #expect(SprintTracker.linear.myOpenCount(jira: jira, linear: linear) == 0)
  }

  @Test("All | Mine labels")
  func scopeLabels() {
    #expect(SprintAssigneeScope.allCases.map(\.description) == ["All", "Mine"])
  }
}

private actor CountingJiraService: JiraTicketReading, JiraTicketSearching, JiraAuthenticating,
  JiraBoardBrowsing, JiraTicketTransitioning
{
  func searchTickets(jql: String, limit: Int) async throws -> [JiraTicketSnapshot] {
    [
      JiraTicketSnapshot(
        key: "XFA-1", summary: "Open", status: "To Do", assignee: "Me", assigneeAccountId: "me",
        assigneeEmail: "me@xfa.tech", statusCategory: "new"),
      JiraTicketSnapshot(
        key: "XFA-2", summary: "Done", status: "Done", assignee: "Me", assigneeAccountId: "me",
        assigneeEmail: "me@xfa.tech", statusCategory: "done"),
      JiraTicketSnapshot(
        key: "XFA-3", summary: "Theirs", status: "To Do", assignee: "Them",
        assigneeAccountId: "them", assigneeEmail: "them@xfa.tech", statusCategory: "new"),
    ]
  }

  func ticket(key: String) async throws -> JiraTicketSnapshot {
    throw JiraTicketReaderError.invalidResponse
  }
  func authenticate() async throws {}
  func currentAccount() async throws -> JiraAccount {
    JiraAccount(site: "xfa.atlassian.net", email: "ME@xfa.tech")
  }
  func boards() async throws -> [JiraBoard] { [JiraBoard(id: 1, name: "Board")] }
  func openSprints(boardID: Int) async throws -> [JiraSprint] {
    [JiraSprint(id: 7, name: "Sprint 47", state: "active")]
  }
  func transition(key: String, toStatus status: String) async throws {}
}
