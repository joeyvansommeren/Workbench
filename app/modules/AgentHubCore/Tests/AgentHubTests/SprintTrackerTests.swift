import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint tracker")
struct SprintTrackerTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "SprintTrackerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("Without a saved tracker, Sprint opens on Jira when acli is installed")
  func defaultsToJiraWithACLI() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { true })
    #expect(model.sprintTracker == .jira)
  }

  @Test("Without a saved tracker, Sprint opens on Linear when acli is missing")
  func defaultsToLinearWithoutACLI() {
    let model = WorkbenchShellModel(defaults: makeDefaults(), isJiraCLIAvailable: { false })
    #expect(model.sprintTracker == .linear)
  }

  @Test("A saved tracker wins over the default rule, and acli is not checked")
  func savedTrackerWins() {
    let defaults = makeDefaults()
    defaults.set("jira", forKey: AgentHubDefaults.sprintTracker)
    var checked = false
    let model = WorkbenchShellModel(
      defaults: defaults,
      isJiraCLIAvailable: {
        checked = true
        return false
      })
    #expect(model.sprintTracker == .jira)
    #expect(!checked)
  }

  @Test("Switching the tracker persists it for the next window")
  func persistence() {
    let defaults = makeDefaults()
    let model = WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true })
    model.setSprintTracker(.linear)
    #expect(defaults.string(forKey: AgentHubDefaults.sprintTracker) == "linear")
    #expect(
      WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { true }).sprintTracker == .linear)

    model.setSprintTracker(.jira)
    #expect(
      WorkbenchShellModel(defaults: defaults, isJiraCLIAvailable: { false }).sprintTracker == .jira)
  }

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
