import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint people filter")
struct SprintPeopleFilterTests {
  private typealias Filter = JiraSprintViewModel.AssigneeFilter

  private static func assignee(_ id: String, _ name: String, count: Int = 1) -> JiraSprintViewModel.Assignee {
    JiraSprintViewModel.Assignee(accountId: id, name: name, email: "\(id)@xfa.tech", avatarURL: nil, ticketCount: count)
  }

  private static func person(_ id: String) -> SprintPerson {
    SprintPerson(kind: .person(accountId: id), name: id, ticketCount: 1)
  }

  @Test("You first, then the others in the given order, then Unassigned")
  func ordering() {
    let assignees = [Self.assignee("anna", "Anna"), Self.assignee("joey", "Joey van Sommeren", count: 3), Self.assignee("bram", "Bram")]
    let people = SprintPeopleFilter.jira(assignees: assignees, isMe: { $0.accountId == "joey" }, unassignedCount: 2)

    #expect(people.map(\.kind) == [.me, .person(accountId: "anna"), .person(accountId: "bram"), .unassigned])
    #expect(people[0].accessibilityName == "Joey van Sommeren (you)")
    #expect(people[0].initials == "JV")
    #expect(people[0].ticketCountText == "3 tickets")
    #expect(people[3].initials == nil)
    #expect(people[3].ticketCountText == "2 tickets")
  }

  @Test("No Unassigned avatar when every ticket has an assignee; no You when you have none")
  func optionalEntries() {
    let people = SprintPeopleFilter.jira(assignees: [Self.assignee("anna", "Anna")], isMe: { _ in false }, unassignedCount: 0)
    #expect(people.map(\.kind) == [.person(accountId: "anna")])
    #expect(people[0].ticketCountText == "1 ticket")
  }

  @Test("Overflow: fixed counts, never a +1")
  func overflow() {
    let people = (1...8).map { Self.person("p\($0)") }

    let wide = SprintPeopleFilter.split(people, visibleLimit: 6)
    #expect(wide.visible.count == 6)
    #expect(wide.overflow.map(\.name) == ["p7", "p8"])

    let narrow = SprintPeopleFilter.split(people, visibleLimit: 3)
    #expect(narrow.visible.count == 3)
    #expect(narrow.overflow.count == 5)

    let menuOnly = SprintPeopleFilter.split(people, visibleLimit: 0)
    #expect(menuOnly.visible.isEmpty)
    #expect(menuOnly.overflow.count == 8)

    // Seven people with room for six: the seventh takes the "+1" slot.
    let seven = SprintPeopleFilter.split(Array(people.prefix(7)), visibleLimit: 6)
    #expect(seven.visible.count == 7)
    #expect(seven.overflow.isEmpty)

    let one = SprintPeopleFilter.split(Array(people.prefix(1)), visibleLimit: 0)
    #expect(one.visible.count == 1)
    #expect(one.overflow.isEmpty)

    #expect(SprintPeopleFilter.split([], visibleLimit: 6).visible.isEmpty)
  }

  @Test("Selected person: Mine and a person filter on your own account both show as you")
  func selection() {
    #expect(SprintPeopleFilter.selectedKind(.everyone, myAccountID: "joey") == nil)
    #expect(SprintPeopleFilter.selectedKind(.me, myAccountID: "joey") == .me)
    #expect(SprintPeopleFilter.selectedKind(.person(accountId: "joey"), myAccountID: "joey") == .me)
    #expect(SprintPeopleFilter.selectedKind(.person(accountId: "anna"), myAccountID: "joey") == .person(accountId: "anna"))
    #expect(SprintPeopleFilter.selectedKind(.unassigned, myAccountID: nil) == .unassigned)
  }

  @Test("One click selects, a second click shows everyone")
  func toggle() {
    let anna = SprintPerson.Kind.person(accountId: "anna")
    #expect(SprintPeopleFilter.toggled(anna, current: .everyone, myAccountID: "joey") == .person(accountId: "anna"))
    #expect(SprintPeopleFilter.toggled(anna, current: .person(accountId: "anna"), myAccountID: "joey") == .everyone)
    // Switching person goes straight to the other person.
    #expect(SprintPeopleFilter.toggled(anna, current: .unassigned, myAccountID: "joey") == .person(accountId: "anna"))
    // Your avatar is the Mine filter, so it stays in step with All | Mine.
    #expect(SprintPeopleFilter.toggled(.me, current: .everyone, myAccountID: "joey") == .me)
    #expect(SprintPeopleFilter.toggled(.me, current: .me, myAccountID: "joey") == .everyone)
    #expect(SprintPeopleFilter.toggled(.me, current: .person(accountId: "joey"), myAccountID: "joey") == .everyone)
    #expect(SprintPeopleFilter.toggled(.unassigned, current: .me, myAccountID: "joey") == .unassigned)
    #expect(SprintPeopleFilter.toggled(.unassigned, current: .unassigned, myAccountID: "joey") == .everyone)
  }
}
