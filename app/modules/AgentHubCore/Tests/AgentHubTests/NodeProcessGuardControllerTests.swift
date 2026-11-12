import Foundation
import Testing
@testable import AgentHubCore

@MainActor
struct NodeProcessGuardControllerTests {
  @Test func missingHelperIsVisible() {
    var messages: [String] = []
    let controller = NodeProcessGuardController(executable: { nil }, notice: { messages.append($0) })
    controller.start()
    #expect(messages.count == 1)
    #expect(messages[0].contains("missing"))
  }

  @Test func handlesSplitReportsWithoutModalAlertsAndRespectsDismissal() {
    var messages: [String] = []
    let controller = NodeProcessGuardController(notice: { messages.append($0) })
    controller.receive(Data("ready\nNode resource".utf8))
    #expect(messages.isEmpty)
    let now = Date(timeIntervalSince1970: 10_000)
    controller.receive(Data(" limit reached\n".utf8), now: now)
    #expect(controller.latestNotice == "Node resource limit reached")
    controller.receive(Data("Another limit\n".utf8), now: now)
    #expect(controller.latestNotice == "Another limit")
    let dismissed = now.addingTimeInterval(300)
    controller.dismissNotice(now: dismissed)
    controller.receive(Data("Too soon\n".utf8), now: dismissed.addingTimeInterval(599))
    #expect(controller.latestNotice == nil)
    controller.receive(Data("New limit\n".utf8), now: dismissed.addingTimeInterval(600))
    #expect(controller.latestNotice == "New limit")
    #expect(messages.isEmpty)
  }
}
