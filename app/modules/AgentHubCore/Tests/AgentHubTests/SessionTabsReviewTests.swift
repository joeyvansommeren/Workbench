import Foundation
import Testing

@testable import AgentHubCore

/// Code-review follow-ups for the P6 session view: selection upkeep, restore
/// reporting, prune hand-off, pending migration ordering, cross-window
/// persistence, the commit cooldown, side-panel auto-open and the width budget.
@MainActor
@Suite("SessionTabs review findings")
struct SessionTabsReviewTests {

  // MARK: - Selection upkeep

  @Test("Nothing shown: the first visible restored tab is shown")
  func upkeepPrefersRestoredTab() {
    let model = SessionTabsModel()
    model.restore(["claude-gone", "claude-b", "claude-a"], provider: .claude)
    let decision = model.selectionUpkeep(
      primarySessionId: nil, availableIDs: ["claude-a", "claude-b", "codex-x"])
    #expect(decision == .select("claude-b"))
  }

  @Test("Nothing shown and no restored tab: pick the newest session")
  func upkeepFallsBackToFirstAvailable() {
    let model = SessionTabsModel()
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: ["claude-a"]) == .selectFirstAvailable)
  }

  @Test("No upkeep while something is shown, while sessions are not loaded, or after closing every tab")
  func upkeepDoesNothing() {
    let model = SessionTabsModel()
    #expect(model.selectionUpkeep(primarySessionId: "claude-a", availableIDs: ["claude-a"]) == .none)
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: []) == .none)
    model.open("claude-a")
    model.close("claude-a")
    #expect(model.hasClosedAllTabs)
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: ["claude-a"]) == .none)
    model.open("claude-b")
    #expect(!model.hasClosedAllTabs)
  }

  @Test("Pruning the last tab does not count as the user closing every tab")
  func pruneIsNotUserClose() {
    let model = SessionTabsModel()
    model.open("claude-a")
    model.prune(availableIDs: ["claude-a"])
    model.prune(availableIDs: [])
    #expect(model.openTabIDs.isEmpty)
    #expect(!model.hasClosedAllTabs)
  }

  // MARK: - Restore reporting

  @Test("A tab opened before the read is reported for saving even when restore adds nothing")
  func restoreAlwaysReports() {
    let model = SessionTabsModel()
    var reported: [[String]] = []
    model.onTabsChanged = { reported.append($0) }
    model.open("claude-early")
    reported.removeAll()
    model.restore([], provider: .claude)
    #expect(reported == [["claude-early"]])
    model.restore(["claude-early"], provider: .codex)
    #expect(reported.count == 2)
  }

  // MARK: - Prune hand-off

  @Test("The shown session is pruned: its visible right neighbour is shown")
  func prunedShownSelectsNeighbour() {
    let model = SessionTabsModel()
    ["claude-a", "claude-b", "claude-c"].forEach(model.open)
    model.prune(availableIDs: ["claude-a", "claude-b", "claude-c"])
    let change = model.prune(availableIDs: ["claude-a", "claude-c"], shownID: "claude-b")
    #expect(change == .show("claude-c"))
    #expect(model.selectedTabID == "claude-c")
  }

  @Test("The last shown tab is pruned: the left neighbour is shown, skipping unloaded tabs")
  func prunedLastSelectsLeftVisible() {
    let model = SessionTabsModel()
    model.restore(["claude-unloaded"], provider: .claude)
    ["claude-a", "claude-b"].forEach(model.open)
    model.prune(availableIDs: ["claude-a", "claude-b"])
    let change = model.prune(availableIDs: ["claude-a"], shownID: "claude-b")
    #expect(change == .show("claude-a"))
  }

  @Test("The only shown tab is pruned: nothing is shown")
  func prunedOnlyTabShowsNothing() {
    let model = SessionTabsModel()
    model.open("claude-a")
    model.prune(availableIDs: ["claude-a"])
    #expect(model.prune(availableIDs: [], shownID: "claude-a") == .show(nil))
  }

  @Test("Pruned while the shown session already changed: no hand-off")
  func prunedAfterPrimaryChangedIsNoOp() {
    let model = SessionTabsModel()
    ["claude-a", "claude-b"].forEach(model.open)
    model.prune(availableIDs: ["claude-a", "claude-b"])
    #expect(model.prune(availableIDs: ["claude-a"], shownID: "claude-a") == .unchanged)
    #expect(model.openTabIDs == ["claude-a"])
  }

  // MARK: - Pending migration ordering

  @Test("A resolved pending selection reuses the pending tab")
  func followReusesPendingTab() {
    let model = SessionTabsModel()
    let pendingID = UUID()
    let pendingTab = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    ["claude-a", pendingTab].forEach(model.open)
    // The navigation model switched to the real id before the history change arrived.
    model.follow(
      primarySessionId: "claude-real",
      resolvedHistories: [(.claude, [pendingID: "real"]), (.codex, [:])]
    )
    #expect(model.openTabIDs == ["claude-a", "claude-real"])
    #expect(model.selectedTabID == "claude-real")
  }

  // MARK: - Cross-window persistence

  @Test("The saved list is the ordered union of every window's tabs")
  func aggregateUnion() {
    var aggregate = OpenSessionTabsAggregate()
    let first = UUID()
    let second = UUID()
    #expect(aggregate.update(window: first, ids: ["claude-a", "claude-b"]) == ["claude-a", "claude-b"])
    #expect(aggregate.update(window: second, ids: ["claude-c", "claude-a"]) == ["claude-a", "claude-b", "claude-c"])
  }

  @Test("A window closing a tab never drops another window's tabs")
  func aggregateKeepsOtherWindows() {
    var aggregate = OpenSessionTabsAggregate()
    let first = UUID()
    let second = UUID()
    _ = aggregate.update(window: first, ids: ["claude-a"])
    _ = aggregate.update(window: second, ids: ["claude-b"])
    #expect(aggregate.update(window: first, ids: []) == ["claude-b"])
  }

  @Test("A tab closed in every window is no longer saved")
  func aggregateDropsClosedTabs() {
    var aggregate = OpenSessionTabsAggregate()
    let first = UUID()
    let second = UUID()
    _ = aggregate.update(window: first, ids: ["claude-a", "claude-x"])
    _ = aggregate.update(window: second, ids: ["claude-x"])
    _ = aggregate.update(window: first, ids: ["claude-a"])
    #expect(aggregate.update(window: second, ids: []) == ["claude-a"])
  }

  @Test("Each window has its own id for the union")
  func windowIDsDiffer() {
    #expect(SessionTabsModel().windowID != SessionTabsModel().windowID)
  }

  // MARK: - Commit cooldown

  @Test("Commit cooldown: a second request for the same session waits")
  func commitCooldown() {
    let cooldown = SessionActionCooldown()
    #expect(cooldown.begin("s1"))
    #expect(!cooldown.begin("s1"))
    #expect(cooldown.begin("s2"))
    cooldown.end("s1")
    #expect(cooldown.begin("s1"))
  }

  @Test("Create PR prompt is unchanged")
  func createPullRequestPrompt() {
    #expect(
      CreatePullRequestAction.prompt
        == "Make a PR for the current branch. Include the local changes in this worktree and use the session context for the title, body, and validation notes."
    )
  }

  // MARK: - Side-panel auto-open

  private static let baseline = Date(timeIntervalSince1970: 1_000)

  private static func editItem(toolUseId: String, at date: Date, sessionActivity: Date) -> MonitoringAutoOpenSidePanelItem {
    MonitoringAutoOpenSidePanelItem(
      itemID: "claude-s1",
      providerKind: .claude,
      session: CLISession(id: "s1", projectPath: "/tmp/p", lastActivityAt: sessionActivity),
      state: SessionMonitorState(
        pendingToolUse: PendingToolUse(toolName: "Edit", toolUseId: toolUseId, timestamp: date))
    )
  }

  @Test("A new edit after the baseline opens Edits once")
  func autoOpenNewEditOnce() throws {
    var tracker = SidePanelAutoOpenTracker()
    tracker.start(now: Self.baseline, items: [])
    let item = Self.editItem(toolUseId: "e1", at: Self.baseline + 5, sessionActivity: Self.baseline + 5)
    let candidate = try #require(tracker.candidate(for: item))
    #expect(tracker.decide(candidate, shownSegment: nil) == .edits)
    #expect(tracker.candidate(for: item) == nil)
  }

  @Test("Triggers present when the window started never open")
  func autoOpenSeededTriggerIsSuppressed() {
    var tracker = SidePanelAutoOpenTracker()
    let item = Self.editItem(toolUseId: "e1", at: Self.baseline + 5, sessionActivity: Self.baseline + 5)
    tracker.start(now: Self.baseline, items: [item])
    if let candidate = tracker.candidate(for: item) {
      #expect(tracker.decide(candidate, shownSegment: nil) == nil)
    }
  }

  @Test("Auto-open never replaces a panel the user picked")
  func autoOpenRespectsUserPanel() throws {
    var tracker = SidePanelAutoOpenTracker()
    tracker.start(now: Self.baseline, items: [])
    let item = Self.editItem(toolUseId: "e1", at: Self.baseline + 5, sessionActivity: Self.baseline + 5)
    let candidate = try #require(tracker.candidate(for: item))
    #expect(tracker.decide(candidate, shownSegment: .gitHub) == nil)
    #expect(tracker.candidate(for: item) == nil)
  }

  @Test("Auto-open may replace another auto-opened panel")
  func autoOpenReplacesAutoPanel() throws {
    var tracker = SidePanelAutoOpenTracker()
    tracker.start(now: Self.baseline, items: [])
    let item = Self.editItem(toolUseId: "e1", at: Self.baseline + 5, sessionActivity: Self.baseline + 5)
    let candidate = try #require(tracker.candidate(for: item))
    #expect(tracker.decide(candidate, shownSegment: .plan) == .edits)
  }

  @Test("A session first seen with old activity is suppressed")
  func autoOpenFirstObservedOldSession() throws {
    var tracker = SidePanelAutoOpenTracker()
    tracker.start(now: Self.baseline, items: [])
    let item = Self.editItem(toolUseId: "e1", at: Self.baseline + 5, sessionActivity: Self.baseline - 5)
    let candidate = try #require(tracker.candidate(for: item))
    #expect(tracker.decide(candidate, shownSegment: nil) == nil)
  }

  // MARK: - Width budget

  @Test("Sessions fits the shell's minimum window width")
  func sessionsFitsWindowMinimum() {
    let needed = DesignTokens.Width.sidebar + DesignTokens.Inset.panel + SessionDetailLayout.minimumWidth
    #expect(needed <= ShellLayout.windowMinWidth)
    #expect(ShellLayout.windowMinWidth == 900)
    #expect(SessionDetailLayout.sidePanelMinWidth <= DesignTokens.Width.sidePanel)
    #expect(DesignTokens.Width.sidePanel <= SessionDetailLayout.sidePanelMaxWidth)
  }
}
