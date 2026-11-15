import Testing
@testable import AgentHubCore

@Suite("SessionStatusPresentation")
struct SessionStatusPresentationTests {
  @Test("Provider activity never implies acceptance or completion")
  func activityIsIndependentOfOutcome() {
    let cases: [(SessionStatus?, SessionActivity, String)] = [
      (.thinking, .running, "Thinking"),
      (.executingTool(name: "Bash"), .running, "Running Bash"),
      (.waitingForUser, .waiting, "Waiting for you"),
      (.idle, .inactive, "Inactive"),
      (nil, .unknown, "Status unknown"),
    ]
    for (status, activity, word) in cases {
      let presentation = SessionStatusPresentation(status: status)
      #expect(presentation.activity == activity)
      #expect(presentation.outcome == .unknown)
      #expect(presentation.word == word)
      #expect(presentation.shape != .filledCheck)
      #expect(presentation.category != .ready)
      #expect(presentation.accessibilityLabel.contains("outcome unknown"))
    }
  }

  @Test("Working glyphs retain the difference between thinking and tool execution")
  func workingGlyphs() {
    #expect(SessionStatusPresentation(status: .thinking).shape == .breathingDot)
    #expect(SessionStatusPresentation(status: .executingTool(name: "Bash")).shape == .spinningArc)
  }

  @Test("Pending launch is Starting only until an active status is observed")
  func pendingLaunch() {
    for status in [nil, SessionStatus.idle] {
      let presentation = SessionStatusPresentation(status: status, isPending: true)
      #expect(presentation.activity == .starting)
      #expect(presentation.outcome == .unknown)
      #expect(presentation.word == "Starting")
      #expect(presentation.shape == .breathingDot)
    }
    #expect(SessionStatusPresentation(status: .thinking, isPending: true).word == "Thinking")
  }

  @Test("Explicit questions and permission requests have different outcomes")
  func requestOutcomes() {
    for tool in ["AskUserQuestion", "request_user_input"] {
      let presentation = SessionStatusPresentation(status: .awaitingApproval(tool: tool))
      #expect(presentation.activity == .waiting)
      #expect(presentation.outcome == .needsInput)
      #expect(presentation.word == "Needs input")
      #expect(presentation.shape == .filledBang)
      #expect(presentation.category == .attention)
    }
    let permission = SessionStatusPresentation(status: .awaitingApproval(tool: "Bash"))
    #expect(permission.outcome == .needsApproval)
    #expect(permission.word == "Needs approval")
  }

  @Test("Only an explicit successful outcome has a success glyph")
  func explicitOutcome() {
    for outcome in [SessionOutcome.accepted, .finished] {
      let presentation = SessionStatusPresentation(status: .idle, outcome: outcome)
      #expect(presentation.activity == .inactive)
      #expect(presentation.outcome == outcome)
      #expect(presentation.shape == .filledCheck)
      #expect(presentation.category == .ready)
      #expect(presentation.accessibilityLabel == outcome.displayName)
    }
    let ready = SessionStatusPresentation(status: .waitingForUser, outcome: .readyToInspect)
    #expect(ready.activity == .waiting)
    #expect(ready.outcome == .readyToInspect)
    #expect(ready.word == "Ready to inspect")
    #expect(ready.shape != .filledCheck)
    #expect(ready.category != .ready)
    let changes = SessionStatusPresentation(status: .idle, outcome: .changesRequested)
    #expect(changes.word == "Changes requested")
    #expect(changes.category == .attention)
  }

  @Test("New activity and live requests cannot retain an older acceptance")
  func newActivityOverridesOldOutcome() {
    let running = SessionStatusPresentation(status: .thinking, outcome: .accepted)
    #expect(running.activity == .running)
    #expect(running.outcome == .unknown)
    #expect(running.word == "Thinking")
    #expect(running.category == .working)
    let request = SessionStatusPresentation(
      status: .awaitingApproval(tool: "Bash"), outcome: .finished)
    #expect(request.outcome == .needsApproval)
    #expect(request.word == "Needs approval")
  }

  @Test("Unknown is a separate sidebar group and waiting never says Ready")
  func honestStatusGroups() {
    #expect(StatusGroupCategory.category(for: nil) == .unknown)
    #expect(StatusGroupCategory.category(for: .idle) == .idle)
    #expect(StatusGroupCategory.category(for: .waitingForUser).rawValue == "Waiting for you")
    #expect(StatusGroupCategory.category(for: .thinking) == .working)
    #expect(StatusGroupCategory.category(for: .awaitingApproval(tool: "Bash")) == .needsAttention)
  }

  @Test("Legacy status text and icons do not present quiet work as success")
  func legacyStatusIsHonest() {
    #expect(SessionStatus.waitingForUser.displayName == "Waiting for you")
    #expect(SessionStatus.waitingForUser.icon == "pause.circle")
    #expect(SessionStatus.waitingForUser.color != "green")
    #expect(SessionStatus.idle.displayName == "Inactive")
  }
}
