import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

struct SessionAttentionProjectionTests {
  private func input(_ id: String, status: SessionStatus? = nil, pending: Bool = false)
    -> SessionAttentionInput
  {
    SessionAttentionInput(
      id: id, title: id, provider: .claude, sessionID: id,
      projectPath: "/tmp/work", status: status, isPending: pending, pendingToolName: nil)
  }

  @Test func fiveSessionsExcludeQuietAndActivity() {
    let inputs = [
      input("permission", status: .awaitingApproval(tool: "Bash")),
      input("ready"), input("failed"), input("working", status: .thinking),
      input("quiet", status: .waitingForUser),
    ]
    let result = SessionResult(provider: .claude, sessionID: "ready", projectPath: "/tmp/work")
    let items = SessionAttentionProjection.project(
      inputs: inputs, records: ["ready": result],
      failedChecks: ["failed": "Review failed checks"], previous: [])
    #expect(Set(items.map(\.id)) == ["permission", "ready", "failed"])
  }

  @Test func stableOrderSurvivesActivityAndNewItemsAppend() {
    let previous = [
      SessionAttentionItem(id: "b", title: "b", reason: "old"),
      SessionAttentionItem(id: "a", title: "a", reason: "old"),
    ]
    let inputs = [input("a"), input("new"), input("b")]
    let result = SessionAttentionProjection.project(
      inputs: inputs, records: [:],
      failedChecks: ["a": "failed", "b": "failed", "new": "failed"], previous: previous)
    #expect(result.map(\.id) == ["b", "a", "new"])
    let resolved = SessionAttentionProjection.project(
      inputs: inputs, records: [:],
      failedChecks: ["a": "failed", "new": "failed"], previous: result)
    #expect(resolved.map(\.id) == ["a", "new"])
  }

  @Test func acceptedAndPendingResultsDoNotRequestInspection() {
    var result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/work")
    result.decision = .accepted
    let items = SessionAttentionProjection.project(
      inputs: [input("a"), input("launch", pending: true)],
      records: ["a": result, "launch": result], failedChecks: [:], previous: [])
    #expect(items.isEmpty)
  }

  @Test func keyboardWrapsAndEmptyQueueHasNoTarget() {
    let items = [
      SessionAttentionItem(id: "a", title: "A", reason: "question"),
      SessionAttentionItem(id: "b", title: "B", reason: "failed"),
    ]
    #expect(SessionAttentionProjection.next(after: "a", in: items)?.id == "b")
    #expect(SessionAttentionProjection.next(after: "b", in: items)?.id == "a")
    #expect(SessionAttentionProjection.next(after: nil, in: []) == nil)
  }
  @Test func rawActivityAfterAcceptanceDoesNotInventAReviewRequest() {
    var result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/work")
    result.decision = .accepted
    result.decidedAt = Date(timeIntervalSince1970: 10)
    var changed = input("a")
    changed.lastActivityAt = Date(timeIntervalSince1970: 11)
    let items = SessionAttentionProjection.project(
      inputs: [changed], records: ["a": result],
      failedChecks: [:], previous: [])
    #expect(items.isEmpty)
  }

  @Test func resultFromAnotherWorktreeNeverBecomesThisSessionsReadyResult() {
    let result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/other")
    let items = SessionAttentionProjection.project(
      inputs: [input("a")], records: ["a": result],
      failedChecks: [:], previous: [])
    #expect(items.isEmpty)
  }

