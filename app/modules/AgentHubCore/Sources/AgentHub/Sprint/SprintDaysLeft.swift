//
//  SprintDaysLeft.swift
//  AgentHub
//
//  The toolbar title of the Sprint destination: "Sprint 47" plus a days-left
//  chip. Jira has sprints; Linear has cycles, so its title falls back to the
//  cycle name or number, and to "Sprint" when there is no active cycle.
//

import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation

enum SprintDaysLeft {
  /// "4 days left", "1 day left", "Ends today" or "Ended". Counts calendar
  /// days, so a sprint that ends tomorrow morning says "1 day left".
  static func label(endDate: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let days =
      calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: now),
        to: calendar.startOfDay(for: endDate)
      ).day ?? 0
    switch days {
    case ..<0: return "Ended"
    case 0: return "Ends today"
    case 1: return "1 day left"
    default: return "\(days) days left"
    }
  }
}

/// What the Jira or Linear list head shows: sprint or cycle name, days left.
struct SprintTitle: Equatable {
  let title: String
  /// Nil when the sprint or cycle has no end date.
  let daysLeft: String?

  static let fallback = SprintTitle(title: "Sprint", daysLeft: nil)

  /// The name alone, for a narrow list head.
  var withoutDaysLeft: SprintTitle { SprintTitle(title: title, daysLeft: nil) }

  static func jira(_ sprint: JiraSprint?, now: Date = .now) -> SprintTitle {
    guard let sprint else { return .fallback }
    return SprintTitle(
      title: sprint.name,
      daysLeft: sprint.endDate.map { SprintDaysLeft.label(endDate: $0, now: now) }
    )
  }

  /// Linear's head: the project's name when the board is filtered to one
  /// (no days left; a project is not a time box), else the cycle. Nil hides
  /// the title (no project and no active cycle).
  static func linear(project: LinearProject?, cycle: LinearCycle?, now: Date = .now) -> SprintTitle? {
    if let project { return SprintTitle(title: project.name, daysLeft: nil) }
    return cycle.map { linear($0, now: now) }
  }

  static func linear(_ cycle: LinearCycle?, now: Date = .now) -> SprintTitle {
    guard let cycle else { return .fallback }
    return SprintTitle(
      title: cycle.displayName,
      daysLeft: SprintDaysLeft.label(endDate: cycle.endsAt, now: now)
    )
  }
}
