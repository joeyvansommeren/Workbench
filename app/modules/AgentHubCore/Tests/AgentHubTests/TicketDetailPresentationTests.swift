import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Ticket detail presentation")
struct TicketDetailPresentationTests {
  private static let noStatus: (SessionProviderKind, String) -> SessionStatus? = { _, _ in nil }
  private static let now = Date(timeIntervalSince1970: 2_000_000)

  private static let columns = [
    JiraSprintViewModel.BoardColumn(status: "To Do", category: "new", tickets: []),
    JiraSprintViewModel.BoardColumn(status: "In Progress", category: "indeterminate", tickets: []),
    JiraSprintViewModel.BoardColumn(status: "Done", category: "done", tickets: []),
  ]

  private static func pullRequest(_ number: Int, state: String, isDraft: Bool = false)
    -> GitHubProjectPullRequest
  {
    GitHubProjectPullRequest(
      id: "\(number)", number: number, title: "PR \(number)",
      url: "https://github.com/o/r/pull/\(number)",
      repositoryName: "r", repositoryNameWithOwner: "o/r", authorLogin: nil, updatedAt: nil,
      isDraft: isDraft, state: state, projectStatus: nil, projectPriority: nil)
  }

  private static func jiraLink(
    _ id: String, pending: Bool = false, monitored: Bool = false, minutesAgo: Double,
    sessionID: String? = nil, branch: String? = nil
  ) -> JiraLinkedSession {
    JiraLinkedSession(
      provider: .claude, itemID: id, title: "Session \(id)", branchName: branch,
      lastActivityAt: now.addingTimeInterval(-minutesAgo * 60), isPending: pending,
      isMonitored: monitored,
      session: sessionID.map { CLISession(id: $0, projectPath: "/tmp/repo") })
  }

  private static func jira(
    _ ticket: JiraTicketSnapshot,
    links: [JiraLinkedSession] = [],
    pullRequests: [GitHubProjectPullRequest]? = nil,
    isLoadingPullRequests: Bool = false,
    status: (SessionProviderKind, String) -> SessionStatus? = noStatus
  ) -> SprintTicketDetail {
    TicketDetailPresentation.jira(
      ticket: ticket, sprintName: "Sprint 47", isLoadingDetail: false,
      browseURL: URL(string: "https://x.atlassian.net/browse/\(ticket.key)"),
      columns: columns, linkedSessions: links, pullRequests: pullRequests,
      isLoadingPullRequests: isLoadingPullRequests, status: status, now: now)
  }

  // MARK: - Jira

  @Test("A Jira ticket maps key, status tone, Move To targets, tags and sprint")
  func jiraTicket() {
    let ticket = JiraTicketSnapshot(
      key: "XFA-2311", summary: "Copy link gives no confirmation", issueType: "Bug",
      status: "In Progress", assignee: "Gijs Peeters", statusCategory: "indeterminate",
      priority: "Highest")
    let detail = Self.jira(ticket)

    #expect(detail.key == "XFA-2311")
    #expect(detail.trackerName == "Jira")
    #expect(detail.status?.name == "In Progress")
    #expect(detail.status?.tone == .working)
    // Every other column, never the current one.
    #expect(detail.status?.moveTargets.map(\.id) == ["To Do", "Done"])
    #expect(detail.tags.map(\.text) == ["Highest", "Bug"])
    #expect(detail.tags.first?.tone == .attention)
    #expect(detail.assigneeInitials == "GP")
    #expect(detail.iterationLabel == "Sprint")
    #expect(detail.iterationName == "Sprint 47")
    #expect(detail.pullRequests != nil)
  }

  @Test("No priority, no type and no assignee leave no tags and no initials")
  func jiraSparseTicket() {
    let detail = Self.jira(JiraTicketSnapshot(key: "XFA-1", summary: "x", priority: "None"))
    #expect(detail.tags.isEmpty)
    #expect(detail.assigneeName == nil)
    #expect(detail.assigneeInitials == nil)
    #expect(detail.status?.name == "No status")
    #expect(detail.status?.tone == .neutral)
    #expect(detail.descriptionMarkdown == nil)
  }

  @Test("Jira status categories map to tones")
  func jiraTones() {
    #expect(TicketDetailPresentation.jiraTone(category: "new") == .neutral)
    #expect(TicketDetailPresentation.jiraTone(category: "indeterminate") == .working)
    #expect(TicketDetailPresentation.jiraTone(category: "done") == .ready)
    #expect(TicketDetailPresentation.jiraTone(category: nil) == .neutral)
  }

