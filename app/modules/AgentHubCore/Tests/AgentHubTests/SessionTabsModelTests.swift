import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("SessionTabsModel")
struct SessionTabsModelTests {

  // MARK: - Open, select, close

  @Test("Open appends and selects; opening again only selects")
  func openDedupes() {
    let model = SessionTabsModel()
    model.open("claude-a")
    model.open("claude-b")
    model.open("claude-a")
    #expect(model.openTabIDs == ["claude-a", "claude-b"])
    #expect(model.selectedTabID == "claude-a")
  }

  @Test("Closing the selected tab selects its right neighbour")
  func closeSelectsRightNeighbour() {
    let model = SessionTabsModel()
    ["claude-a", "claude-b", "claude-c"].forEach(model.open)
    model.select("claude-b")
    #expect(model.close("claude-b") == "claude-c")
    #expect(model.openTabIDs == ["claude-a", "claude-c"])
  }

  @Test("Closing the last tab selects its left neighbour")
  func closeLastSelectsLeftNeighbour() {
    let model = SessionTabsModel()
    ["claude-a", "claude-b"].forEach(model.open)
    #expect(model.close("claude-b") == "claude-a")
  }

  @Test("Closing the only tab leaves nothing selected")
  func closeOnlyTab() {
    let model = SessionTabsModel()
    model.open("claude-a")
    #expect(model.close("claude-a") == nil)
    #expect(model.openTabIDs.isEmpty)
  }

  @Test("Closing an unselected tab keeps the selection")
  func closeOtherTabKeepsSelection() {
    let model = SessionTabsModel()
    ["claude-a", "claude-b", "claude-c"].forEach(model.open)
    #expect(model.close("claude-a") == "claude-c")
    #expect(model.selectedTabID == "claude-c")
  }

  @Test("Closing drops the tab's content mode and side-panel segment")
  func closeDropsPerTabState() {
    let model = SessionTabsModel()
    model.open("claude-a")
    model.setContentMode(.chat, for: "claude-a", defaultProjectPath: "/p")
    model.setSidePanelSegment(.plan, for: "claude-a")
    model.close("claude-a")
    model.open("claude-a")
    #expect(model.contentMode(for: "claude-a") == .terminal)
    #expect(model.sidePanelSegment(for: "claude-a") == .diff)
  }

  @Test("Opening a file routes the tab to Files with a navigation request")
  func openFileSwitchesToFiles() {
    let model = SessionTabsModel()
    model.open("claude-a")
    model.openFile("/p/a.swift", lineNumber: 4, projectPath: "/p", for: "claude-a")
    let state = model.editorState(for: "claude-a", defaultProjectPath: "/other")
    #expect(state.contentMode == .editor)
    #expect(state.selectedFilePath == "/p/a.swift")
    #expect(state.navigationRequest?.lineNumber == 4)
  }

  // MARK: - Pending → resolved

  @Test("A pending tab takes the resolved id in place, with its state")
  func pendingMigratesInPlace() {
    let model = SessionTabsModel()
    let pendingID = UUID()
    let pendingTab = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    ["claude-a", pendingTab, "claude-c"].forEach(model.open)
    model.select(pendingTab)
    model.setContentMode(.chat, for: pendingTab, defaultProjectPath: "/p")

    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .claude)

