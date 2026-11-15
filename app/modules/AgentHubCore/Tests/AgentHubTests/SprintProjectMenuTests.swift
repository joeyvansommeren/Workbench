import AgentWorkflowLinear
import AppKit
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint project menu")
struct SprintProjectMenuTests {
  private func idealWidth<V: View>(_ view: V) -> CGFloat {
    NSHostingView(rootView: view).fittingSize.width
  }

  private let projects = [
    LinearProject(id: "p1", name: "Onboarding"),
    LinearProject(id: "p2", name: String(repeating: "A very long project name ", count: 6)),
  ]

  @Test("A long project name truncates at the label's cap")
  func fullLabelIsCapped() {
    let long = SprintProjectMenu(projects: projects, selected: projects[1], isCompact: false) { _ in }
    let short = SprintProjectMenu(projects: projects, selected: nil, isCompact: false) { _ in }
    #expect(idealWidth(long) <= SprintProjectMenu.labelMaxWidth)
    #expect(idealWidth(short) <= SprintProjectMenu.labelMaxWidth)
  }

  @Test("The compact menu is one 28 pt control, whatever is selected")
  func compactIsOneControl() {
    let compact = SprintProjectMenu(projects: projects, selected: projects[1], isCompact: true) { _ in }
    #expect(idealWidth(compact) == DesignTokens.Size.control)
  }

  /// The narrowest head (`SprintListHeadCompactRow`: compact menu, Refresh,
  /// Filters with a search active) at the 900 pt minimum with a ticket open.
  /// The real row is measured, not assumed.
  @Test("The narrowest Linear head keeps the project menu at 900 pt with a ticket open")
  func narrowestHeadFits() {
    let boardWidth =
      ShellLayout.windowMinWidth - DesignTokens.Width.sidebar - DesignTokens.Inset.panel
      - SprintLayout.hairlineWidth - SprintLayout.detailWidth
    let headContent = boardWidth - DesignTokens.Spacing.lg - DesignTokens.Spacing.md
    let row = idealWidth(
      SprintListHeadCompactRow {
        SprintProjectMenu(projects: projects, selected: projects[0], isCompact: true) { _ in }
      } trailing: {
        SprintRefreshButton(isLoading: false, accessibilityLabel: "Refresh issues") {}
        FiltersButton(activeCount: 1, onOpen: {}, onClear: {})
      })
    #expect(row <= headContent, "row \(row) > head \(headContent)")
  }
}
