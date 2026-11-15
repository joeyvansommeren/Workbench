//
//  SessionStatusPresentation.swift
//  AgentHub
//
//  Pure mapping from SessionStatus to glyph shape, colour tokens and
//  display word. Does not touch SessionStatus.displayName, which voice
//  and the columns still use.
//

import SwiftUI

// MARK: - Glyph shape

/// The shape a StatusGlyph draws.
public enum StatusGlyphShape: String, Sendable, CaseIterable {
  /// Filled dot with a breathing halo. Used for thinking / starting.
  case breathingDot
  /// Spinning arc. Used for tool execution.
  case spinningArc
  /// Filled circle with a check mark. Used only for an explicit successful outcome.
  case filledCheck
  /// Filled circle with an exclamation mark. Used for approval / input.
  case filledBang
  /// Empty ring. Used for idle.
  case ring
}

// MARK: - Visual category

/// Colour category for a status glyph.
public enum StatusCategory: String, Sendable, CaseIterable {
  case working
  case ready
  case attention
  case idle
}

// MARK: - Independent activity and outcome

/// Provider activity does not establish whether the user accepted the work.
public enum SessionActivity: String, Equatable, Sendable {
  case starting
  case running
  case waiting
  case inactive
  case unknown
}

/// Only explicit, current-version evidence may supply a product outcome.
public enum SessionOutcome: String, Codable, Equatable, Sendable {
  case unknown
  case needsInput
  case needsApproval
  case readyToInspect
  case changesRequested
  case accepted
  case finished

  public var displayName: String {
    switch self {
    case .unknown: "Outcome unknown"
    case .needsInput: "Needs input"
    case .needsApproval: "Needs approval"
    case .readyToInspect: "Ready to inspect"
    case .changesRequested: "Changes requested"
    case .accepted: "Accepted"
    case .finished: "Finished"
    }
  }
}

// MARK: - Presentation

/// Pure presentation of provider activity and separately evidenced outcome.
public struct SessionStatusPresentation: Equatable, Sendable {
  public let activity: SessionActivity
  public let outcome: SessionOutcome
  public let shape: StatusGlyphShape
  public let category: StatusCategory
  public let word: String
  public let accessibilityLabel: String

  /// Callers must bind an explicit outcome to the current result version.
  /// A quiet, missing or completed provider turn never supplies acceptance.
  public init(
    status: SessionStatus?,
    isPending: Bool = false,
    outcome: SessionOutcome = .unknown
  ) {
    if isPending, status == nil || status == .idle {
      activity = .starting
      self.outcome = .unknown
      shape = .breathingDot
      category = .working
      word = "Starting"
      accessibilityLabel = "Starting, outcome unknown"
      return
    }

    switch status {
    case .thinking, .executingTool: activity = .running
    case .waitingForUser, .awaitingApproval: activity = .waiting
    case .idle: activity = .inactive
    case nil: activity = .unknown
    }

    // A live request takes precedence over an earlier result outcome.
    if case .awaitingApproval(let tool) = status {
      self.outcome = SessionInteractiveInputTool.matches(tool) ? .needsInput : .needsApproval
    } else {
      self.outcome = activity == .running ? .unknown : outcome
    }

    // Running activity stays visible. A new run must not look accepted merely
    // because a caller still holds the previous result's acceptance.
    if activity == .running {
      self.shape = status == .thinking ? .breathingDot : .spinningArc
      category = .working
      switch status {
      case .executingTool(let name):
        word = "Running \(name)"
        accessibilityLabel = "Running tool \(name), outcome unknown"
      default:
        word = "Thinking"
        accessibilityLabel = "Thinking, outcome unknown"
      }
      return
    }

    switch self.outcome {
    case .needsInput, .needsApproval, .changesRequested:
      shape = .filledBang
      category = .attention
      word = self.outcome.displayName
    case .accepted, .finished:
      shape = .filledCheck
      category = .ready
      word = self.outcome.displayName
    case .readyToInspect:
      shape = .ring
      category = .idle
      word = self.outcome.displayName
    case .unknown:
      switch activity {
      case .waiting:
        shape = .filledBang
        category = .attention
        word = "Waiting for you"
      case .inactive:
        shape = .ring
        category = .idle
        word = "Inactive"
      case .unknown:
        shape = .ring
        category = .idle
        word = "Status unknown"
      case .starting, .running:
        // Handled above; kept exhaustive without deriving an outcome.
        shape = .breathingDot
        category = .working
        word = "Working"
      }
    }
    accessibilityLabel = self.outcome == .unknown ? "\(word), outcome unknown" : word
  }

  /// The fill colour for the glyph.
  @MainActor
  public var fillColor: Color {
    switch category {
    case .working:   return .wbStatusWorkingFill
    case .ready:     return .wbStatusReadyFill
    case .attention: return .wbStatusAttentionFill
    case .idle:      return .wbStatusIdleFill
    }
  }

  /// The text colour for chips and labels.
  @MainActor
  public var textColor: Color {
    switch category {
    case .working:   return .wbStatusWorkingText
    case .ready:     return .wbStatusReadyText
    case .attention: return .wbStatusAttentionText
    case .idle:      return .wbStatusIdleText
    }
  }

  /// The tint (background) colour for chips.
  @MainActor
  public var tintColor: Color {
    switch category {
    case .working:   return .wbStatusWorkingTint
    case .ready:     return .wbStatusReadyTint
    case .attention: return .wbStatusAttentionTint
    case .idle:      return .wbStatusIdleTint
    }
  }

  /// The ink colour drawn inside filled glyphs (check, bang).
  @MainActor
  public var glyphInkColor: Color { .wbStatusGlyphInk }
}
