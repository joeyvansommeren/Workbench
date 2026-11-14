//
//  TicketDetailPresentation.swift
//  AgentHub
//
//  Tracker-neutral data for the shell's ticket detail panel. A Jira ticket
//  and a Linear issue map to the same `SprintTicketDetail`, so one view
//  (`TicketDetailView`) draws both. Pure: no views, no view models.
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation

/// Colour of a tag or chip in the detail. Maps to the status token sets.
enum SprintDetailTone: Equatable {
  case neutral
  case working
  case ready
  case attention
  case error
}

/// A priority, type or label tag under the title.
struct SprintDetailTag: Identifiable, Equatable {
  enum Kind: String, Equatable {
    case priority
    case type
    case label
  }

  let kind: Kind
  let text: String
  var tone: SprintDetailTone = .neutral
  /// A Linear label's own colour (hex), drawn as a dot before the text.
  var colorHex: String?

  var id: String { "\(kind.rawValue):\(text)" }

  var accessibilityLabel: String {
    switch kind {
    case .priority: return "Priority: \(text)"
    case .type: return "Type: \(text)"
    case .label: return "Label: \(text)"
    }
  }
}

/// The ticket's status chip and where it can move.
struct SprintDetailStatus: Equatable {
  let name: String
  let tone: SprintDetailTone
  /// The other columns of the board. Empty when the tracker cannot move tickets.
  let moveTargets: [SprintMoveTarget]
}

/// One agent session linked to the ticket.
struct SprintDetailSessionRow: Identifiable, Equatable {
  /// The link's item id; the host maps it back to its link to open it.
  let id: String
  let title: String
  /// `Claude Code · feat/branch · 5 min ago`.
  let subtitle: String
  let presentation: SessionStatusPresentation
  /// Still starting: cannot be opened yet.
  let isPending: Bool
}

/// One pull request that mentions the ticket.
struct SprintDetailPullRequestRow: Identifiable, Equatable {
  let id: String
  let title: String
  /// `repo #123`.
  let reference: String
  let stateWord: String
  let tone: SprintDetailTone
  let url: URL?
}

/// The pull request section (Jira only; Linear has no search).
struct SprintDetailPullRequests: Equatable {
  let rows: [SprintDetailPullRequestRow]
  let isLoading: Bool
  /// What to say when there are no rows; nil while the first search runs.
  let emptyText: String?
}

/// "Start session": its title, whether the primary half runs, and a short
/// reason when it cannot.
struct SprintDetailStart: Equatable {
  let title: String
  let isPrimaryEnabled: Bool
  let isStarting: Bool
  /// Shown under the button when nothing can start.
  let hint: String?

  static func make(
    hasProject: Bool, isStarting: Bool, isClaudeAvailable: Bool, isCodexAvailable: Bool
  ) -> SprintDetailStart {
    let hasAgent = isClaudeAvailable || isCodexAvailable
    let hint: String?
    if !hasAgent {
      hint = "Install Claude Code or Codex to start a session."
    } else if !hasProject {
      hint = "Choose a project to start a session."
    } else {
      hint = nil
    }
    return SprintDetailStart(
      title: isStarting ? "Starting…" : "Start session",
      isPrimaryEnabled: hasAgent && hasProject && !isStarting,
      isStarting: isStarting,
      hint: hint
    )
  }

  /// Whether the menu item for one agent runs.
  static func canStart(
    _ provider: SessionProviderKind, hasProject: Bool, isStarting: Bool,
    isClaudeAvailable: Bool, isCodexAvailable: Bool
  ) -> Bool {
    let isAvailable = provider == .claude ? isClaudeAvailable : isCodexAvailable
    return isAvailable && hasProject && !isStarting
  }
}

/// Everything the detail panel draws for one ticket.
struct SprintTicketDetail: Equatable {
  /// What the host selects by: Jira key or Linear issue id.
  let id: String
  /// `XFA-2311`.
  let key: String
  let title: String
  /// "Jira" or "Linear", for "Open in …".
  let trackerName: String
  let browseURL: URL?
  let status: SprintDetailStatus?
  let assigneeName: String?
  let tags: [SprintDetailTag]
  /// "Sprint" or "Cycle".
  let iterationLabel: String
  let iterationName: String?
  /// Markdown, ready for MarkdownUI. Nil when the ticket has none.
  let descriptionMarkdown: String?
  /// The full ticket (with its description) is still loading.
  let isLoadingDetail: Bool
  let sessions: [SprintDetailSessionRow]
  /// Nil hides the section (Linear).
  let pullRequests: SprintDetailPullRequests?

