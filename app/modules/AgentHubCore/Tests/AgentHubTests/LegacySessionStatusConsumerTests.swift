import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Legacy session status consumers")
struct LegacySessionStatusConsumerTests {
  @Test("Legacy row and project card show waiting as a request, not green Ready")
  func waitingIsNotSuccess() {
    for presentation in consumerPresentations(status: .waitingForUser) {
      #expect(presentation.word == "Waiting for you")
      #expect(presentation.activity == .waiting)
      #expect(presentation.outcome == .unknown)
      #expect(presentation.category == .attention)
      #expect(presentation.shape != .filledCheck)
      #expect(presentation.accessibilityLabel == "Waiting for you, outcome unknown")
      #expect(
        presentation.textColor == SessionStatusPresentation(status: .waitingForUser).textColor)
    }
  }

  @Test("Missing status stays unknown regardless of transcript activity")
  func missingStatusIsUnknown() {
    for isActive in [true, false] {
      for presentation in consumerPresentations(status: nil, isActive: isActive) {
        #expect(presentation.word == "Status unknown")
        #expect(presentation.activity == .unknown)
        #expect(presentation.outcome == .unknown)
        #expect(presentation.category == .idle)
        #expect(presentation.accessibilityLabel == "Status unknown, outcome unknown")
      }
    }
  }

  @Test("Real pending launches keep Starting until active status arrives")
  func pendingLaunchesKeepStarting() {
    for status in [nil, SessionStatus.idle] {
      for presentation in consumerPresentations(status: status, isPending: true) {
        #expect(presentation.word == "Starting")
        #expect(presentation.activity == .starting)
        #expect(presentation.category == .working)
        #expect(presentation.accessibilityLabel == "Starting, outcome unknown")
      }
    }
    for presentation in consumerPresentations(status: .thinking, isPending: true) {
      #expect(presentation.word == "Thinking")
      #expect(presentation.activity == .running)
    }
  }

  private func consumerPresentations(
    status: SessionStatus?,
    isPending: Bool = false,
    isActive: Bool = false
  ) -> [SessionStatusPresentation] {
    let session = CLISession(
      id: "status-consumer", projectPath: "/tmp/status-repo", isActive: isActive)
    let row = CollapsibleSessionRow(
      session: session, providerKind: .claude, timestamp: .distantPast,
      isPending: isPending, isPrimary: false, customName: nil, sessionStatus: status,
      colorScheme: .light, isPinned: false, onPin: nil, onArchive: nil, onSelect: {})
    let card = ProjectDetailsSessionItem(
      id: "status-consumer", session: session, providerKind: .claude, timestamp: .distantPast,
      isPending: isPending, status: status, customName: nil)
    return [row.statusPresentation, card.statusPresentation]
  }
}
