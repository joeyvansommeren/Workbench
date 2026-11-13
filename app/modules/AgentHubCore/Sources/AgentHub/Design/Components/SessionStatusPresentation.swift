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
  /// Filled circle with a check mark. Used for "your turn".
  case filledCheck
  /// Filled circle with an exclamation mark. Used for approval / input.
  case filledBang
  /// Empty ring. Used for idle.
  case ring
}

// MARK: - Status category (mirrors StatusGroupCategory)

/// Colour category for a status glyph.
public enum StatusCategory: String, Sendable, CaseIterable {
  case working
  case ready
  case attention
  case idle
}

// MARK: - Presentation

/// Everything the UI needs to render a session status, computed once
/// from a `SessionStatus?` value. Pure — no side effects, no AppKit.
public struct SessionStatusPresentation: Equatable, Sendable {

  /// The glyph shape to draw.
  public let shape: StatusGlyphShape

  /// The colour category (drives fill, text and tint token choice).
  public let category: StatusCategory

  /// Human-readable word for labels and chips.
  public let word: String

  /// Accessibility label for VoiceOver.
  public let accessibilityLabel: String

  /// Create a presentation for the given status.
  ///
  /// - Parameters:
  ///   - status: The session status, or `nil` for idle.
  ///   - isPending: `true` when the session is still starting
  ///     (pending / "Starting"). Overrides `nil` to show a breathing dot.
  public init(status: SessionStatus?, isPending: Bool = false) {
    if isPending, status == nil || status == .idle {
      self.shape = .breathingDot
      self.category = .working
      self.word = "Starting"
      self.accessibilityLabel = "Starting"
      return
    }

    switch status {
    case .thinking:
      self.shape = .breathingDot
      self.category = .working
      self.word = "Thinking"
      self.accessibilityLabel = "Thinking"

    case .executingTool(let name):
      self.shape = .spinningArc
      self.category = .working
      self.word = "Running \(name)"
      self.accessibilityLabel = "Running tool \(name)"

    case .waitingForUser:
      self.shape = .filledCheck
      self.category = .ready
      self.word = "Your turn"
      self.accessibilityLabel = "Your turn"

    case .awaitingApproval(let tool):
      self.shape = .filledBang
      self.category = .attention
      let isInput = SessionInteractiveInputTool.matches(tool)
      let label = isInput ? "Needs input" : "Needs approval"
      self.word = label
      self.accessibilityLabel = label

    case .idle, .none:
      self.shape = .ring
      self.category = .idle
      self.word = "Idle"
      self.accessibilityLabel = "Idle"
    }
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
