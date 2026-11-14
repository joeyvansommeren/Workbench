//
//  SprintPeopleFilter.swift
//  AgentHub
//
//  The people filter in the Sprint list head: one avatar per assignee in the
//  sprint (you first), then Unassigned. One click filters the board to that
//  person, a second click shows everyone again. Pure, so it is testable;
//  the view is `SprintPeopleStrip`.
//

import Foundation

/// One avatar in the people filter.
struct SprintPerson: Identifiable, Equatable {
  enum Kind: Hashable {
    /// The signed-in user. Selecting it is the same filter as Mine.
    case me
    case person(accountId: String)
    case unassigned
  }

  let kind: Kind
  /// Full name; "Unassigned" for `.unassigned`.
  let name: String
  let ticketCount: Int

  var id: Kind { kind }

  /// Two letters for the avatar; nil for Unassigned, which shows a glyph.
  var initials: String? {
    guard kind != .unassigned else { return nil }
    let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
    return letters.isEmpty ? nil : String(letters).uppercased()
  }

  /// What VoiceOver says and the tooltip shows: "Gijs Peeters", "Joey (you)".
  var accessibilityName: String {
    kind == .me ? "\(name) (you)" : name
  }

  /// "3 tickets".
  var ticketCountText: String {
    "\(ticketCount) \(ticketCount == 1 ? "ticket" : "tickets")"
  }
}

enum SprintPeopleFilter {
  /// How many avatars the head shows before the rest go into a "+n" menu.
  /// Fixed counts, picked by `ViewThatFits`; never measured.
  static let wideLimit = 6
  static let narrowLimit = 3
  /// Only the menu (or a lone avatar).
  static let menuOnlyLimit = 0

  /// Splits the people into avatars and a "+n" menu. A "+1" would take the
  /// same room as the avatar it hides, so that person is shown instead.
  static func split(
    _ people: [SprintPerson], visibleLimit: Int
  ) -> (visible: [SprintPerson], overflow: [SprintPerson]) {
    guard people.count > visibleLimit + 1 else { return (people, []) }
    let limit = max(visibleLimit, 0)
    return (Array(people.prefix(limit)), Array(people.dropFirst(limit)))
  }
}

// MARK: - Jira

extension SprintPeopleFilter {
  /// You first, then everyone else by name (the order of
  /// `JiraSprintViewModel.assignees`, as the legacy bar), then Unassigned
  /// when the sprint has unassigned tickets.
  static func jira(
    assignees: [JiraSprintViewModel.Assignee],
    isMe: (JiraSprintViewModel.Assignee) -> Bool,
    unassignedCount: Int
  ) -> [SprintPerson] {
    let mine = assignees.filter(isMe)
    let others = assignees.filter { !isMe($0) }
    var people = mine.prefix(1).map {
      SprintPerson(kind: .me, name: $0.name, ticketCount: $0.ticketCount)
    }
    people += others.map {
      SprintPerson(kind: .person(accountId: $0.accountId), name: $0.name, ticketCount: $0.ticketCount)
    }
    if unassignedCount > 0 {
      people.append(SprintPerson(kind: .unassigned, name: "Unassigned", ticketCount: unassignedCount))
    }
    return people
  }

  /// The person the board is filtered to, if any. A stored person filter on
  /// your own account shows as your avatar.
  static func selectedKind(
    _ filter: JiraSprintViewModel.AssigneeFilter, myAccountID: String?
  ) -> SprintPerson.Kind? {
    switch filter {
    case .everyone: return nil
    case .me: return .me
    case .unassigned: return .unassigned
    case .person(let accountId):
      return accountId == myAccountID ? .me : .person(accountId: accountId)
    }
  }

  /// One click selects the person; clicking the selected person shows everyone.
  static func toggled(
    _ kind: SprintPerson.Kind,
    current: JiraSprintViewModel.AssigneeFilter,
    myAccountID: String?
  ) -> JiraSprintViewModel.AssigneeFilter {
    if selectedKind(current, myAccountID: myAccountID) == kind { return .everyone }
    switch kind {
    case .me: return .me
    case .unassigned: return .unassigned
    case .person(let accountId): return .person(accountId: accountId)
    }
  }
}