  var assigneeInitials: String? {
    guard let assigneeName else { return nil }
    let letters = assigneeName.split(separator: " ").prefix(2).compactMap(\.first)
    return letters.isEmpty ? nil : String(letters).uppercased()
  }
}

enum TicketDetailPresentation {
  // MARK: - Jira

  static func jira(
    ticket: JiraTicketSnapshot,
    sprintName: String?,
    isLoadingDetail: Bool,
    browseURL: URL?,
    columns: [JiraSprintViewModel.BoardColumn],
    linkedSessions: [JiraLinkedSession],
    pullRequests: [GitHubProjectPullRequest]?,
    isLoadingPullRequests: Bool,
    status: (SessionProviderKind, String) -> SessionStatus?,
    now: Date = Date()
  ) -> SprintTicketDetail {
    var tags: [SprintDetailTag] = []
    if let priority = jiraPriorityTag(ticket.priority) { tags.append(priority) }
    if let type = ticket.issueType?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
      tags.append(SprintDetailTag(kind: .type, text: type))
    }
    let statusName = ticket.status ?? "No status"
    return SprintTicketDetail(
      id: ticket.key,
      key: ticket.key,
      title: ticket.summary,
      trackerName: "Jira",
      browseURL: browseURL,
      status: SprintDetailStatus(
        name: statusName,
        tone: jiraTone(category: ticket.statusCategory),
        moveTargets: columns
          .filter { $0.status != statusName }
          .map { SprintMoveTarget(id: $0.id, title: $0.status) }
      ),
      assigneeName: ticket.assignee,
      tags: tags,
      iterationLabel: "Sprint",
      iterationName: sprintName,
      descriptionMarkdown: nonEmpty(ticket.description).map(markdown(fromPlainText:)),
      isLoadingDetail: isLoadingDetail,
      sessions: sessionRows(linkedSessions, status: status, now: now),
      pullRequests: pullRequestSection(
        ticketKey: ticket.key, pullRequests: pullRequests, isLoading: isLoadingPullRequests)
    )
  }

  /// Jira status categories: `new`, `indeterminate`, `done`.
  static func jiraTone(category: String?) -> SprintDetailTone {
    switch category {
    case "indeterminate": return .working
    case "done": return .ready
    default: return .neutral
    }
  }

  /// Hidden when Jira has no priority; the top priorities stand out.
  static func jiraPriorityTag(_ priority: String?) -> SprintDetailTag? {
    guard let priority = nonEmpty(priority), priority.lowercased() != "none" else { return nil }
    let urgent = ["highest", "blocker", "critical", "urgent"].contains(priority.lowercased())
    return SprintDetailTag(kind: .priority, text: priority, tone: urgent ? .attention : .neutral)
  }

  // MARK: - Linear

  static func linear(
    issue: LinearIssue,
    cycleName: String?,
    isLoadingDetail: Bool,
    linkedSessions: [LinearLinkedSession],
    status: (SessionProviderKind, String) -> SessionStatus?,
    now: Date = Date()
  ) -> SprintTicketDetail {
    var tags: [SprintDetailTag] = []
    // Linear priority 0 is "No priority"; 1 is Urgent.
    if issue.priority > 0 {
      tags.append(
        SprintDetailTag(
          kind: .priority, text: issue.priorityLabel, tone: issue.priority == 1 ? .attention : .neutral))
    }
    tags += issue.labels.map { SprintDetailTag(kind: .label, text: $0.name, colorHex: $0.color) }
    return SprintTicketDetail(
      id: issue.id,
      key: issue.identifier,
      title: issue.title,
      trackerName: "Linear",
      browseURL: URL(string: issue.url).flatMap { $0.scheme == nil ? nil : $0 },
      // The shell cannot move Linear issues yet (the board cannot either).
      status: SprintDetailStatus(
        name: issue.state.name, tone: linearTone(stateType: issue.state.type), moveTargets: []),
      assigneeName: issue.assignee?.name,
      tags: tags,
      iterationLabel: "Cycle",
      iterationName: cycleName,
      descriptionMarkdown: nonEmpty(issue.description),
      isLoadingDetail: isLoadingDetail,
      sessions: sessionRows(linkedSessions, status: status, now: now),
      pullRequests: nil
    )
  }

  /// Linear state types: `backlog`, `unstarted`, `started`, `completed`, `canceled`.
  static func linearTone(stateType: String) -> SprintDetailTone {
    switch stateType {
    case "started": return .working
    case "completed": return .ready
    default: return .neutral
    }
  }

  // MARK: - Sessions

  /// Starting and open sessions first, then the most recent.
  static func sessionRows<Link: SprintLinkedSession & Identifiable>(
    _ links: [Link],
    status: (SessionProviderKind, String) -> SessionStatus?,
    now: Date
  ) -> [SprintDetailSessionRow] where Link.ID == String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return links
      .sorted { lhs, rhs in
        let left = lhs.isPending || lhs.isMonitored
        let right = rhs.isPending || rhs.isMonitored
        return left == right ? lhs.lastActivityAt > rhs.lastActivityAt : left
      }
      .map { link in
        var parts = [SprintBoardItems.providerName(link.provider)]
        if let branch = link.branchName, !branch.isEmpty { parts.append(branch) }
        parts.append(formatter.localizedString(for: link.lastActivityAt, relativeTo: now))
        let sessionStatus = link.session.flatMap { status(link.provider, $0.id) }
        return SprintDetailSessionRow(
          id: link.id,
          title: link.title,
          subtitle: parts.joined(separator: " · "),
          presentation: SessionStatusPresentation(status: sessionStatus, isPending: link.isPending),
          isPending: link.isPending
        )
      }
  }

  // MARK: - Pull requests

  static func pullRequestSection(
    ticketKey: String, pullRequests: [GitHubProjectPullRequest]?, isLoading: Bool
  ) -> SprintDetailPullRequests {
    let rows = (pullRequests ?? []).map(pullRequestRow)
    let emptyText: String?
    if !rows.isEmpty || isLoading {
      emptyText = nil
    } else if pullRequests != nil {
      emptyText = "No pull requests mention \(ticketKey) yet."
    } else {
      emptyText = "GitHub not searched."
    }
    return SprintDetailPullRequests(rows: rows, isLoading: isLoading, emptyText: emptyText)
  }

  /// Same words and tones as the Reviews detail: Open, Merged, Closed, Draft.
  static func pullRequestRow(_ pullRequest: GitHubProjectPullRequest) -> SprintDetailPullRequestRow {
    let state = pullRequest.isDraft ? "draft" : pullRequest.state.lowercased()
    let word: String
    let tone: SprintDetailTone
    switch state {
    case "open": (word, tone) = ("Open", .ready)
    case "merged": (word, tone) = ("Merged", .working)
    case "closed": (word, tone) = ("Closed", .error)
    case "draft": (word, tone) = ("Draft", .neutral)
    default: (word, tone) = (pullRequest.state.capitalized, .neutral)
    }
    return SprintDetailPullRequestRow(
      id: pullRequest.url,
      title: pullRequest.title,
      reference: "\(pullRequest.repositoryName) #\(pullRequest.number)",
      stateWord: word,
      tone: tone,
      url: URL(string: pullRequest.url)
    )
  }

  // MARK: - Description

  /// Long descriptions show this many characters until "Show all".
  static let descriptionCharacterLimit = 1200

  /// The first part of a long description, cut at a paragraph break when one
  /// is near the limit, so Markdown blocks (lists, code) stay whole.
  static func cappedDescription(
    _ text: String, limit: Int = descriptionCharacterLimit
  ) -> (text: String, isCapped: Bool) {
    guard text.count > limit else { return (text, false) }
    let head = String(text.prefix(limit))
    if let breakRange = head.range(of: "\n\n", options: .backwards),
      head.distance(from: head.startIndex, to: breakRange.lowerBound) >= limit / 2
    {
      return (String(head[..<breakRange.lowerBound]), true)
    }
    if let space = head.lastIndex(where: \.isWhitespace),
      head.distance(from: head.startIndex, to: space) >= limit / 2
    {
      return (String(head[..<space]) + "…", true)
    }
    return (head + "…", true)
  }

  /// Jira descriptions arrive as plain text (`ACLITicketReader` flattens
  /// Atlassian's format): paragraphs split by a blank line, list items by one
  /// newline. Markdown would join single newlines into one line, so they
  /// become hard breaks.
  static func markdown(fromPlainText text: String) -> String {
    text
      .components(separatedBy: "\n\n")
      .map { paragraph in
        paragraph
          .split(separator: "\n", omittingEmptySubsequences: false)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .joined(separator: "  \n")
      }
      .joined(separator: "\n\n")
  }

  private static func nonEmpty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }
}
