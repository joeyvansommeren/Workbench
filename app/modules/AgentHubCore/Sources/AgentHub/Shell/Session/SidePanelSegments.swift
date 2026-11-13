//
//  SidePanelSegments.swift
//  AgentHub
//
//  Pure availability rules for a session's side panels, moved out of
//  `MonitoringCardView.toolsMenu`. The legacy Tools menu and the new shell's
//  side-panel segments both read them, so the two never disagree.
//

import Foundation

/// One side panel a session can show.
enum SidePanelSegment: String, CaseIterable, Hashable, Sendable {
  case diff
  case plan
  case edits
  case storybook
  case preview
  case mcpApps
  case measurements
  case studio
  case artifact
  case diagram
  case simulator
  case gitHub
}

/// Everything the availability rules depend on, resolved by the caller.
struct SidePanelAvailability: Equatable, Sendable {
  var diffDisplayMode: DiffDisplayMode = .inline
  var hasStorybook = false
  /// `WebPreviewCandidateVisibility.shouldShow(...)` for this session.
  var showsWebPreview = false
  var queuedPreviewContextCount = 0
  var mcpAppCount = 0
  var measurementCount = 0
  var studioArtifactCount = 0
  /// Claude-only published artifacts (Codex never files any).
  var artifactCount = 0
  var hasMermaidContent = false
  var isXcodeProject = false
  /// The host can open Studio / Artifact panels (legacy: the callback is wired).
  var supportsStudio = true
  var supportsArtifact = true
  /// A code-change tool waits for approval (the legacy "Edits" button).
  var hasPendingCodeChange = false
}

enum SidePanelSegments {
  /// Items of the legacy Tools menu, in menu order.
  static func toolsMenuItems(_ availability: SidePanelAvailability) -> [SidePanelSegment] {
    var items: [SidePanelSegment] = []
    if availability.diffDisplayMode == .sidePanel { items.append(.diff) }
    // Storybook takes precedence when present: showing both would route the
    // same pane to two URLs.
    if availability.hasStorybook {
      items.append(.storybook)
    } else if availability.showsWebPreview {
      items.append(.preview)
    }
    if availability.mcpAppCount > 0 { items.append(.mcpApps) }
    if availability.measurementCount > 0 { items.append(.measurements) }
    if availability.supportsStudio, availability.studioArtifactCount > 0 { items.append(.studio) }
    if availability.supportsArtifact, availability.artifactCount > 0 { items.append(.artifact) }
    if availability.hasMermaidContent { items.append(.diagram) }
    if availability.isXcodeProject { items.append(.simulator) }
    items.append(.gitHub)
    return items
  }

  /// Diff and Plan always lead the new shell's segmented control.
  static let primary: [SidePanelSegment] = [.diff, .plan]

  /// Extra segments after Diff | Plan in the new shell. Edits comes first
  /// while a change waits for approval.
  static func extras(_ availability: SidePanelAvailability) -> [SidePanelSegment] {
    var items: [SidePanelSegment] = availability.hasPendingCodeChange ? [.edits] : []
    items += toolsMenuItems(availability).filter { $0 != .diff }
    return items
  }

  /// At most this many extras sit inline; more collapse into a "More" menu.
  static let maxInlineExtras = 2

  static func inlineExtras(_ availability: SidePanelAvailability) -> [SidePanelSegment] {
    let all = extras(availability)
    return all.count > maxInlineExtras ? [] : all
  }

  static func menuExtras(_ availability: SidePanelAvailability) -> [SidePanelSegment] {
    let all = extras(availability)
    return all.count > maxInlineExtras ? all : []
  }

  /// Keeps a remembered segment only while it is still available.
  static func coerced(
    _ segment: SidePanelSegment,
    availability: SidePanelAvailability
  ) -> SidePanelSegment {
    if primary.contains(segment) || extras(availability).contains(segment) { return segment }
    return .diff
  }

  /// The badge count an extra shows (agent results waiting), if any.
  static func count(for segment: SidePanelSegment, availability: SidePanelAvailability) -> Int? {
    switch segment {
    case .mcpApps: return availability.mcpAppCount
    case .measurements: return availability.measurementCount
    case .studio: return availability.studioArtifactCount
    case .artifact: return availability.artifactCount
    case .preview:
      return availability.queuedPreviewContextCount > 0 ? availability.queuedPreviewContextCount : nil
    default: return nil
    }
  }

  static func title(for segment: SidePanelSegment) -> String {
    switch segment {
    case .diff: return "Diff"
    case .plan: return "Plan"
    case .edits: return "Edits"
    case .storybook: return "Storybook"
    case .preview: return "Preview"
    case .mcpApps: return "MCP apps"
    case .measurements: return "Measurements"
    case .studio: return "Studio"
    case .artifact: return "Artifact"
    case .diagram: return "Diagram"
    case .simulator: return "Simulator"
    case .gitHub: return "GitHub"
    }
  }

  static func systemImage(for segment: SidePanelSegment) -> String {
    switch segment {
    case .diff: return "plusminus"
    case .plan: return "checklist"
    case .edits: return "eye"
    case .storybook: return "book.pages"
    case .preview: return "globe"
    case .mcpApps: return "square.stack.3d.up"
    case .measurements: return "chart.bar.doc.horizontal"
    case .studio: return "paintpalette"
    case .artifact: return "sparkles.rectangle.stack"
    case .diagram: return "chart.xyaxis.line"
    case .simulator: return "iphone.gen3"
    case .gitHub: return "arrow.triangle.pull"
    }
  }

  /// Legacy Tools-menu label (with counts), unchanged from the old menu.
  static func legacyMenuTitle(for segment: SidePanelSegment, availability: SidePanelAvailability) -> String {
    switch segment {
    case .preview where availability.queuedPreviewContextCount > 0:
      return "Preview (\(availability.queuedPreviewContextCount) queued updates)"
    case .mcpApps: return "MCP apps (\(availability.mcpAppCount))"
    case .measurements: return "Measurements (\(availability.measurementCount))"
    case .studio: return "Studio (\(availability.studioArtifactCount))"
    case .artifact: return "Artifact (\(availability.artifactCount))"
    default: return title(for: segment)
    }
  }

  /// Legacy menu icons where they differ from the segment icon.
  static func legacyMenuSystemImage(for segment: SidePanelSegment) -> String {
    segment == .diff ? "arrow.left.arrow.right" : systemImage(for: segment)
  }
}
