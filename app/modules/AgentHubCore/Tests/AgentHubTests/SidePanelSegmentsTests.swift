import Testing

@testable import AgentHubCore

@Suite("SidePanelSegments")
struct SidePanelSegmentsTests {

  @Test("Legacy menu: only GitHub when nothing else applies")
  func minimalMenu() {
    #expect(SidePanelSegments.toolsMenuItems(SidePanelAvailability()) == [.gitHub])
  }

  @Test("Legacy menu: Diff only in side-panel diff mode")
  func diffOnlyInSidePanelMode() {
    var availability = SidePanelAvailability()
    availability.diffDisplayMode = .sidePanel
    #expect(SidePanelSegments.toolsMenuItems(availability).first == .diff)
    availability.diffDisplayMode = .inline
    #expect(!SidePanelSegments.toolsMenuItems(availability).contains(.diff))
  }

  @Test("Storybook replaces Preview; never both")
  func storybookAndPreviewAreExclusive() {
    var availability = SidePanelAvailability(hasStorybook: true, showsWebPreview: true)
    var items = SidePanelSegments.toolsMenuItems(availability)
    #expect(items.contains(.storybook))
    #expect(!items.contains(.preview))

    availability.hasStorybook = false
    items = SidePanelSegments.toolsMenuItems(availability)
    #expect(items.contains(.preview))
    #expect(!items.contains(.storybook))

    availability.showsWebPreview = false
    items = SidePanelSegments.toolsMenuItems(availability)
    #expect(!items.contains(.preview))
    #expect(!items.contains(.storybook))
  }

  @Test("Legacy menu order is unchanged")
  func fullMenuOrder() {
    let availability = SidePanelAvailability(
      diffDisplayMode: .sidePanel,
      showsWebPreview: true,
      mcpAppCount: 1,
      measurementCount: 2,
      studioArtifactCount: 3,
      artifactCount: 4,
      hasMermaidContent: true,
      isXcodeProject: true
    )
    #expect(
      SidePanelSegments.toolsMenuItems(availability) == [
        .diff, .preview, .mcpApps, .measurements, .studio, .artifact, .diagram, .simulator, .gitHub,
      ])
  }

  @Test("Counts gate the agent-result items")
  func zeroCountsHideItems() {
    let items = SidePanelSegments.toolsMenuItems(
      SidePanelAvailability(mcpAppCount: 0, measurementCount: 0, studioArtifactCount: 0, artifactCount: 0))
    #expect(items == [.gitHub])
  }

  @Test("Studio and Artifact need a host that can open them")
  func unsupportedHostHidesStudioAndArtifact() {
    let availability = SidePanelAvailability(
      studioArtifactCount: 1, artifactCount: 1, supportsStudio: false, supportsArtifact: false)
    let items = SidePanelSegments.toolsMenuItems(availability)
    #expect(!items.contains(.studio))
    #expect(!items.contains(.artifact))
  }

  @Test("Legacy labels keep their counts")
  func legacyTitles() {
    let availability = SidePanelAvailability(queuedPreviewContextCount: 2, mcpAppCount: 3)
    #expect(SidePanelSegments.legacyMenuTitle(for: .preview, availability: availability) == "Preview (2 queued updates)")
    #expect(SidePanelSegments.legacyMenuTitle(for: .mcpApps, availability: availability) == "MCP apps (3)")
    #expect(SidePanelSegments.legacyMenuTitle(for: .gitHub, availability: availability) == "GitHub")
    #expect(
      SidePanelSegments.legacyMenuTitle(for: .preview, availability: SidePanelAvailability()) == "Preview")
  }

  @Test("Shell extras: Diff stays primary, Edits leads while a change waits")
  func shellExtras() {
    let availability = SidePanelAvailability(
      diffDisplayMode: .sidePanel, isXcodeProject: true, hasPendingCodeChange: true)
    #expect(SidePanelSegments.extras(availability) == [.edits, .simulator, .gitHub])
    #expect(SidePanelSegments.primary == [.diff, .plan])
  }

  @Test("Two extras sit inline; more collapse into the More menu")
  func inlineAndMenuSplit() {
    let two = SidePanelAvailability(isXcodeProject: true)
    #expect(SidePanelSegments.inlineExtras(two) == [.simulator, .gitHub])
    #expect(SidePanelSegments.menuExtras(two).isEmpty)

    let three = SidePanelAvailability(hasMermaidContent: true, isXcodeProject: true)
    #expect(SidePanelSegments.inlineExtras(three).isEmpty)
    #expect(SidePanelSegments.menuExtras(three) == [.diagram, .simulator, .gitHub])
  }

  @Test("A remembered segment falls back to Diff once it is gone")
  func coercion() {
    let none = SidePanelAvailability()
    #expect(SidePanelSegments.coerced(.plan, availability: none) == .plan)
    #expect(SidePanelSegments.coerced(.simulator, availability: none) == .diff)
    #expect(SidePanelSegments.coerced(.simulator, availability: SidePanelAvailability(isXcodeProject: true)) == .simulator)
  }
}
