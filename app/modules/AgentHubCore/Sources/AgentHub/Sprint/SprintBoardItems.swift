//
//  SprintBoardItems.swift
//  AgentHub
//
//  Tracker-neutral data for the shell's Sprint board. Jira tickets and Linear
//  issues map to the same columns and cards, so one set of views draws both.
//

import AgentHubGitHub
import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation
import SwiftUI

/// The one line under a ticket title (`.ticket-foot` in the prototype).
enum SprintTicketFooter: Equatable {
  /// An agent session works on the ticket.
  case session(providerName: String, presentation: SessionStatusPresentation)
  case pullRequest(number: Int, isMerged: Bool)
  case done
}

struct SprintTicketItem: Identifiable, Equatable {
  /// Jira ticket key or Linear issue id: what the view model selects by.
  let id: String
  /// What the card shows: `XFA-2335`.
  let key: String
  let title: String
  let assigneeName: String?
  let isDone: Bool
  let footer: SprintTicketFooter?

  /// Hover "Start session" shows on open tickets without a session.
  var canStart: Bool {
    guard !isDone else { return false }
    if case .session = footer { return false }
    return true
  }

  var assigneeInitials: String? {
    guard let assigneeName else { return nil }
    let letters = assigneeName.split(separator: " ").prefix(2).compactMap(\.first)
    return letters.isEmpty ? nil : String(letters).uppercased()
  }
}

struct SprintColumnItem: Identifiable, Equatable {
  let id: String
  let title: String
  let tickets: [SprintTicketItem]
}

/// Sessions are shown for the most relevant link: one that is starting or
/// monitored first, then the most recent.
struct SprintLinkedSessionSummary: Equatable {
  let provider: SessionProviderKind
  let sessionID: String?
  let isPending: Bool
  let isMonitored: Bool
  let lastActivityAt: Date
}

enum SprintBoardItems {
  /// Provider names as the prototype writes them in the card footer.
  static func providerName(_ provider: SessionProviderKind) -> String {
    switch provider {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    }
  }

  static func footer(
    isDone: Bool,
    sessions: [SprintLinkedSessionSummary],
    pullRequests: [GitHubProjectPullRequest]?,
    status: (SessionProviderKind, String) -> SessionStatus?
  ) -> SprintTicketFooter? {
    // A done ticket says Done, even if an old session or a merged PR still links to it.
    if isDone { return .done }
    let best = sessions.max { lhs, rhs in
      let left = (lhs.isPending || lhs.isMonitored, lhs.lastActivityAt)
      let right = (rhs.isPending || rhs.isMonitored, rhs.lastActivityAt)
      return left.0 == right.0 ? left.1 < right.1 : !left.0
    }
    if let best {
      let sessionStatus = best.sessionID.flatMap { status(best.provider, $0) }
      return .session(
        providerName: providerName(best.provider),
        presentation: SessionStatusPresentation(status: sessionStatus, isPending: best.isPending)
      )
    }
    // An open PR first, then a merged one. A closed, unmerged PR is not work
    // in review, so it gets no footer.
    let pullRequests = pullRequests ?? []
    if let open = pullRequests.first(where: { $0.state.lowercased() == "open" }) {
      return .pullRequest(number: open.number, isMerged: false)
    }
    if let merged = pullRequests.first(where: { $0.state.lowercased() == "merged" }) {
      return .pullRequest(number: merged.number, isMerged: true)
    }
    return nil
  }

  /// The session a footer click opens: a monitored one, else the most recent.
  /// Sessions still starting cannot be opened yet.
  static func sessionToOpen<Link: SprintLinkedSession>(_ links: [Link]) -> Link? {
    let openable = links.filter { !$0.isPending }
    return openable.first(where: \.isMonitored) ?? openable.max { $0.lastActivityAt < $1.lastActivityAt }
  }

  static func summary(_ link: some SprintLinkedSession) -> SprintLinkedSessionSummary {
    SprintLinkedSessionSummary(
      provider: link.provider, sessionID: link.session?.id, isPending: link.isPending,
      isMonitored: link.isMonitored, lastActivityAt: link.lastActivityAt)
  }

  // MARK: - Jira

  static func jira(
    columns: [JiraSprintViewModel.BoardColumn],
    linkedSessions: [String: [JiraLinkedSession]],
    pullRequests: [String: [GitHubProjectPullRequest]],
    status: (SessionProviderKind, String) -> SessionStatus?
  ) -> [SprintColumnItem] {
    columns.map { column in
      SprintColumnItem(
        id: column.id,
        title: column.status,
        tickets: column.tickets.map { ticket in
          let isDone = ticket.statusCategory == "done"
          return SprintTicketItem(
            id: ticket.key,
            key: ticket.key,
            title: ticket.summary,
            assigneeName: ticket.assignee,
            isDone: isDone,
            footer: footer(
              isDone: isDone,
              sessions: (linkedSessions[ticket.key] ?? []).map { summary($0) },
              pullRequests: pullRequests[ticket.key],
              status: status
            )
          )
        }
      )
    }
  }

  // MARK: - Linear

  static func linear(
    columns: [LinearViewModel.BoardColumn],
    linkedSessions: [String: [LinearLinkedSession]],
    status: (SessionProviderKind, String) -> SessionStatus?
  ) -> [SprintColumnItem] {
    columns.map { column in
      SprintColumnItem(
        id: column.id,
        title: column.state.name,
        tickets: column.issues.map { issue in
          let isDone = issue.state.type == "completed"
          return SprintTicketItem(
            id: issue.id,
            key: issue.identifier,
            title: issue.title,
            assigneeName: issue.assignee?.name,
            isDone: isDone,
            footer: footer(
              isDone: isDone,
              sessions: (linkedSessions[issue.identifier] ?? []).map { summary($0) },
              pullRequests: nil,
              status: status
            )
          )
        }
      )
    }
  }

}

// MARK: - Linked sessions

/// What the board reads from a Jira or a Linear session link.
protocol SprintLinkedSession {
  var provider: SessionProviderKind { get }
  var isPending: Bool { get }
  var isMonitored: Bool { get }
  var lastActivityAt: Date { get }
  var session: CLISession? { get }
}

extension JiraLinkedSession: SprintLinkedSession {}
extension LinearLinkedSession: SprintLinkedSession {}

// MARK: - Assignee scope

/// The All | Mine switch. Finer filters (a person, unassigned) live in Filters.
enum SprintAssigneeScope: String, CaseIterable, CustomStringConvertible {
  case all
  case mine

  var description: String {
    switch self {
    case .all: return "All"
    case .mine: return "Mine"
    }
  }

  /// Binds the switch to a tracker's "only mine" filter and leaves a breadcrumb.
  static func binding(
    isMine: @escaping () -> Bool,
    setMine: @escaping (Bool) -> Void
  ) -> Binding<SprintAssigneeScope> {
    Binding(
      get: { isMine() ? .mine : .all },
      set: { scope in
        setMine(scope == .mine)
        MainThreadStallMonitor.breadcrumb("sprint filter: \(scope.rawValue)")
      }
    )
  }
}
