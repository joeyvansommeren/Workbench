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

      // Map our StatusCategory to StatusGroupCategory for comparison
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

  // MARK: - Accessibility labels

  @Test("every status has a non-empty accessibility label")
  func accessibilityLabels() {
    let statuses: [SessionStatus?] = [
      .thinking,
      .executingTool(name: "Bash"),
      .waitingForUser,
      .awaitingApproval(tool: "Bash"),
      .awaitingApproval(tool: "request_user_input"),
      .idle,
      nil,
    ]

    for status in statuses {
      let p = SessionStatusPresentation(status: status)
      #expect(!p.accessibilityLabel.isEmpty,
        "Status \(String(describing: status)) has empty accessibility label")
    }

    let pending = SessionStatusPresentation(status: nil, isPending: true)
    #expect(!pending.accessibilityLabel.isEmpty)
  }
}
