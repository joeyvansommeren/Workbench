import Foundation
import Testing

@testable import AgentHubCore

@Suite("Linear issue key detection for sessions")
struct LinearIssueKeyDetectorTests {
  private let linearKeys: Set<String> = ["WB", "DES"]
  private let jiraKeys: Set<String> = ["XFA"]

  @Test("Branch names starting with a known Linear team key link to the issue")
  func branchNames() {
    #expect(keys(branch: "wb-12-add-linear") == ["WB-12"])
    #expect(keys(branch: "codex/des-45-new-icons") == ["DES-45"])
    #expect(keys(branch: "WB-7") == ["WB-7"])
  }

  @Test("Unknown team key prefixes in branches are ignored")
  func unknownPrefixes() {
    #expect(keys(branch: "feature/abc-12-thing").isEmpty)
    #expect(keys(branch: "release-2").isEmpty)
    #expect(keys(branch: "main").isEmpty)
  }

  @Test("Linear URLs in prompts always count")
  func linearURLs() {
    #expect(
      keys(prompt: "Check https://linear.app/workbench/issue/WB-12/add-linear please")
        == ["WB-12"])
  }

  @Test("Explicit 'Linear issue KEY' in prompts always count")
  func explicitPrompt() {
    #expect(keys(prompt: "Pick up Linear issue WB-12: Add Linear") == ["WB-12"])
  }

  @Test("Jira project keys do not collide with Linear")
  func jiraCollision() {
    // XFA is a known Jira key, so even if someone added it as a Linear key
    // the branch detector should not claim it for Linear.
    let both = LinearIssueKeyDetector.keys(
      branchName: "xfa-123-fix",
      customName: nil,
      prompt: nil,
      knownLinearTeamKeys: ["XFA", "WB"],
      knownJiraProjectKeys: ["XFA"]
    )
    // XFA-123 from a branch should NOT be Linear because it's a known Jira key.
    #expect(both.isEmpty)
  }

  @Test("Linear key in branch is accepted when Jira has a different prefix")
  func noCollision() {
    let result = LinearIssueKeyDetector.keys(
      branchName: "wb-12-something",
      customName: nil,
      prompt: nil,
      knownLinearTeamKeys: ["WB"],
      knownJiraProjectKeys: ["XFA"]
    )
    #expect(result == ["WB-12"])
  }

  @Test("Custom names starting with a known Linear key link; duplicates collapse")
  func customNames() {
    let result = LinearIssueKeyDetector.keys(
      branchName: "wb-9-login",
      customName: "WB-9 login fix",
      prompt: "Pick up Linear issue WB-9: Login",
      knownLinearTeamKeys: linearKeys,
      knownJiraProjectKeys: jiraKeys
    )
    #expect(result == ["WB-9"])
  }

  @Test("Jira and Linear keys from the same session do not cross-contaminate")
  func mixedSession() {
    // A session might reference both a Jira ticket (via URL) and a Linear issue (via branch).
    let jiraResult = JiraTicketKeyDetector.keys(
      branchName: "wb-12-something",
      customName: nil,
      prompt: "Check https://xfatech.atlassian.net/browse/XFA-100",
      knownProjectKeys: jiraKeys
    )
    let linearResult = LinearIssueKeyDetector.keys(
      branchName: "wb-12-something",
      customName: nil,
      prompt: "Check https://xfatech.atlassian.net/browse/XFA-100",
      knownLinearTeamKeys: linearKeys,
      knownJiraProjectKeys: jiraKeys
    )
    #expect(jiraResult == ["XFA-100"])
    #expect(linearResult == ["WB-12"])
  }

  private func keys(branch: String? = nil, prompt: String? = nil) -> [String] {
    LinearIssueKeyDetector.keys(
      branchName: branch,
      customName: nil,
      prompt: prompt,
      knownLinearTeamKeys: linearKeys,
      knownJiraProjectKeys: jiraKeys
    )
  }
}
