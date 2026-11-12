import Testing
@testable import AgentHubCore

@Suite("Session columns")
struct SessionColumnsStateTests {
  @Test func addsDistinctSessionsInOrder() {
    var state = SessionColumnsState()
    state.add("codex-b", beside: "claude-a")
    state.add("codex-c", beside: "codex-b")
    state.add("codex-b", beside: "claude-a")
    #expect(state.itemIDs == ["claude-a", "codex-b", "codex-c"])
  }

  @Test func focusingAColumnKeepsTheLayout() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.select("b", replacing: "a")
    #expect(state.itemIDs == ["a", "b"])
    state.select("a", replacing: "b")
    #expect(state.itemIDs == ["a", "b"])
  }

  @Test func outsideSelectionReplacesTheActiveColumnOnly() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.add("c", beside: "a")
    state.select("x", replacing: "b")
    #expect(state.itemIDs == ["a", "x", "c"])
    // No known previous column: the first slot gives way.
    state.select("y", replacing: nil)
    #expect(state.itemIDs == ["y", "x", "c"])
    // A previous id that is not a column falls back to the first slot too.
    state.select("z", replacing: "gone")
    #expect(state.itemIDs == ["z", "x", "c"])
  }

  @Test func selectingNothingOrWithoutColumnsChangesNothing() {
    var state = SessionColumnsState()
    state.select("a", replacing: nil)
    #expect(state.itemIDs.isEmpty)
    state.add("b", beside: "a")
    state.select(nil, replacing: "a")
    #expect(state.itemIDs == ["a", "b"])
  }

  @Test func closingTheFocusedColumnLeavesTheOthers() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.add("c", beside: "a")
    state.remove("b")
    #expect(state.itemIDs == ["a", "c"])
    // The caller then makes the first remaining column primary.
    #expect(state.itemIDs.first == "a")
  }

  @Test func disappearedSessionsArePrunedWithoutReplacingOthers() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.add("c", beside: "a")
    state.retainAvailable(["a", "c"])
    #expect(state.itemIDs == ["a", "c"])
    state.retainAvailable([])
    #expect(state.itemIDs.isEmpty)
  }

  @Test func closeColumnsIsTheOnlyExit() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.select("outside", replacing: "a")
    #expect(state.itemIDs.count == 2)
    state = SessionColumnsState()
    #expect(state.itemIDs.isEmpty)
  }

  @Test func draggedWidthSurvivesASessionTakingOverTheColumn() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    #expect(state.widthShares == [0.5, 0.5])
    state.resize(divider: 0, from: state.widthShares, by: 0.2, minShare: 0.1)
    state.select("x", replacing: "b")
    #expect(state.itemIDs == ["a", "x"])
    #expect(abs(state.widthShares[0] - 0.7) < 0.0001)
    #expect(abs(state.widthShares[1] - 0.3) < 0.0001)
  }

  @Test func resizeStopsAtTheMinimumWidth() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.resize(divider: 0, from: state.widthShares, by: 0.9, minShare: 0.25)
    #expect(state.widthShares == [0.75, 0.25])
  }

  @Test func addingAndClosingKeepsTheOtherProportions() {
    var state = SessionColumnsState()
    state.add("b", beside: "a")
    state.resize(divider: 0, from: state.widthShares, by: 0.1, minShare: 0.1)
    state.add("c", beside: "a")
    // a:b stays 6:4, c gets an even third.
    #expect(abs(state.widthShares[0] - 0.4) < 0.0001)
    #expect(abs(state.widthShares[1] - 4.0 / 15.0) < 0.0001)
    #expect(abs(state.widthShares[2] - 1.0 / 3.0) < 0.0001)
    state.remove("c")
    #expect(abs(state.widthShares[0] - 0.6) < 0.0001)
    #expect(abs(state.widthShares[1] - 0.4) < 0.0001)
  }
}
