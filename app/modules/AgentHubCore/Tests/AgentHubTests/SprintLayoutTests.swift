import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Sprint layout")
struct SprintLayoutTests {
  @Test("Sprint, with a ticket open, keeps one whole column at the shell's minimum window width")
  func fitsWindowMinimum() {
    let needed = DesignTokens.Width.sidebar + SprintLayout.minimumContentWidth + DesignTokens.Inset.panel
    #expect(needed <= ShellLayout.windowMinWidth)
    #expect(
      SprintLayout.minimumContentWidth
        == SprintLayout.columnMinWidth + 2 * SprintLayout.boardInset + SprintLayout.hairlineWidth
        + SprintLayout.detailWidth)
  }

  @Test("Four equal columns need more than the board gets at the minimum, so it scrolls instead")
  func narrowBoardScrolls() {
    let boardWidth =
      ShellLayout.windowMinWidth - DesignTokens.Width.sidebar - DesignTokens.Inset.panel
      - SprintLayout.hairlineWidth - SprintLayout.detailWidth
    let fourColumns =
      CGFloat(SprintBoardView.visibleColumnCount) * SprintLayout.columnMinWidth
      + CGFloat(SprintBoardView.visibleColumnCount - 1) * DesignTokens.Spacing.md
      + 2 * SprintLayout.boardInset
    #expect(boardWidth >= SprintLayout.boardMinWidth)
    #expect(boardWidth < fourColumns)
  }
}

@Suite("Sprint board navigation")
struct SprintBoardNavigationTests {
  private let columns = [["A1", "A2", "A3"], [], ["C1"], ["D1", "D2"]]

  @Test("Nothing selected: any arrow picks the first ticket; an empty board picks nothing")
  func firstTicket() {
    #expect(SprintBoardNavigation.target(columns: columns, selected: nil, direction: .right) == "A1")
    #expect(SprintBoardNavigation.target(columns: [[], []], selected: nil, direction: .down) == nil)
  }

  @Test("Up and down stay in the column and stop at its ends")
  func vertical() {
    #expect(SprintBoardNavigation.target(columns: columns, selected: "A1", direction: .down) == "A2")
    #expect(SprintBoardNavigation.target(columns: columns, selected: "A1", direction: .up) == nil)
    #expect(SprintBoardNavigation.target(columns: columns, selected: "A3", direction: .down) == nil)
  }

  @Test("Left and right skip empty columns and clamp the row")
  func horizontal() {
    #expect(SprintBoardNavigation.target(columns: columns, selected: "A3", direction: .right) == "C1")
    #expect(SprintBoardNavigation.target(columns: columns, selected: "C1", direction: .right) == "D1")
    #expect(SprintBoardNavigation.target(columns: columns, selected: "D2", direction: .right) == nil)
    #expect(SprintBoardNavigation.target(columns: columns, selected: "D2", direction: .left) == "C1")
  }

  @Test("A selection hidden by a filter starts again at the first ticket")
  func hiddenSelection() {
    #expect(SprintBoardNavigation.target(columns: columns, selected: "gone", direction: .down) == "A1")
  }
}

@Suite("Sprint error text")
struct SprintErrorTextTests {
  @Test("Keeps the first non-empty line and caps its length")
  func summary() {
    #expect(SprintErrorText.summary("\n  Error: no such host \nat line 2") == "Error: no such host")
    let long = String(repeating: "x", count: 400)
    let summary = SprintErrorText.summary(long)
    #expect(summary.count == SprintErrorText.maxLength)
    #expect(summary.hasSuffix("…"))
    #expect(SprintErrorText.summary("") == "")
  }
}