  @Test func fiveSeededSessionsContainEveryActionAndExcludeRawActivity() {
    let inputs = [
      input("permission", status: .awaitingApproval(tool: "Bash")),
      input("question", status: .awaitingApproval(tool: "AskUserQuestion")),
      input("checks"), input("result"), input("activity", status: .thinking),
    ]
    let result = SessionResult(provider: .claude, sessionID: "result", projectPath: "/tmp/work")
    let items = SessionAttentionProjection.project(
      inputs: inputs, records: ["result": result],
      failedChecks: ["checks": "Review failed checks"], previous: [])
    #expect(items.map(\.id) == ["checks", "permission", "question", "result"])
    #expect(items.map(\.category) == [.checks, .permission, .question, .result])
    #expect(items.allSatisfy { !$0.reason.isEmpty })
    #expect(items.first(where: { $0.id == "permission" })?.reason == "Permission needed · Bash")
    #expect(SessionAttentionProjection.next(after: "activity", in: items)?.id == "checks")
    #expect(
      SessionAttentionProjection.next(after: "checks", in: items, forward: false)?.id == "result")
  }

  @Test func pendingQuestionsAreActionableWithoutAnApprovalStatus() {
    let question = SessionAttentionInput(
      id: "question", title: "Choose a layout", provider: .codex,
      sessionID: "question", projectPath: "/tmp/work", status: .waitingForUser,
      isPending: false, pendingToolName: "request_user_input")
    let items = SessionAttentionProjection.project(
      inputs: [question], records: [:],
      failedChecks: [:], previous: [])
    #expect(items.first?.category == .question)
    #expect(items.first?.accessibilityLabel == "Choose a layout, Answer a question")
  }

  @Test func workingSessionsDoNotOfferAnEarlierResult() {
    let result = SessionResult(provider: .claude, sessionID: "a", projectPath: "/tmp/work")
    for status in [SessionStatus.thinking, .executingTool(name: "Bash")] {
      #expect(
        SessionAttentionProjection.project(
          inputs: [input("a", status: status)],
          records: ["a": result], failedChecks: [:], previous: []
        ).isEmpty)
    }
    var accepted = result
    accepted.decision = .accepted
    accepted.revise(sourceIdentity: "new-version")
    #expect(
      SessionAttentionProjection.project(
        inputs: [input("a")], records: ["a": accepted],
        failedChecks: [:], previous: []
      ).first?.category == .result)
  }

  @Test func reasonChangesKeepTheSamePosition() {
    let old = [
      SessionAttentionItem(id: "z", title: "Old", reason: "Old reason"),
      SessionAttentionItem(id: "a", title: "A", reason: "Failed checks"),
    ]
    let items = SessionAttentionProjection.project(
      inputs: [
        input("a"),
        input("z", status: .awaitingApproval(tool: "AskUserQuestion")),
      ], records: [:],
      failedChecks: ["a": "Failed checks"], previous: old)
    #expect(items.map(\.id) == ["z", "a"])
    #expect(items.first?.reason == "Answer a question")
  }

}

@MainActor
struct SessionAttentionModelTests {
  private func input(branch: String, path: String = "/tmp/work") -> SessionAttentionInput {
    SessionAttentionInput(
      id: "claude-s", title: "Task", provider: .claude, sessionID: "s",
      projectPath: path, status: .idle, isPending: false, pendingToolName: nil, branchName: branch)
  }

