import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Linear view model")
struct LinearViewModelTests {
  private func makeViewModel() -> LinearViewModel {
    let suiteName = "LinearViewModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return LinearViewModel(userDefaults: defaults)
  }

  @Test("A second start for the same issue is refused until the first one ends")
  func startingSessionGuard() {
    let viewModel = makeViewModel()

    #expect(viewModel.beginStartingSession(for: "issue-1"))
    #expect(viewModel.startingIssueIDs.contains("issue-1"))
    // A double-click on Start: the second launch is refused.
    #expect(!viewModel.beginStartingSession(for: "issue-1"))
    // Another issue can still start.
    #expect(viewModel.beginStartingSession(for: "issue-2"))

    viewModel.endStartingSession(for: "issue-1")
    #expect(!viewModel.startingIssueIDs.contains("issue-1"))
    #expect(viewModel.beginStartingSession(for: "issue-1"))
  }
}
