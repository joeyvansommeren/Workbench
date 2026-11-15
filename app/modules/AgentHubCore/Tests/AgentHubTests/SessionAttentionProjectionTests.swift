import AgentHubGitHub
import Foundation
import Testing
@testable import AgentHubCore

struct SessionAttentionProjectionTests {
  private func input(_ id: String, status: SessionStatus? = nil, pending: Bool = false) -> SessionAttentionInput {
    SessionAttentionInput(id: id, title: id, provider: .claude, sessionID: id,
      projectPath: "/tmp/work", status: status, isPending: pending, pendingToolName: nil)
  }

  @Test func fiveSessionsExcludeQuietAndActivity() {
    let inputs = [input("permission", status: .awaitingApproval(tool: "Bash")),
      input("ready"), input("failed"), input("working", status: .thinking),
      input("quiet", status: .waitingForUser)]
    let result = SessionResult(provider: .claude, sessionID: "ready", projectPath: "/tmp/work")
    let items = SessionAttentionProjection.project(inputs: inputs, records: ["ready": result],
      failedChecks: ["failed": "Review failed checks"], previous: [])
    #expect(Set(items.map(\.id)) == ["permission", "ready", "failed"])
  }

  @Test func stableOrderSurvivesActivityAndNewItemsAppend() {
    let previous = [SessionAttentionItem(id: "b", title: "b", reason: "old"),
      SessionAttentionItem(id: "a", title: "a", reason: "old")]
    let inputs = [input("a"), input("new"), input("b")]
    let result = SessionAttentionProjection.project(inputs: inputs, records: [:],
      failedChecks: ["a": "failed", "b": "failed", "new": "failed"], previous: previous)
    #expect(result.map(\.id) == ["b", "a", "new"])
    let resolved = SessionAttentionProjection.project(inputs: inputs, records: [:],
      failedChecks: ["a": "failed", "new": "failed"], previous: result)
    #expect(resolved.map(\.id) == ["a", "new"])
  }

  @Test func acceptedAndPendingResultsDoNotRequestInspection() {
    var result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/work")
    result.decision = .accepted
    let items = SessionAttentionProjection.project(inputs: [input("a"), input("launch", pending: true)],
      records: ["a": result, "launch": result], failedChecks: [:], previous: [])
    #expect(items.isEmpty)
  }

  @Test func keyboardWrapsAndEmptyQueueHasNoTarget() {
    let items = [SessionAttentionItem(id: "a", title: "A", reason: "question"),
      SessionAttentionItem(id: "b", title: "B", reason: "failed")]
    #expect(SessionAttentionProjection.next(after: "a", in: items)?.id == "b")
    #expect(SessionAttentionProjection.next(after: "b", in: items)?.id == "a")
    #expect(SessionAttentionProjection.next(after: nil, in: []) == nil)
  }
  @Test func newActivityAfterAcceptanceRequiresAnotherLook() {
    var result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/work")
    result.decision = .accepted
    result.decidedAt = Date(timeIntervalSince1970: 10)
    var changed = input("a")
    changed.lastActivityAt = Date(timeIntervalSince1970: 11)
    let items = SessionAttentionProjection.project(inputs: [changed], records: ["a": result],
      failedChecks: [:], previous: [])
    #expect(items.first?.reason == "New activity after acceptance · review result")
  }

  @Test func resultFromAnotherWorktreeNeverBecomesThisSessionsReadyResult() {
    let result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/other")
    let items = SessionAttentionProjection.project(inputs: [input("a")], records: ["a": result],
      failedChecks: [:], previous: [])
    #expect(items.isEmpty)
  }

}


@MainActor
struct SessionAttentionModelTests {
  private func input(branch: String, path: String = "/tmp/work") -> SessionAttentionInput {
    SessionAttentionInput(id: "claude-s", title: "Task", provider: .claude, sessionID: "s",
      projectPath: path, status: .idle, isPending: false, pendingToolName: nil, branchName: branch)
  }

  @Test func snapshotMustMatchExactProjectAndBranch() {
    let model = SessionAttentionModel()
    model.update(inputs: [input(branch: "feature")], records: [:])
    let wrongBranch = GitHubPRObservationSnapshot.initial(target: .session(
      projectPath: "/tmp/work", branchName: "other", linkedPullRequests: []))
    let wrongProject = GitHubPRObservationSnapshot.initial(target: .session(
      projectPath: "/tmp/other", branchName: "feature", linkedPullRequests: []))
    model.receive(wrongBranch, itemID: "claude-s")
    model.receive(wrongProject, itemID: "claude-s")
    #expect(model.snapshots.isEmpty)
    let matching = GitHubPRObservationSnapshot.initial(target: .session(
      projectPath: "/tmp/work", branchName: "feature", linkedPullRequests: []))
    model.receive(matching, itemID: "claude-s")
    #expect(model.snapshots["claude-s"] == matching)
    model.update(inputs: [input(branch: "new")], records: [:])
    #expect(model.snapshots.isEmpty)
    #expect(model.checksLabel(for: "claude-s") == "Checks not loaded")
  }
}
