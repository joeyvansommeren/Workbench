import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Provider turn progress")
struct SessionProgressPresentationTests {
  private let began = Date(timeIntervalSince1970: 1_767_225_600)
  private let ended = Date(timeIntervalSince1970: 1_767_225_602)
  private let project = "/tmp/progress-fixture"

  @Test("Codex progress is working, completion survives reparse and a new turn clears readiness")
  func codexProgressAndCompletion() {
    let firstTurn = [
      #"{"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"task_started","turn_id":"first"}}"#,
      #"{"type":"event_msg","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"agent_message","phase":"commentary","message":"I am reading the fixtures."}}"#,
    ]
    let completion = #"{"type":"event_msg","timestamp":"2026-01-01T00:00:02Z","payload":{"type":"task_complete","turn_id":"first","last_agent_message":"No edits were needed."}}"#
    var parsed = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(firstTurn, into: &parsed)
    CodexSessionJSONLParser.updateCurrentStatus(&parsed, now: began.addingTimeInterval(1))
    #expect(projected(parsed.currentStatus, parsed.turnProgress).action == .working)

    CodexSessionJSONLParser.parseNewLines([completion], into: &parsed)
    var restored = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(firstTurn + [completion], into: &restored)
    #expect(parsed.turnProgress == restored.turnProgress)
    let response = projected(restored.currentStatus, restored.turnProgress)
    #expect(response.action == .readResponse)
    #expect(response.status.outcome == .unknown)
    #expect(response.lastCompletedAt == ended)

    let nextTurn = #"{"type":"event_msg","timestamp":"2026-01-01T00:00:04Z","payload":{"type":"task_started","turn_id":"second"}}"#
    CodexSessionJSONLParser.parseNewLines([
      nextTurn, completion,
      #"{"type":"unknown_record","timestamp":"2026-01-01T00:00:04Z"}"#,
    ], into: &restored)
    CodexSessionJSONLParser.updateCurrentStatus(&restored, now: began.addingTimeInterval(4))
    let working = projected(restored.currentStatus, restored.turnProgress)
    #expect(working.action == .working)
    #expect(working.startedAt == began.addingTimeInterval(4))
    #expect(working.lastCompletedAt == ended)
  }

  @Test("Claude streamed commentary is working and end_turn is a durable plain response")
  func claudeProgressAndCompletion() {
    let prefix = [
      #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Please review the fixture."}]}}"#,
      #"{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"Reading the fixture."}]}}"#,
    ]
    let final = #"{"type":"assistant","timestamp":"2026-01-01T00:00:02Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"No code changes needed."}]}}"#
    var parsed = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(prefix, into: &parsed)
    SessionJSONLParser.updateCurrentStatus(&parsed, now: began.addingTimeInterval(1))
    #expect(projected(parsed.currentStatus, parsed.turnProgress).action == .working)
    SessionJSONLParser.parseNewLines([final], into: &parsed)

    var restored = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(prefix + [final], into: &restored)
    #expect(parsed.turnProgress == restored.turnProgress)
    #expect(projected(restored.currentStatus, restored.turnProgress).action == .readResponse)
    #expect(restored.turnProgress.lastCompletedAt == ended)

    SessionJSONLParser.parseNewLines([
      #"{"type":"user","timestamp":"2026-01-01T00:00:04Z","message":{"role":"user","content":[{"type":"text","text":"Check another fixture."}]}}"#,
      final,
    ], into: &restored)
    SessionJSONLParser.updateCurrentStatus(&restored, now: began.addingTimeInterval(4))
    #expect(restored.turnProgress.phase == .working)
    #expect(restored.turnProgress.lastCompletedAt == ended)
    #expect(projected(restored.currentStatus, restored.turnProgress).action == .working)
  }

  @Test("An explicit question retains attention until its output is recorded")
  func explicitQuestions() {
    var codex = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([
      #"{"type":"response_item","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"function_call","name":"request_user_input","call_id":"q1"}}"#,
    ], into: &codex)
    #expect(projected(codex.currentStatus, codex.turnProgress).action == .answer)
    CodexSessionJSONLParser.parseNewLines([
      #"{"type":"response_item","timestamp":"2026-01-01T00:00:02Z","payload":{"type":"function_call_output","call_id":"q1","output":"Continue"}}"#,
    ], into: &codex)
    #expect(projected(codex.currentStatus, codex.turnProgress).action != .answer)

    var claude = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([
      #"{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","id":"q1","input":{}}]}}"#,
    ], into: &claude)
    #expect(projected(claude.currentStatus, claude.turnProgress).action == .answer)
    #expect(projected(.awaitingApproval(tool: "Edit"), .init()).action == .permission)
  }