  @Test func snapshotMustMatchExactProjectAndBranch() {
    let model = SessionAttentionModel()
    model.update(inputs: [input(branch: "feature")], records: [:])
    let wrongBranch = GitHubPRObservationSnapshot.initial(
      target: .session(
        projectPath: "/tmp/work", branchName: "other", linkedPullRequests: []))
    let wrongProject = GitHubPRObservationSnapshot.initial(
      target: .session(
        projectPath: "/tmp/other", branchName: "feature", linkedPullRequests: []))
    model.receive(wrongBranch, itemID: "claude-s")
    model.receive(wrongProject, itemID: "claude-s")
    #expect(model.snapshots.isEmpty)
    let matching = GitHubPRObservationSnapshot.initial(
      target: .session(
        projectPath: "/tmp/work", branchName: "feature", linkedPullRequests: []))
    model.receive(matching, itemID: "claude-s")
    #expect(model.snapshots["claude-s"] == matching)
    model.update(inputs: [input(branch: "new")], records: [:])
    #expect(model.snapshots.isEmpty)
    #expect(model.checksLabel(for: "claude-s") == "Checks not loaded")
  }
  @Test func shortcutRevealsQueueCyclesAndAnnouncesTheOpenedTarget() {
    var spoken: [String] = []
    var opened: [String] = []
    let model = SessionAttentionModel(announce: { spoken.append($0) })
    let inputs = ["a", "b", "c", "d", "e"].map { id in
      SessionAttentionInput(
        id: id, title: "Task \(id)", provider: .claude, sessionID: id,
        projectPath: "/tmp/work", status: id == "e" ? .thinking : .awaitingApproval(tool: "Bash"),
        isPending: false, pendingToolName: nil)
    }
    model.update(inputs: inputs, records: [:])
    let window = WorkbenchShellModel()
    window.select(.reviews)
    window.toggleSidebar()
    for expected in ["a", "b", "c", "d", "a"] {
      model.navigateNext(after: nil, shellModel: window) { item in opened.append(item.id) }
      #expect(opened.last == expected)
      #expect(spoken.last == "Task \(expected), Permission needed · Bash")
      #expect(window.attentionTargetID == expected)
      #expect(window.needsYouFilter && window.sidebarVisible && window.destination == .sessions)
    }
    #expect(spoken.count == opened.count)
    let otherWindow = WorkbenchShellModel()
    model.navigateNext(after: nil, shellModel: otherWindow) { opened.append($0.id) }
    #expect(otherWindow.attentionTargetID == "a")
    model.navigateNext(after: "c", shellModel: window) { opened.append($0.id) }
    #expect(window.attentionTargetID == "d")
    #expect(otherWindow.attentionTargetID == "a")
    model.update(inputs: [], records: [:])
    let openedCount = opened.count
    model.navigateNext(after: nil, shellModel: window) { opened.append($0.id) }
    #expect(opened.count == openedCount)
    #expect(window.attentionTargetID == nil)
    #expect(spoken.last == "No sessions need you")
  }

  @Test func onlyOpenMatchingPullRequestsSupplyFailedChecks() {
    let model = SessionAttentionModel(announce: { _ in })
    model.update(inputs: [input(branch: "feature")], records: [:])
    for (branch, state, expected) in [
      ("feature", "OPEN", 1), ("other", "OPEN", 0),
      ("feature", "CLOSED", 0), ("feature", "MERGED", 0),
    ] {
      let pr = GitHubPullRequest(
        number: 5, title: "Change", body: nil, state: state,
        url: "https://example.com/pr/5", headRefName: branch, baseRefName: "main", author: nil,
        createdAt: nil, updatedAt: nil, isDraft: false, mergeable: nil, additions: 0,
        deletions: 0, changedFiles: 0, reviewDecision: nil, statusCheckRollup: nil,
        labels: nil, reviewRequests: nil, comments: nil)
      let snapshot = GitHubPRObservationSnapshot(
        target: .session(
          projectPath: "/tmp/work",
          branchName: "feature", linkedPullRequests: []), pullRequest: pr,
        checks: [GitHubCheckRun(name: "Tests", status: "COMPLETED", conclusion: "FAILURE")],
        state: .ready, lastRefreshedAt: Date(timeIntervalSince1970: 1))
      model.receive(snapshot, itemID: "claude-s")
      #expect(model.items.count == expected)
    }
  }

  @Test func reasonsOpenTheirChecksOrRecordedResult() {
    let model = SessionAttentionModel(announce: { _ in })
    let navigation = SessionNavigationModel()
    let coordinator = SessionsActionCoordinator()
    let detail = SessionDetailStateModel()
    let shell = WorkbenchShellModel()
    shell.toggleSidePanel()
    navigation.selectedWorkspaceID = "workspace"
    detail.setShowsResult(false, for: "claude-result")
    model.routeReason(
      .init(id: "claude-result", title: "Result", reason: "Inspect", category: .result),
      projectPath: "/tmp/work", navigationModel: navigation, shellModel: shell,
      coordinator: coordinator,
      detailState: detail)
    #expect(navigation.primarySessionId == "claude-result")
    #expect(navigation.selectedWorkspaceID == nil)
    #expect(detail.showsResult(for: "claude-result"))
    #expect(coordinator.gitHubSheetItem == nil)
    model.routeReason(
      .init(id: "claude-checks", title: "Checks", reason: "Failed", category: .checks),
      projectPath: "/tmp/work", navigationModel: navigation, shellModel: shell,
      coordinator: coordinator,
      detailState: detail)
    #expect(coordinator.gitHubSheetItem == nil)
    #expect(navigation.primarySessionId == "claude-checks")
    #expect(detail.sidePanelSegment(for: "claude-checks") == .gitHub)
    #expect(shell.sidePanelVisible)
  }