    #expect(model.openTabIDs == ["claude-a", "claude-real", "claude-c"])
    #expect(model.selectedTabID == "claude-real")
    #expect(model.contentMode(for: "claude-real") == .chat)
  }

  @Test("A pending tab whose session is already open is dropped")
  func pendingMigrationDropsDuplicate() {
    let model = SessionTabsModel()
    let pendingID = UUID()
    let pendingTab = SidebarSessionItemID.pending(provider: .codex, pendingId: pendingID)
    ["codex-real", pendingTab].forEach(model.open)
    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .codex)
    #expect(model.openTabIDs == ["codex-real"])
  }

  @Test("Resolutions of the other provider are ignored")
  func migrationIsProviderScoped() {
    let model = SessionTabsModel()
    let pendingID = UUID()
    let pendingTab = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    model.open(pendingTab)
    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .codex)
    #expect(model.openTabIDs == [pendingTab])
  }

  // MARK: - Persistence

  @Test("Persisted ids are per provider, in order, without pending tabs")
  func persistedIDsFilter() {
    let model = SessionTabsModel()
    let pendingTab = SidebarSessionItemID.pending(provider: .claude, pendingId: UUID())
    ["claude-b", "codex-x", pendingTab, "claude-a"].forEach(model.open)
    #expect(model.persistedIDs(for: .claude) == ["claude-b", "claude-a"])
    #expect(model.persistedIDs(for: .codex) == ["codex-x"])
  }

  @Test("Restore merges once per provider after tabs opened before the read")
  func restoreMergesOnce() {
    let model = SessionTabsModel()
    model.open("claude-new")
    model.restore(["claude-a", "claude-new", "pending-claude-x"], provider: .claude)
    #expect(model.openTabIDs == ["claude-new", "claude-a"])
    #expect(model.hasRestored(.claude))

    model.restore(["claude-z"], provider: .claude)
    #expect(model.openTabIDs == ["claude-new", "claude-a"])
  }

  @Test("Every change reports the full tab list for saving")
  func changesAreReported() {
    let model = SessionTabsModel()
    var reported: [[String]] = []
    model.onTabsChanged = { reported.append($0) }
    model.open("claude-a")
    model.open("claude-a")
    model.open("codex-b")
    model.close("claude-a")
    #expect(reported == [["claude-a"], ["claude-a", "codex-b"], ["codex-b"]])
  }

  @Test("Persistence round-trip through the workspace state")
  func persistenceRoundTrip() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "tabs_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: path)
    let model = SessionTabsModel()
    ["claude-a", "codex-b", "claude-c"].forEach(model.open)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(openSessionTabIds: model.persistedIDs(for: .claude)), for: .claude)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(openSessionTabIds: model.persistedIDs(for: .codex)), for: .codex)

    let restored = SessionTabsModel()
    restored.restore(try store.readWorkspaceState(for: .claude).openSessionTabIds, provider: .claude)
    restored.restore(try store.readWorkspaceState(for: .codex).openSessionTabIds, provider: .codex)
    #expect(restored.openTabIDs == ["claude-a", "claude-c", "codex-b"])
  }

  // MARK: - Pruning

  @Test("Prune closes tabs whose session went away, not ones never seen")
  func pruneOnlySeenTabs() {
    let model = SessionTabsModel()
    model.restore(["claude-restoring"], provider: .claude)
    ["claude-a", "claude-b"].forEach(model.open)
    model.prune(availableIDs: ["claude-a", "claude-b"])
    model.prune(availableIDs: ["claude-a"])
    #expect(model.openTabIDs == ["claude-restoring", "claude-a"])
    #expect(model.selectedTabID == "claude-a")
  }

  @Test("Only tabs that resolve to a session are visible")
  func visibleTabs() {
    let model = SessionTabsModel()
    model.restore(["claude-x", "claude-a"], provider: .claude)
    #expect(model.visibleTabIDs(availableIDs: ["claude-a"]) == ["claude-a"])
  }

  // MARK: - Overflow

  @Test("Overflow keeps strip order and moves the rest into the menu")
  func overflowOrder() {
    let layout = SessionTabsModel.layout(
      tabIDs: ["a", "b", "c", "d", "e"], selectedID: "a", capacity: 3)
    #expect(layout.visible == ["a", "b", "c"])
    #expect(layout.overflow == ["d", "e"])
  }

  @Test("A selected overflowing tab swaps into the last visible slot")
  func overflowKeepsSelectionVisible() {
    let layout = SessionTabsModel.layout(
      tabIDs: ["a", "b", "c", "d", "e"], selectedID: "e", capacity: 3)
    #expect(layout.visible == ["a", "b", "e"])
    #expect(layout.overflow == ["c", "d"])
  }

  @Test("No overflow when everything fits")
  func noOverflow() {
    let layout = SessionTabsModel.layout(tabIDs: ["a", "b"], selectedID: nil, capacity: 4)
    #expect(layout.visible == ["a", "b"])
    #expect(layout.overflow.isEmpty)
  }

  @Test("Capacity counts tabs at their 120 pt minimum")
  func capacityAtMinimumWidth() {
    #expect(SessionTabsModel.capacity(forWidth: 0, minimumTabWidth: 120, spacing: 4) == 1)
    #expect(SessionTabsModel.capacity(forWidth: 244, minimumTabWidth: 120, spacing: 4) == 2)
    #expect(SessionTabsModel.capacity(forWidth: 243, minimumTabWidth: 120, spacing: 4) == 1)
  }

  // MARK: - Commit and Claude theme hint

  @Test("Commit title and prompt name the file count")
  func commitWording() {
    #expect(CommitChangesAction.title(fileCount: 1) == "Commit 1 file…")
    #expect(CommitChangesAction.title(fileCount: 3) == "Commit 3 files…")
    #expect(CommitChangesAction.prompt(fileCount: 3).contains("the 3 changed files"))
    #expect(CommitChangesAction.prompt(fileCount: 3).contains("Do not push"))
  }

  @Test("Claude theme hint: only a dark Claude theme on the new shell's light terminal")
  func claudeThemeHint() {
    func show(_ theme: String?, _ provider: SessionProviderKind = .claude, dark: Bool = false, flag: Bool = true) -> Bool {
      ClaudeTUIThemeHint.shouldShow(
        claudeTheme: theme, providerKind: provider, isDarkTerminal: dark, followsWorkbenchPalette: flag)
    }
    #expect(show("dark"))
    #expect(show("dark-daltonized"))
    #expect(!show("light"))
    #expect(!show(nil))
    #expect(!show("dark", .codex))
    #expect(!show("dark", dark: true))
    #expect(!show("dark", flag: false))
  }

  @Test("Claude theme is read from the config JSON")
  func claudeThemeParsing() {
    #expect(ClaudeTUIThemeReader.theme(fromConfigData: Data(#"{"theme":"dark","x":1}"#.utf8)) == "dark")
    #expect(ClaudeTUIThemeReader.theme(fromConfigData: Data(#"{"x":1}"#.utf8)) == nil)
    #expect(ClaudeTUIThemeReader.theme(fromConfigData: Data("not json".utf8)) == nil)
  }
}