  @Test("Jira plain text keeps its line breaks as Markdown hard breaks")
  func jiraDescription() {
    let ticket = JiraTicketSnapshot(
      key: "XFA-1", summary: "x", description: "Steps:\n• one\n• two\n\nExpected: a toast.")
    #expect(Self.jira(ticket).descriptionMarkdown == "Steps:  \n• one  \n• two\n\nExpected: a toast.")
  }

  // MARK: - Pull requests

  @Test("Pull requests: not searched, searching, none, found")
  func pullRequestSection() {
    let notSearched = TicketDetailPresentation.pullRequestSection(
      ticketKey: "XFA-1", pullRequests: nil, isLoading: false)
    #expect(notSearched.emptyText == "GitHub not searched.")

    let searching = TicketDetailPresentation.pullRequestSection(
      ticketKey: "XFA-1", pullRequests: nil, isLoading: true)
    #expect(searching.emptyText == nil)
    #expect(searching.isLoading)

    let none = TicketDetailPresentation.pullRequestSection(
      ticketKey: "XFA-1", pullRequests: [], isLoading: false)
    #expect(none.emptyText == "No pull requests mention XFA-1 yet.")

    let found = TicketDetailPresentation.pullRequestSection(
      ticketKey: "XFA-1",
      pullRequests: [
        Self.pullRequest(1, state: "OPEN"), Self.pullRequest(2, state: "MERGED"),
        Self.pullRequest(3, state: "CLOSED"), Self.pullRequest(4, state: "OPEN", isDraft: true),
      ],
      isLoading: false)
    #expect(found.emptyText == nil)
    #expect(found.rows.map(\.stateWord) == ["Open", "Merged", "Closed", "Draft"])
    #expect(found.rows.map(\.tone) == [.ready, .working, .error, .neutral])
    #expect(found.rows.first?.reference == "r #1")
    #expect(found.rows.first?.url?.absoluteString == "https://github.com/o/r/pull/1")
  }

  // MARK: - Sessions

  @Test("Sessions: starting and open first, then newest; live status and word")
  func sessionRows() {
    let links = [
      Self.jiraLink("old", minutesAgo: 120),
      Self.jiraLink("new", minutesAgo: 5),
      Self.jiraLink("open", monitored: true, minutesAgo: 60, sessionID: "s1", branch: "feat/x"),
      Self.jiraLink("starting", pending: true, minutesAgo: 0),
    ]
    let rows = TicketDetailPresentation.sessionRows(
      links, status: { _, id in id == "s1" ? .waitingForUser : nil }, now: Self.now)

    #expect(rows.map(\.id) == ["starting", "open", "new", "old"])
    #expect(rows[0].isPending)
    #expect(rows[0].presentation == SessionStatusPresentation(status: nil, isPending: true))
    #expect(rows[1].presentation == SessionStatusPresentation(status: .waitingForUser))
    #expect(rows[1].subtitle.hasPrefix("Claude Code · feat/x · "))
    #expect(!rows[2].isPending)
  }

  // MARK: - Linear

  @Test("A Linear issue moves to the other board states")
  func linearMoveTargets() {
    let todo = LinearWorkflowState(id: "s-todo", name: "Todo", type: "unstarted", position: 0, color: "")
    let doing = LinearWorkflowState(id: "s-doing", name: "In Progress", type: "started", position: 1, color: "")
    let done = LinearWorkflowState(id: "s-done", name: "Done", type: "completed", position: 2, color: "")
    let detail = TicketDetailPresentation.linear(
      issue: LinearIssue(id: "i", identifier: "ENG-1", title: "x", state: doing),
      cycleName: nil, isLoadingDetail: false, linkedSessions: [],
      moveStates: [todo, doing, done], status: Self.noStatus, now: Self.now)
    #expect(detail.status?.moveTargets.map(\.id) == ["s-todo", "s-done"])
    #expect(detail.status?.moveTargets.map(\.title) == ["Todo", "Done"])
  }

