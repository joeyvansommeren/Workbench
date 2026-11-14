import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint assignee scope")
struct SprintAssigneeScopeTests {
  @Test("All | Mine labels")
  func scopeLabels() {
    #expect(SprintAssigneeScope.allCases.map(\.description) == ["All", "Mine"])
  }

  @Test("The All | Mine binding reads and writes the tracker's mine filter")
  func scopeBinding() {
    var isMine = false
    let binding = SprintAssigneeScope.binding(isMine: { isMine }, setMine: { isMine = $0 })
    #expect(binding.wrappedValue == .all)
    binding.wrappedValue = .mine
    #expect(isMine)
    #expect(binding.wrappedValue == .mine)
    binding.wrappedValue = .all
    #expect(!isMine)
  }
}