  @Test("Unproven status, stopped process and a completed response have different labels")
  func missingStoppedAndCompleted() {
    let missing = SessionProgressPresentation(state: nil, projectPath: project)
    #expect(missing.action == .unavailable)
    #expect(missing.updatedAt == nil)
    let disconnected = SessionProgressPresentation(
      state: .init(status: .thinking, isSourceAvailable: false), projectPath: project)
    #expect(disconnected.action == .unavailable)
    let stopped = SessionProgressPresentation(state: nil, terminalExitedAt: ended, projectPath: project)
    #expect(stopped.action == .notRunning)

    var interrupted = SessionTurnProgress()
    interrupted.begin(at: began)
    interrupted.interrupt()
    #expect(projected(.idle, interrupted).action == .notRunning)
    #expect(projected(.idle, interrupted).lastCompletedAt == nil)

    var codex = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([
      #"{"type":"event_msg","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"agent_message","phase":"commentary","message":"Checking the working tree."}}"#,
    ], into: &codex)
    CodexSessionJSONLParser.updateCurrentStatus(&codex, now: began)
    #expect(projected(codex.currentStatus, codex.turnProgress).action == .unavailable)
  }

  @Test("Current-branch check failures and recorded results are independent of response readiness")
  func workAndPublication() {
    var progress = SessionTurnProgress()
    progress.begin(at: began)
    progress.complete(at: ended, hasResponse: true)
    let state = SessionMonitorState(
      status: .responseReady, lastActivityAt: ended, sessionStartedAt: began, turnProgress: progress)
    let pr = GitHubPullRequest(number: 5, title: "Change", body: nil, state: "OPEN",
      url: "https://example.com/pull/5", headRefName: "feature", baseRefName: "main", author: nil,
      createdAt: nil, updatedAt: nil, isDraft: false, mergeable: nil, additions: 0,
      deletions: 0, changedFiles: 0, reviewDecision: nil, statusCheckRollup: nil,
      labels: nil, reviewRequests: nil, comments: nil)
    let snapshot = GitHubPRObservationSnapshot(
      target: .session(projectPath: project, branchName: "feature", linkedPullRequests: []),
      pullRequest: pr, checks: [GitHubCheckRun(name: "Tests", status: "COMPLETED", conclusion: "FAILURE")],
      state: .ready, lastRefreshedAt: ended)
    let failed = SessionProgressPresentation(
      state: state, projectPath: project, branch: "feature", snapshot: snapshot)
    #expect(failed.action == .checkFailure)
    #expect(failed.publication == "Open PR #5")
    #expect(failed.lastCompletedAt == ended)
    #expect(SessionProgressPresentation(
      state: state, projectPath: project, branch: "other", snapshot: snapshot).action == .readResponse)

    var result = SessionResult(provider: .codex, sessionID: "fixture", projectPath: project)
    result.updatedAt = ended
    #expect(SessionProgressPresentation(
      state: state, result: result, projectPath: project).action == .reviewChanges)
    progress.begin(at: ended.addingTimeInterval(1))
    #expect(SessionProgressPresentation(
      state: .init(status: .idle, turnProgress: progress), result: result, projectPath: project
    ).action == .unavailable)
  }

  @Test("The sidebar label and terminal header agree for a returned response")
  func rowAndHeaderProjection() {
    var turn = SessionTurnProgress()
    turn.begin(at: began)
    turn.complete(at: ended, hasResponse: true)
    let session = CLISession(id: "fixture", projectPath: project, lastActivityAt: ended)
    let node = SessionNode(id: "fixture", session: session, providerKind: .codex,
      isPending: false, status: .responseReady)
    let progress = projected(.responseReady, turn)
    let row = SessionRowModel(node: node, title: "Check fixtures", roleLabel: nil,
      isFirstInBranch: true, isLastInBranch: true, progress: progress)
    #expect(row.reason == "Response ready")
    #expect(row.sidebarAccessibilityLabel.contains(progress.status.accessibilityLabel))
  }

  private func projected(_ status: SessionStatus, _ turn: SessionTurnProgress) -> SessionProgressPresentation {
    SessionProgressPresentation(
      state: .init(status: status, lastActivityAt: ended, sessionStartedAt: began, turnProgress: turn),
      projectPath: project)
  }
}
