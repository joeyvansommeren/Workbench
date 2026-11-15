import AgentHubGitHub
import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

struct SessionRowPresentationTests {
  @Test("Only a verified PR for this branch supplies a PR action")
  func pullRequestAction() {
    let ready = snapshot(branch: "feature", state: .ready)
    #expect(
      SessionRowAction.make(attention: nil, snapshot: ready, branch: "feature") == "Review PR #5")
    #expect(SessionRowAction.make(attention: nil, snapshot: ready, branch: "other") == nil)
    #expect(
      SessionRowAction.make(
        attention: .init(id: "s", title: "S", reason: "Changed copy", category: .checks),
        snapshot: ready, branch: "other") == nil
    )
    #expect(
      SessionRowAction.make(
        attention: nil, snapshot: snapshot(branch: "feature", state: .error("offline")),
        branch: "feature") == nil)
    #expect(
      SessionRowAction.make(
        attention: .init(id: "s", title: "S", reason: "Inspect the recorded result"), snapshot: nil,
        branch: nil)
        == "Inspect the recorded result")
    #expect(
      SessionRowAction.make(
        attention: nil, snapshot: snapshot(branch: "feature", state: .ready, draft: true),
        branch: "feature") == "Review draft #5")
    #expect(
      SessionRowAction.make(
        attention: nil, snapshot: snapshot(branch: "feature", state: .ready, prState: "MERGED"),
        branch: "feature") == nil)
  }

  @Test("Unrelated failed checks do not hide a recorded result action")
  func unrelatedChecksFallBackToResult() {
    let attention = SessionAttentionItem(
      id: "s", title: "S", reason: "Review failed checks", category: .checks)
    let fallback = "Inspect the recorded result"
    let stale = snapshot(branch: "feature", state: .error("offline"))
    #expect(stale.isStale)
    let invalid = [
      snapshot(branch: "other", state: .ready),
      stale,
      snapshot(branch: "feature", state: .ready, draft: true),
      snapshot(branch: "feature", state: .ready, prState: "CLOSED"),
    ]
    for value in invalid {
      #expect(
        SessionRowAction.make(
          attention: attention, snapshot: value, branch: "feature", fallbackReason: fallback)
          == fallback)
    }
    #expect(
      SessionRowAction.make(
        attention: attention, snapshot: nil, branch: "feature", fallbackReason: fallback)
        == fallback)
  }

  @Test("Only the active key window can acknowledge activity")
  func activeWindow() {
    #expect(SessionReadVisibility.isActive(scenePhase: .active, controlActiveState: .key))
    #expect(!SessionReadVisibility.isActive(scenePhase: .background, controlActiveState: .key))
    #expect(!SessionReadVisibility.isActive(scenePhase: .active, controlActiveState: .inactive))
    #expect(!SessionReadVisibility.isActive(scenePhase: .active, controlActiveState: .active))
  }

  @Test("Invalid workspace indices do not fall back to another session")
  func workspaceVisibility() {
    let link = TerminalWorkspaceLinkedSessionSnapshot(provider: .codex, sessionId: "one")
    let tab = TerminalWorkspaceTabSnapshot(role: .agent, linkedSession: link)
    let panel = TerminalWorkspacePanelSnapshot(role: .primary, tabs: [tab])
    var workspace = TerminalWorkspaceSnapshot(panels: [panel])
    #expect(SessionReadVisibility.activeLinkedSession(workspace) == link)
    workspace.activePanelIndex = 3
    #expect(SessionReadVisibility.activeLinkedSession(workspace) == nil)
    workspace.activePanelIndex = 0
    workspace.panels[0].activeTabIndex = 2
    #expect(SessionReadVisibility.activeLinkedSession(workspace) == nil)
  }

  private func snapshot(
    branch: String, state: GitHubPRObservationState, draft: Bool = false, prState: String = "OPEN"
  ) -> GitHubPRObservationSnapshot {
    let pr = GitHubPullRequest(
      number: 5, title: "Change", body: nil, state: prState, url: "https://example.com",
      headRefName: branch, baseRefName: "main", author: nil, createdAt: nil, updatedAt: nil,
      isDraft: draft, mergeable: nil, additions: 0, deletions: 0, changedFiles: 0,
      reviewDecision: nil, statusCheckRollup: nil, labels: nil, reviewRequests: nil, comments: nil)
    return GitHubPRObservationSnapshot(
      target: .currentBranch(projectPath: "/tmp", branchName: "feature"),
      pullRequest: pr, checks: [], state: state, lastRefreshedAt: Date(timeIntervalSince1970: 1))
  }
}