  @Test("A Linear issue maps state tone, priority, labels and cycle; no states, no moves")
  func linearIssue() {
    let state = LinearWorkflowState(id: "s", name: "In Progress", type: "started", position: 1, color: "")
    let issue = LinearIssue(
      id: "id-1", identifier: "ENG-12", title: "Retry org service", description: "**Bold**",
      priority: 1, priorityLabel: "Urgent", state: state,
      assignee: LinearUser(id: "u", name: "Ana Maes"),
      labels: [LinearLabel(id: "l", name: "Backend", color: "#4EA7FC")],
      url: "https://linear.app/x/issue/ENG-12")
    let detail = TicketDetailPresentation.linear(
      issue: issue, cycleName: "Cycle 12", isLoadingDetail: false, linkedSessions: [],
      status: Self.noStatus, now: Self.now)

    #expect(detail.id == "id-1")
    #expect(detail.key == "ENG-12")
    #expect(detail.trackerName == "Linear")
    #expect(detail.browseURL?.absoluteString == "https://linear.app/x/issue/ENG-12")
    #expect(detail.status?.tone == .working)
    #expect(detail.status?.moveTargets.isEmpty == true)
    #expect(detail.tags.map(\.text) == ["Urgent", "Backend"])
    #expect(detail.tags[0].tone == .attention)
    #expect(detail.tags[1].colorHex == "#4EA7FC")
    #expect(detail.iterationLabel == "Cycle")
    // Linear descriptions are Markdown already.
    #expect(detail.descriptionMarkdown == "**Bold**")
    // No pull request search for Linear.
    #expect(detail.pullRequests == nil)
  }

  @Test("No priority and an empty URL hide the priority tag and Open in Linear")
  func linearSparseIssue() {
    let state = LinearWorkflowState(id: "s", name: "Todo", type: "unstarted", position: 0, color: "")
    let detail = TicketDetailPresentation.linear(
      issue: LinearIssue(id: "i", identifier: "ENG-1", title: "x", state: state),
      cycleName: nil, isLoadingDetail: true, linkedSessions: [], status: Self.noStatus, now: Self.now)
    #expect(detail.tags.isEmpty)
    #expect(detail.browseURL == nil)
    #expect(detail.status?.tone == .neutral)
    #expect(detail.isLoadingDetail)
  }

  // MARK: - Description headings

  @Test("Description headings never outrank the panel title")
  func descriptionHeadingsStayBelowTitle() {
    #expect(DescriptionMarkdownHeading.style(level: 1) == .title3)
    #expect(DescriptionMarkdownHeading.style(level: 2) == .headline)
    for level in 3...6 {
      #expect(DescriptionMarkdownHeading.style(level: level) == .bodyEmphasis)
    }
    for level in 1...6 {
      #expect(DescriptionMarkdownHeading.style(level: level).size < WorkbenchTextStyle.title2.size)
    }
  }

  // MARK: - Description cap

  @Test("Short descriptions are not capped")
  func shortDescription() {
    let capped = TicketDetailPresentation.cappedDescription("Short.", limit: 100)
    #expect(capped.text == "Short.")
    #expect(!capped.isCapped)
  }

  @Test("Long descriptions cut at a paragraph break near the limit")
  func cappedAtParagraph() {
    let first = String(repeating: "a", count: 70)
    let text = first + "\n\n" + String(repeating: "b", count: 100)
    let capped = TicketDetailPresentation.cappedDescription(text, limit: 100)
    #expect(capped.isCapped)
    #expect(capped.text == first)
  }

  @Test("Without a near paragraph break the cut falls on a space, with an ellipsis")
  func cappedAtSpace() {
    let text = Array(repeating: "word", count: 40).joined(separator: " ")
    let capped = TicketDetailPresentation.cappedDescription(text, limit: 100)
    #expect(capped.isCapped)
    #expect(capped.text.hasSuffix("word…"))
    #expect(capped.text.count <= 101)
  }

  // MARK: - Start

  @Test("Start session needs an agent and a project, and is off while starting")
  func start() {
    let ready = SprintDetailStart.make(
      hasProject: true, isStarting: false, isClaudeAvailable: true, isCodexAvailable: false)
    #expect(ready.isPrimaryEnabled)
    #expect(ready.title == "Start session")
    #expect(ready.hint == nil)

    let noProject = SprintDetailStart.make(
      hasProject: false, isStarting: false, isClaudeAvailable: true, isCodexAvailable: true)
    #expect(!noProject.isPrimaryEnabled)
    #expect(noProject.hint == "Choose a project to start a session.")

    let noAgent = SprintDetailStart.make(
      hasProject: true, isStarting: false, isClaudeAvailable: false, isCodexAvailable: false)
    #expect(!noAgent.isPrimaryEnabled)
    #expect(noAgent.hint == "Install Claude Code or Codex to start a session.")

    let starting = SprintDetailStart.make(
      hasProject: true, isStarting: true, isClaudeAvailable: true, isCodexAvailable: true)
    #expect(!starting.isPrimaryEnabled)
    #expect(starting.title == "Starting…")

    #expect(
      !SprintDetailStart.canStart(
        .claude, hasProject: true, isStarting: false, isClaudeAvailable: false, isCodexAvailable: true))
    #expect(
      SprintDetailStart.canStart(
        .codex, hasProject: true, isStarting: false, isClaudeAvailable: false, isCodexAvailable: true))
  }
}
