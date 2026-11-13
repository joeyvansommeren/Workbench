import AgentWorkflowJiraCLI
import AgentWorkflowLinear
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Sprint days left")
struct SprintDaysLeftTests {
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
    return calendar
  }

  /// 2026-11-13 15:00 in Brussels.
  private static let now: Date = calendar.date(
    from: DateComponents(year: 2026, month: 11, day: 13, hour: 15))!

  private static func day(_ offset: Int, hour: Int = 9) -> Date {
    let start = calendar.startOfDay(for: now)
    return calendar.date(byAdding: DateComponents(day: offset, hour: hour), to: start)!
  }

  private func label(_ end: Date) -> String {
    SprintDaysLeft.label(endDate: end, now: Self.now, calendar: Self.calendar)
  }

  @Test("Counts calendar days until the end")
  func daysLeft() {
    #expect(label(Self.day(4)) == "4 days left")
    #expect(label(Self.day(1, hour: 1)) == "1 day left")
  }

  @Test("A sprint that ends today says Ends today, also when the hour has passed")
  func endsToday() {
    #expect(label(Self.day(0, hour: 23)) == "Ends today")
    #expect(label(Self.day(0, hour: 9)) == "Ends today")
  }

  @Test("A past end date says Ended")
  func past() {
    #expect(label(Self.day(-1)) == "Ended")
    #expect(label(Self.day(-30)) == "Ended")
  }

  @Test("Jira title: sprint name and chip; no end date means no chip")
  func jiraTitle() {
    let sprint = JiraSprint(id: 1, name: "Sprint 47", state: "active", endDate: Self.day(4))
    let title = SprintTitle.jira(sprint, now: Self.now)
    #expect(title.title == "Sprint 47")
    #expect(title.daysLeft != nil)
    let future = JiraSprint(id: 2, name: "Sprint 48", state: "future")
    #expect(SprintTitle.jira(future, now: Self.now).daysLeft == nil)
    #expect(SprintTitle.jira(nil) == .fallback)
  }

  @Test("Linear title falls back to the cycle number, then to Sprint")
  func linearTitle() {
    let numbered = LinearCycle(
      id: "c", number: 12, name: nil, startsAt: Self.day(-10), endsAt: Self.day(4))
    #expect(SprintTitle.linear(numbered, now: Self.now).title == "Cycle 12")
    let named = LinearCycle(
      id: "d", number: 13, name: "Polish", startsAt: Self.day(-10), endsAt: Self.day(4))
    #expect(SprintTitle.linear(named, now: Self.now).title == "Polish")
    #expect(SprintTitle.linear(nil) == SprintTitle(title: "Sprint", daysLeft: nil))
  }
}
