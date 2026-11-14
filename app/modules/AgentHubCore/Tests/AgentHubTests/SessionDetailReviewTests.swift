import Foundation
import Testing

@testable import AgentHubCore

/// Code-review follow-ups for the P6 session view: cross-window persistence,
/// the commit cooldown, side-panel auto-open and the width budget.
@MainActor
@Suite("Session detail review findings")
struct SessionDetailReviewTests {

  // MARK: - Cross-window persistence

  @Test("The saved list is the ordered union of every window's shown sessions")
  func aggregateUnion() {
    var aggregate = OpenSessionTabsAggregate()
    let first = UUID()
    let second = UUID()
    #expect(aggregate.update(window: first, ids: ["claude-a", "claude-b"]) == ["claude-a", "claude-b"])
    #expect(aggregate.update(window: second, ids: ["claude-c", "claude-a"]) == ["claude-a", "claude-b", "claude-c"])
  }

  @Test("A window moving on never drops another window's session")
  func aggregateKeepsOtherWindows() {
    var aggregate = OpenSessionTabsAggregate()
    let first = UUID()
    let second = UUID()
    _ = aggregate.update(window: first, ids: ["claude-a"])
    _ = aggregate.update(window: second, ids: ["claude-b"])
    #expect(aggregate.update(window: first, ids: []) == ["claude-b"])
  }

  @Test("A session no window shows any more is no longer saved")
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
    #expect(SessionDetailStateModel().windowID != SessionDetailStateModel().windowID)
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
