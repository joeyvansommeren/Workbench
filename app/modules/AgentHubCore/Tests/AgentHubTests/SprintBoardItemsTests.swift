import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint board items")
struct SprintBoardItemsTests {
  private static let noStatus: (SessionProviderKind, String) -> SessionStatus? = { _, _ in nil }

  private static func pullRequest(_ number: Int, state: String) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: "\(number)", number: number, title: "x", url: "https://github.com/o/r/pull/\(number)",
      repositoryName: "r", repositoryNameWithOwner: "o/r", authorLogin: nil, updatedAt: nil,
      isDraft: false, state: state, projectStatus: nil, projectPriority: nil)
  }

  private static func session(
    _ provider: SessionProviderKind, id: String, monitored: Bool, minutesAgo: Double
  ) -> SprintLinkedSessionSummary {
    SprintLinkedSessionSummary(
      provider: provider, sessionID: id, isPending: false, isMonitored: monitored,
      lastActivityAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60))
  }

  @Test("Done wins over sessions and pull requests")
  func doneFirst() {
    let footer = SprintBoardItems.footer(
      isDone: true, sessions: [Self.session(.claude, id: "a", monitored: true, minutesAgo: 1)],
      pullRequests: [Self.pullRequest(1, state: "merged")], status: Self.noStatus)
    #expect(footer == .done)
  }

  @Test("A monitored session wins over a newer unmonitored one and shows its live status")
  func sessionFooter() {
    let footer = SprintBoardItems.footer(
      isDone: false,
      sessions: [
        Self.session(.claude, id: "old", monitored: true, minutesAgo: 30),
        Self.session(.codex, id: "new", monitored: false, minutesAgo: 1),
      ],
      pullRequests: nil,
      status: { provider, id in provider == .claude && id == "old" ? .thinking : nil })
    #expect(
      footer
        == .session(
          providerName: "Claude Code", presentation: SessionStatusPresentation(status: .thinking)))
  }

  @Test("Without a session, the open pull request shows")
  func pullRequestFooter() {
    let footer = SprintBoardItems.footer(
      isDone: false, sessions: [],
      pullRequests: [Self.pullRequest(7, state: "merged"), Self.pullRequest(9, state: "OPEN")],
      status: Self.noStatus)
    #expect(footer == .pullRequest(number: 9, isMerged: false))
    #expect(
      SprintBoardItems.footer(isDone: false, sessions: [], pullRequests: [], status: Self.noStatus)
        == nil)
  }

  @Test("A merged PR shows as Merged; a single closed PR gets no footer")
  func mergedAndClosedPullRequests() {
    let merged = SprintBoardItems.footer(
      isDone: false, sessions: [],
      pullRequests: [Self.pullRequest(3, state: "CLOSED"), Self.pullRequest(4, state: "MERGED")],
      status: Self.noStatus)
    #expect(merged == .pullRequest(number: 4, isMerged: true))

    let closed = SprintBoardItems.footer(
      isDone: false, sessions: [], pullRequests: [Self.pullRequest(5, state: "CLOSED")],
      status: Self.noStatus)
    #expect(closed == nil)
  }

  @Test("Linear columns map issues to cards; completed is Done, linked sessions show")
  func linearMapping() {
    let started = LinearWorkflowState(
      id: "s", name: "In Progress", type: "started", position: 1, color: "#f2c94c")
    let completed = LinearWorkflowState(
      id: "c", name: "Done", type: "completed", position: 2, color: "#5e6ad2")
    let open = LinearIssue(
      id: "issue-1", identifier: "WB-12", title: "Sprint board", state: started,
      assignee: LinearUser(id: "u", name: "Ann Maes"))
    let done = LinearIssue(id: "issue-2", identifier: "WB-9", title: "Old work", state: completed)
    let link = LinearLinkedSession(
      provider: .codex, itemID: "item", title: "WB-12", branchName: nil, lastActivityAt: .now,
      isPending: false, isMonitored: true, session: CLISession(id: "s1", projectPath: "/tmp"))

    let items = SprintBoardItems.linear(
      columns: [
        LinearViewModel.BoardColumn(state: started, issues: [open]),
        LinearViewModel.BoardColumn(state: completed, issues: [done]),
      ],
      linkedSessions: ["WB-12": [link]],
      status: { provider, id in provider == .codex && id == "s1" ? .waitingForUser : nil })

    #expect(items.map(\.id) == ["s", "c"])
    #expect(items.map(\.title) == ["In Progress", "Done"])
    let openCard = items[0].tickets[0]
    #expect(openCard.id == "issue-1")
    #expect(openCard.key == "WB-12")
    #expect(openCard.title == "Sprint board")
    #expect(openCard.assigneeInitials == "AM")
    #expect(
      openCard.footer
        == .session(
          providerName: "Codex", presentation: SessionStatusPresentation(status: .waitingForUser)))
    let doneCard = items[1].tickets[0]
    #expect(doneCard.key == "WB-9")
    #expect(doneCard.isDone)
    #expect(doneCard.footer == .done)
    #expect(doneCard.assigneeInitials == nil)
  }

  @Test("A footer click opens a monitored session, else the newest; never one still starting")
  func sessionToOpen() {
    func link(_ id: String, monitored: Bool, pending: Bool, minutesAgo: Double) -> JiraLinkedSession {
      JiraLinkedSession(
        provider: .claude, itemID: id, title: id, branchName: nil,
        lastActivityAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
        isPending: pending, isMonitored: monitored, session: nil)
    }
    let monitored = link("monitored", monitored: true, pending: false, minutesAgo: 60)
    let newest = link("newest", monitored: false, pending: false, minutesAgo: 1)
    let starting = link("starting", monitored: true, pending: true, minutesAgo: 0)

    #expect(SprintBoardItems.sessionToOpen([newest, monitored, starting])?.id == "monitored")
    #expect(SprintBoardItems.sessionToOpen([newest, starting])?.id == "newest")
    #expect(SprintBoardItems.sessionToOpen([starting]) == nil)
  }

  @Test("Jira columns map to cards with initials; Start hides on done tickets")
  func jiraMapping() {
    let columns = [
      JiraSprintViewModel.BoardColumn(
        status: "To Do", category: "new",
        tickets: [
          JiraTicketSnapshot(
            key: "XFA-1", summary: "Filter", status: "To Do", assignee: "Joey van Sommeren",
            statusCategory: "new")
        ]),
      JiraSprintViewModel.BoardColumn(
        status: "Done", category: "done",
        tickets: [
          JiraTicketSnapshot(key: "XFA-2", summary: "Old", status: "Done", statusCategory: "done")
        ]),
    ]
    let items = SprintBoardItems.jira(
      columns: columns, linkedSessions: [:], pullRequests: [:], status: Self.noStatus)
    #expect(items.map(\.title) == ["To Do", "Done"])
    let open = items[0].tickets[0]
    #expect(open.key == "XFA-1")
    #expect(open.assigneeInitials == "JV")
    #expect(open.canStart)
    let done = items[1].tickets[0]
    #expect(done.footer == .done)
    #expect(!done.canStart)
    #expect(done.assigneeInitials == nil)
  }

  @Test("A ticket with a session cannot be started again from the card")
  func sessionHidesStart() {
    let item = SprintTicketItem(
      id: "XFA-3", key: "XFA-3", title: "Busy", assigneeName: nil, isDone: false,
      footer: .session(providerName: "Codex", presentation: SessionStatusPresentation(status: nil)))
    #expect(!item.canStart)
  }

  @Test("Card Start prefers Claude Code, then Codex")
  func startProvider() {
    #expect(SprintStartProvider.preferred(isClaudeAvailable: true, isCodexAvailable: true) == .claude)
    #expect(SprintStartProvider.preferred(isClaudeAvailable: false, isCodexAvailable: true) == .codex)
    #expect(SprintStartProvider.preferred(isClaudeAvailable: false, isCodexAvailable: false) == nil)
    // The detail panel's explicit choice wins.
    #expect(
      SprintStartProvider.resolve(.codex, isClaudeAvailable: true, isCodexAvailable: true) == .codex)
    #expect(
      SprintStartProvider.resolve(nil, isClaudeAvailable: true, isCodexAvailable: true) == .claude)
  }
}
