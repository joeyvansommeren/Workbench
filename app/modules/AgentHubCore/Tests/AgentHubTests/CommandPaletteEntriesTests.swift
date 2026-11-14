import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Command palette entries")
struct CommandPaletteEntriesTests {
  private func session(
    _ id: String,
    _ title: String,
    branch: String = "main",
    status: SessionStatus?,
    isPending: Bool = false
  ) -> CommandPaletteSessionInput {
    CommandPaletteSessionInput(itemID: id, title: title, branch: branch, status: status, isPending: isPending)
  }

  private let pullRequest = CommandPalettePullRequestInput(
    id: "PR_1",
    title: "Replace the acli hint",
    number: 212,
    repositoryName: "workbench",
    repositoryNameWithOwner: "joey/workbench"
  )

  @Test("Sessions sort attention > ready > running > thinking > idle")
  func statusOrder() {
    let sessions = [
      session("idle", "Idle one", status: .idle),
      session("thinking", "Thinking one", status: .thinking),
      session("running", "Running one", status: .executingTool(name: "Bash")),
      session("ready", "Ready one", status: .waitingForUser),
      session("attention", "Attention one", status: .awaitingApproval(tool: "Edit")),
    ]
    let entries = CommandPaletteEntries.build(query: "one", sessions: sessions, pullRequests: [])
    #expect(entries.map(\.id) == [
      "session-attention", "session-ready", "session-running", "session-thinking", "session-idle",
    ])
    #expect(entries.first?.trailingText == "Needs approval")
  }

  @Test("A typed query caps Sessions and Pull requests and counts the rest")
  func typedQueryIsCappedPerGroup() {
    let sessions = (0..<30).map { session("s\($0)", "Fix \($0)", status: .idle) }
    let pullRequests = (0..<4).map {
      CommandPalettePullRequestInput(
        id: "PR_\($0)", title: "Fix bug \($0)", number: $0, repositoryName: "workbench",
        repositoryNameWithOwner: "joey/workbench")
    }
    let results = CommandPaletteEntries.results(
      query: "fix", sessions: sessions, pullRequests: pullRequests, groupLimit: 25)
    #expect(results.entries.filter { $0.group == .sessions }.count == 25)
    #expect(results.entries.filter { $0.group == .pullRequests }.count == 4)
    #expect(results.moreText(for: .sessions) == "5 more, keep typing")
    #expect(results.moreText(for: .pullRequests) == nil)
    // The kept rows are the first matches, in order.
    #expect(results.entries.first?.id == "session-s0")

    let idle = CommandPaletteEntries.results(query: "", sessions: sessions, pullRequests: pullRequests)
    #expect(idle.hiddenCounts.isEmpty)
  }

  @Test("Equal status keeps the caller's order; a pending session counts as thinking")
  func stableWithinRank() {
    let sessions = [
      session("a", "A", status: .idle),
      session("starting", "Starting", status: nil, isPending: true),
      session("b", "B", status: .idle),
      session("c", "C", status: .thinking),
    ]
    let entries = CommandPaletteEntries.build(query: "", sessions: sessions, pullRequests: [])
      .filter { $0.group == .sessions }
    #expect(entries.map(\.id) == ["session-starting", "session-c", "session-a", "session-b"])
  }

  @Test("Empty query: four sessions, Go to, three commands")
  func idleList() {
    let sessions = (0..<6).map { session("s\($0)", "Session \($0)", status: .idle) }
    let entries = CommandPaletteEntries.build(query: "  ", sessions: sessions, pullRequests: [pullRequest])
    #expect(entries.filter { $0.group == .sessions }.count == 4)
    #expect(entries.filter { $0.group == .pullRequests }.isEmpty)
    #expect(entries.filter { $0.group == .goTo }.map(\.title) == ["Sessions", "Reviews", "Jira", "Linear"])
    #expect(entries.filter { $0.group == .commands }.map(\.title) == [
      "New session", "Resume session by ID", "Toggle side panel",
    ])
    // Groups appear in order.
    #expect(entries.map(\.group).reduce(into: [CommandPaletteGroup]()) { groups, group in
      if groups.last != group { groups.append(group) }
    } == [.sessions, .goTo, .commands])
  }

  @Test("A query matches title or meta, case-insensitively, across every group")
  func filtering() {
    let sessions = [
      session("s1", "Fix acli install hint", branch: "fix/acli-install-hint", status: .idle),
      session("s2", "Restore tab order", branch: "feat/session-tabs", status: .idle),
    ]
    let byBranch = CommandPaletteEntries.build(query: "SESSION-TABS", sessions: sessions, pullRequests: [])
    #expect(byBranch.map(\.id) == ["session-s2"])

    let acli = CommandPaletteEntries.build(query: "acli", sessions: sessions, pullRequests: [pullRequest])
    #expect(acli.map(\.id) == ["session-s1", "pr-PR_1"])

    let settings = CommandPaletteEntries.build(query: "settings", sessions: sessions, pullRequests: [])
    #expect(settings.map(\.target) == [.command(.openSettings)])

    #expect(CommandPaletteEntries.build(query: "zzz", sessions: sessions, pullRequests: []).isEmpty)
  }

  @Test("Highlight ranges cover the first match in title and meta")
  func highlights() throws {
    let sessions = [session("s1", "Fix acli install hint", branch: "fix/acli-install-hint", status: .idle)]
    let entry = try #require(
      CommandPaletteEntries.build(query: "Install", sessions: sessions, pullRequests: []).first
    )
    let titleRange = try #require(entry.titleHighlight)
    let metaRange = try #require(entry.metaHighlight)
    #expect(entry.title[titleRange] == "install")
    #expect(entry.meta[metaRange] == "install")

    let noQuery = try #require(
      CommandPaletteEntries.build(query: "", sessions: sessions, pullRequests: []).first
    )
    #expect(noQuery.titleHighlight == nil)
    #expect(noQuery.metaHighlight == nil)
  }

  @Test("Pull requests show repo and number and target the review")
  func pullRequestEntry() throws {
    let entry = try #require(
      CommandPaletteEntries.build(query: "#212", sessions: [], pullRequests: [pullRequest]).first
    )
    #expect(entry.meta == "workbench #212")
    #expect(entry.lead == .tile(name: "workbench", colorKey: "joey/workbench"))
    #expect(entry.target == .pullRequest(id: "PR_1", repositoryNameWithOwner: "joey/workbench", number: 212))
  }

  @Test("Go to and Commands carry the menu shortcuts")
  func shortcuts() {
    let entries = CommandPaletteEntries.build(query: "", sessions: [], pullRequests: [])
    let keysByTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0.keys) })
    #expect(keysByTitle["Sessions"] == ["⌘", "1"])
    #expect(keysByTitle["Reviews"] == ["⌘", "2"])
    #expect(keysByTitle["Jira"] == ["⌘", "3"])
    #expect(keysByTitle["Linear"] == ["⌘", "4"])
    #expect(keysByTitle["New session"] == ["⌘", "N"])
    #expect(keysByTitle["Resume session by ID"] == ["⇧", "⌘", "R"])
    #expect(keysByTitle["Toggle side panel"] == ["⌥", "⌘", "0"])
    #expect(CommandPaletteCommand.toggleSidebar.keys == ["⌃", "⌘", "S"])
    #expect(CommandPaletteCommand.openSettings.keys == ["⌘", ","])
    #expect(CommandPaletteCommand.switchAppearance.keys.isEmpty)
  }

  @Test("Go to and Commands read the same shortcut table as the menu bar")
  func sharedShortcutTable() {
    let entries = CommandPaletteEntries.build(query: "", sessions: [], pullRequests: [])
    for destination in ShellDestination.allCases {
      let entry = entries.first { $0.target == .destination(destination) }
      #expect(entry?.title == destination.title)
      #expect(entry?.keys == destination.shortcut.keyCaps)
    }
    #expect(CommandPaletteCommand.newSession.shortcut == .newSession)
    #expect(CommandPaletteCommand.resumeSessionByID.shortcut == .resumeSessionByID)
    #expect(CommandPaletteCommand.toggleSidebar.shortcut == .toggleSidebar)
    #expect(CommandPaletteCommand.toggleSidePanel.shortcut == .toggleSidePanel)
    #expect(entries.first { $0.target == .destination(.reviews) }?.lead == .pullRequestGlyph)
  }

  @Test("The highlighted row follows its entry when sessions reorder")
  func activeRowFollowsEntry() {
    let before = CommandPaletteEntries.build(
      query: "",
      sessions: [session("a", "A", status: .waitingForUser), session("b", "B", status: .idle)],
      pullRequests: []
    )
    // The user moved the highlight to B…
    let picked = before[CommandPaletteEntries.activeIndex(for: "session-b", in: before)].id
    #expect(picked == "session-b")
    // …then B starts asking for approval and moves to the top.
    let after = CommandPaletteEntries.build(
      query: "",
      sessions: [session("a", "A", status: .waitingForUser), session("b", "B", status: .awaitingApproval(tool: "Edit"))],
      pullRequests: []
    )
    #expect(after[CommandPaletteEntries.activeIndex(for: picked, in: after)].id == "session-b")
    // No pick yet, or a pick that is gone: the first row.
    #expect(CommandPaletteEntries.activeIndex(for: nil, in: after) == 0)
    #expect(CommandPaletteEntries.activeIndex(for: "session-gone", in: after) == 0)
  }

  @Test("Opening and closing the palette toggles the overlay state")
  func overlayModel() {
    let overlays = ShellOverlayModel()
    #expect(!overlays.isPaletteOpen)
    overlays.togglePalette()
    #expect(overlays.isPaletteOpen)
    overlays.openPalette()
    #expect(overlays.isPaletteOpen)
    overlays.closePalette()
    #expect(!overlays.isPaletteOpen)
  }
}