  @Test func failedChecksKeepTheirPlaceDuringRefresh() {
    let model = SessionAttentionModel(announce: { _ in })
    let checkInput = input(branch: "feature")
    let question = SessionAttentionInput(
      id: "a-question", title: "Question", provider: .codex,
      sessionID: "question", projectPath: "/tmp/work",
      status: .awaitingApproval(tool: "request_user_input"),
      isPending: false, pendingToolName: nil)
    let pr = GitHubPullRequest(
      number: 5, title: "Change", body: nil, state: "OPEN",
      url: "https://example.com/pr/5", headRefName: "feature", baseRefName: "main", author: nil,
      createdAt: nil, updatedAt: nil, isDraft: false, mergeable: nil, additions: 0,
      deletions: 0, changedFiles: 0, reviewDecision: nil, statusCheckRollup: nil,
      labels: nil, reviewRequests: nil, comments: nil)
    func snapshot(
      _ state: GitHubPRObservationState, failed: Bool = true,
      refreshedAt: Date? = Date(timeIntervalSince1970: 1)
    ) -> GitHubPRObservationSnapshot {
      GitHubPRObservationSnapshot(
        target: .session(
          projectPath: "/tmp/work",
          branchName: "feature", linkedPullRequests: []), pullRequest: pr,
        checks: [
          GitHubCheckRun(
            name: "Tests", status: "COMPLETED",
            conclusion: failed ? "FAILURE" : "SUCCESS")
        ],
        state: state, lastRefreshedAt: refreshedAt)
    }
    model.update(inputs: [checkInput], records: [:])
    model.receive(snapshot(.ready), itemID: checkInput.id)
    model.update(inputs: [question, checkInput], records: [:])
    let order = [checkInput.id, question.id]
    #expect(model.items.map(\.id) == order)
    model.receive(snapshot(.refreshing), itemID: checkInput.id)
    #expect(model.items.map(\.id) == order)
    #expect(model.items.first?.reason == "Check failure · refreshing status")
    model.receive(snapshot(.error("Offline")), itemID: checkInput.id)
    #expect(model.items.map(\.id) == order)
    #expect(model.items.first?.reason == "Check failure · status unavailable")
    model.receive(snapshot(.ready), itemID: checkInput.id)
    #expect(model.items.map(\.id) == order)
    model.receive(snapshot(.ready, failed: false), itemID: checkInput.id)
    #expect(model.items.map(\.id) == [question.id])
    model.receive(snapshot(.refreshing, refreshedAt: nil), itemID: checkInput.id)
    #expect(model.items.map(\.id) == [question.id])
  }

  @Test func explicitRequestsRevealTheirTerminalEvenWithoutAnApprovalStatus() {
    let model = SessionAttentionModel(announce: { _ in })
    let navigation = SessionNavigationModel()
    let coordinator = SessionsActionCoordinator()
    let detail = SessionDetailStateModel()
    let shell = WorkbenchShellModel()
    for category in [SessionAttentionCategory.question, .permission] {
      navigation.selectedWorkspaceID = "workspace"
      detail.setShowsResult(true, for: "codex-question")
      detail.setContentMode(.editor, for: "codex-question", defaultProjectPath: "/tmp/work")
      model.routeReason(
        .init(id: "codex-question", title: "Request", reason: "Answer", category: category),
        projectPath: "/tmp/work", navigationModel: navigation, shellModel: shell,
        coordinator: coordinator, detailState: detail)
      #expect(!detail.showsResult(for: "codex-question"))
      #expect(detail.contentMode(for: "codex-question") == .terminal)
      #expect(navigation.selectedWorkspaceID == "workspace")
      #expect(coordinator.gitHubSheetItem == nil)
    }
  }

}
