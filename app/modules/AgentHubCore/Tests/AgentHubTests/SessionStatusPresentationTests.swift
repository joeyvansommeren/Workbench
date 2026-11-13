//
//  SessionStatusPresentationTests.swift
//  AgentHubTests
//

import Testing
@testable import AgentHubCore

@Suite("SessionStatusPresentation")
struct SessionStatusPresentationTests {

  // MARK: - Shape mapping

  @Test("thinking maps to breathingDot / working")
  func thinkingShape() {
    let p = SessionStatusPresentation(status: .thinking)
    #expect(p.shape == .breathingDot)
    #expect(p.category == .working)
    #expect(p.word == "Thinking")
  }

  @Test("executingTool maps to spinningArc / working")
  func executingToolShape() {
    let p = SessionStatusPresentation(status: .executingTool(name: "Bash"))
    #expect(p.shape == .spinningArc)
    #expect(p.category == .working)
    #expect(p.word == "Running Bash")
  }

  @Test("waitingForUser maps to filledCheck / ready")
  func waitingForUserShape() {
    let p = SessionStatusPresentation(status: .waitingForUser)
    #expect(p.shape == .filledCheck)
    #expect(p.category == .ready)
    #expect(p.word == "Your turn")
  }

  @Test("awaitingApproval maps to filledBang / attention")
  func awaitingApprovalShape() {
    let p = SessionStatusPresentation(status: .awaitingApproval(tool: "Bash"))
    #expect(p.shape == .filledBang)
    #expect(p.category == .attention)
    #expect(p.word == "Needs approval")
  }

  @Test("interactive input tool maps to filledBang with 'Needs input'")
  func interactiveInputShape() {
    let p = SessionStatusPresentation(status: .awaitingApproval(tool: "request_user_input"))
    #expect(p.shape == .filledBang)
    #expect(p.category == .attention)
    #expect(p.word == "Needs input")
  }

  @Test("AskUserQuestion also matches interactive input")
  func askUserQuestionShape() {
    let p = SessionStatusPresentation(status: .awaitingApproval(tool: "AskUserQuestion"))
    #expect(p.shape == .filledBang)
    #expect(p.category == .attention)
    #expect(p.word == "Needs input")
  }

  @Test("idle maps to ring / idle")
  func idleShape() {
    let p = SessionStatusPresentation(status: .idle)
    #expect(p.shape == .ring)
    #expect(p.category == .idle)
    #expect(p.word == "Idle")
  }

  @Test("nil maps to ring / idle")
  func nilShape() {
    let p = SessionStatusPresentation(status: nil)
    #expect(p.shape == .ring)
    #expect(p.category == .idle)
    #expect(p.word == "Idle")
  }

  @Test("pending session maps to breathingDot / working / Starting")
  func pendingShape() {
    let p = SessionStatusPresentation(status: nil, isPending: true)
    #expect(p.shape == .breathingDot)
    #expect(p.category == .working)
    #expect(p.word == "Starting")
  }

  @Test("pending with idle status still shows Starting")
  func pendingIdleShape() {
    let p = SessionStatusPresentation(status: .idle, isPending: true)
    #expect(p.shape == .breathingDot)
    #expect(p.category == .working)
    #expect(p.word == "Starting")
  }

  @Test("pending with active status uses the active status")
  func pendingActiveShape() {
    let p = SessionStatusPresentation(status: .thinking, isPending: true)
    #expect(p.shape == .breathingDot)
    #expect(p.category == .working)
    #expect(p.word == "Thinking")
  }

  // MARK: - Category matches StatusGroupCategory

  @Test("category matches StatusGroupCategory.category(for:)")
  func categoryMatchesStatusGroupCategory() {
    let cases: [(SessionStatus?, StatusGroupCategory)] = [
      (.thinking, .working),
      (.executingTool(name: "Bash"), .working),
      (.waitingForUser, .ready),
      (.awaitingApproval(tool: "Bash"), .needsAttention),
      (.idle, .idle),
      (nil, .idle),
    ]

    for (status, expectedGroup) in cases {
      let presentation = SessionStatusPresentation(status: status)
      let actualGroup = StatusGroupCategory.category(for: status)

      let mappedCategory: StatusGroupCategory
      switch presentation.category {
      case .working:   mappedCategory = .working
      case .ready:     mappedCategory = .ready
      case .attention: mappedCategory = .needsAttention
      case .idle:      mappedCategory = .idle
      }

      #expect(mappedCategory == actualGroup,
        "Status \(String(describing: status)): expected \(expectedGroup), got \(mappedCategory)")
      #expect(actualGroup == expectedGroup)
    }
  }

  // MARK: - Accessibility labels (pinned)

  @Test("exact accessibility label for each status")
  func pinnedAccessibilityLabels() {
    #expect(SessionStatusPresentation(status: .thinking).accessibilityLabel == "Thinking")
    #expect(SessionStatusPresentation(status: .executingTool(name: "Bash")).accessibilityLabel == "Running tool Bash")
    #expect(SessionStatusPresentation(status: .waitingForUser).accessibilityLabel == "Your turn")
    #expect(SessionStatusPresentation(status: .awaitingApproval(tool: "Bash")).accessibilityLabel == "Needs approval")
    #expect(SessionStatusPresentation(status: .awaitingApproval(tool: "request_user_input")).accessibilityLabel == "Needs input")
    #expect(SessionStatusPresentation(status: .awaitingApproval(tool: "AskUserQuestion")).accessibilityLabel == "Needs input")
    #expect(SessionStatusPresentation(status: .idle).accessibilityLabel == "Idle")
    #expect(SessionStatusPresentation(status: nil).accessibilityLabel == "Idle")
    #expect(SessionStatusPresentation(status: nil, isPending: true).accessibilityLabel == "Starting")
    #expect(SessionStatusPresentation(status: .idle, isPending: true).accessibilityLabel == "Starting")
    #expect(SessionStatusPresentation(status: .thinking, isPending: true).accessibilityLabel == "Thinking")
  }
}
