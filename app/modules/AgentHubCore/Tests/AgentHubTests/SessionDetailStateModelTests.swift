import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("SessionDetailStateModel")
struct SessionDetailStateModelTests {

  // MARK: - Per-session state

  @Test("Content mode and side-panel segment are kept per session")
  func perSessionState() {
    let model = SessionDetailStateModel()
    model.setContentMode(.chat, for: "claude-a", defaultProjectPath: "/p")
    model.setSidePanelSegment(.plan, for: "claude-a")
    #expect(model.contentMode(for: "claude-a") == .chat)
    #expect(model.sidePanelSegment(for: "claude-a") == .plan)
    #expect(model.contentMode(for: "claude-b") == .terminal)
    #expect(model.sidePanelSegment(for: "claude-b") == .diff)
  }

  @Test("Opening a file routes the session to Files with a navigation request")
  func openFileSwitchesToFiles() {
    let model = SessionDetailStateModel()
    model.openFile("/p/a.swift", lineNumber: 4, projectPath: "/p", for: "claude-a")
    let state = model.editorState(for: "claude-a", defaultProjectPath: "/other")
    #expect(state.contentMode == .editor)
    #expect(state.selectedFilePath == "/p/a.swift")
    #expect(state.navigationRequest?.lineNumber == 4)
  }

  @Test("Ordinary entry starts on Terminal for both providers and pending launches")
  func ordinaryEntryStartsOnTerminal() {
    let model = SessionDetailStateModel()
    let pending = SidebarSessionItemID.pending(provider: .claude, pendingId: UUID())
    for id in ["claude-a", "codex-a", pending] {
      #expect(!model.showsResult(for: id))
      #expect(model.contentMode(for: id) == .terminal)
    }
  }

  @Test("Leaving a session resets its view without changing the destination")
  func leavingSessionResetsItsView() {
    let model = SessionDetailStateModel()
    model.setContentMode(.diffs, for: "claude-a", defaultProjectPath: "/p")
    model.setShowsResult(true, for: "claude-a")
    model.openFile("/p/b.swift", lineNumber: 2, projectPath: "/p", for: "codex-b")
    model.leaveSession("claude-a")
    #expect(!model.showsResult(for: "claude-a"))
    #expect(model.contentMode(for: "claude-a") == .terminal)
    #expect(model.contentMode(for: "codex-b") == .editor)
  }

  @Test("A file request dismisses Result")
  func fileRequestDismissesResult() {
    let model = SessionDetailStateModel()
    model.setShowsResult(true, for: "claude-a")
    model.openFile("/p/a.swift", lineNumber: 1, projectPath: "/p", for: "claude-a")
    #expect(!model.showsResult(for: "claude-a"))
    #expect(model.contentMode(for: "claude-a") == .editor)
  }

  @Test("An explicit content request dismisses Result even when its mode is unchanged")
  func explicitContentRequestDismissesResult() {
    for mode in [MonitoringCardContentMode.terminal, .editor, .diffs] {
      let model = SessionDetailStateModel()
      model.setContentMode(mode, for: "claude-a", defaultProjectPath: "/p")
      model.setShowsResult(true, for: "claude-a")
      model.setContentMode(mode, for: "claude-a", defaultProjectPath: "/p")
      #expect(!model.showsResult(for: "claude-a"))
      #expect(model.contentMode(for: "claude-a") == mode)
    }
  }

  @Test("Pending resolution preserves the view in use")
  func pendingResolutionPreservesView() {
    for provider in [SessionProviderKind.claude, .codex] {
      let model = SessionDetailStateModel()
      let pendingID = UUID()
      let pending = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      let resolved = SidebarSessionItemID.monitored(provider: provider, sessionId: "real")
      model.setContentMode(.diffs, for: pending, defaultProjectPath: "/p")
      model.leaveSession(
        pending, transitioningTo: resolved, resolvedHistories: [(provider, [pendingID: "real"])])
      model.migrateResolvedPendingSessions([pendingID: "real"], provider: provider)
      #expect(model.contentMode(for: resolved) == .diffs)
      #expect(!model.showsResult(for: resolved))
    }
  }

  @Test("Pending resolution without editor state stays on Terminal")
  func pendingResolutionWithoutEditorState() {
    for provider in [SessionProviderKind.claude, .codex] {
      let model = SessionDetailStateModel()
      let pendingID = UUID()
      let pending = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      let resolved = SidebarSessionItemID.monitored(provider: provider, sessionId: "real")
      model.show(pending)
      model.migrateResolvedPendingSessions([pendingID: "real"], provider: provider)
      model.show(resolved)
      #expect(!model.showsResult(for: resolved))
      #expect(model.contentMode(for: resolved) == .terminal)
      #expect(model.editorStates.isEmpty)
    }
  }

  @Test("Pending resolution keeps an explicitly opened Result in either notification order")
  func pendingResolutionKeepsExplicitResult() {
    for provider in [SessionProviderKind.claude, .codex] {
      for migrateFirst in [false, true] {
        let model = SessionDetailStateModel()
        let pendingID = UUID()
        let pending = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
        let resolved = SidebarSessionItemID.monitored(provider: provider, sessionId: "real")
        let history = [pendingID: "real"]
        model.setShowsResult(true, for: pending)
        if migrateFirst { model.migrateResolvedPendingSessions(history, provider: provider) }
        model.leaveSession(pending, transitioningTo: resolved, resolvedHistories: [(provider, history)])
        if !migrateFirst { model.migrateResolvedPendingSessions(history, provider: provider) }
        #expect(model.showsResult(for: resolved))
      }
    }
  }

  @Test("Leaving a pending session resets its view regardless of resolution order")
  func leavingPendingSessionResetsView() {
    for migrateFirst in [false, true] {
      let model = SessionDetailStateModel()
      let pendingID = UUID()
      let pending = SidebarSessionItemID.pending(provider: .codex, pendingId: pendingID)
      let history: [UUID: String] = [pendingID: "real"]
      model.setContentMode(.diffs, for: pending, defaultProjectPath: "/p")
      if migrateFirst { model.migrateResolvedPendingSessions(history, provider: .codex) }
      model.leaveSession(
        pending, transitioningTo: "claude-other", resolvedHistories: [(.codex, history)])
      if !migrateFirst { model.migrateResolvedPendingSessions(history, provider: .codex) }
      #expect(model.contentMode(for: "codex-real") == .terminal)
    }
  }

  @Test("Restored sessions start on Terminal and Result stays open until leaving")
  func restoredSessionAndExplicitResult() {
    let model = SessionDetailStateModel()
    model.restore(["codex-a"], provider: .codex)
    #expect(!model.showsResult(for: "codex-a"))
    model.setShowsResult(true, for: "codex-a")
    model.show("codex-a")
    model.show("codex-a")
    #expect(model.showsResult(for: "codex-a"))
    model.leaveSession("codex-a")
    #expect(!model.showsResult(for: "codex-a"))
  }

  @Test("Toggling Result on and off is symmetric")
  func toggleResult() {
    let model = SessionDetailStateModel()
    #expect(!model.showsResult(for: "claude-a"))
    model.setShowsResult(true, for: "claude-a")
    #expect(model.showsResult(for: "claude-a"))
    model.setShowsResult(false, for: "claude-a")
    #expect(!model.showsResult(for: "claude-a"))
  }

  @Test("An approval request dismisses Result and routes to Terminal")
  func approvalDismissesResult() {
    let model = SessionDetailStateModel()
    model.setShowsResult(true, for: "claude-a")
    let routed = model.routePendingRequest(
      for: "claude-a", projectPath: "/p",
      status: .awaitingApproval(tool: "Edit"), hasPermissionRequest: false)
    #expect(routed)
    #expect(!model.showsResult(for: "claude-a"))
    #expect(model.contentMode(for: "claude-a") == .terminal)
  }

  @Test("revealTerminal dismisses Result and sets Terminal mode")
  func revealTerminalDismissesResult() {
    let model = SessionDetailStateModel()
    model.setShowsResult(true, for: "claude-a")
    model.setContentMode(.diffs, for: "claude-a", defaultProjectPath: "/p")
    model.setShowsResult(true, for: "claude-a")
    model.revealTerminal(for: GlobalSessionSelectionRequest(
      providerKind: .claude, sessionId: "a", projectPath: "/p"))
    #expect(!model.showsResult(for: "claude-a"))
    #expect(model.contentMode(for: "claude-a") == .terminal)
  }

  // MARK: - Pending → resolved

  @Test("A resolved launch keeps the pending session's state")
  func pendingStateMigrates() {
    let model = SessionDetailStateModel()
    let pendingID = UUID()
    let pendingKey = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    model.setContentMode(.chat, for: pendingKey, defaultProjectPath: "/p")
    model.setSidePanelSegment(.plan, for: pendingKey)

    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .claude)

    #expect(model.contentMode(for: "claude-real") == .chat)
    #expect(model.sidePanelSegment(for: "claude-real") == .plan)
    #expect(model.editorStates[pendingKey] == nil)
  }

  @Test("Resolutions of the other provider are ignored")
  func migrationIsProviderScoped() {
    let model = SessionDetailStateModel()
    let pendingID = UUID()
    let pendingKey = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    model.setContentMode(.chat, for: pendingKey, defaultProjectPath: "/p")
    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .codex)
    #expect(model.contentMode(for: pendingKey) == .chat)
    #expect(model.contentMode(for: "codex-real") == .terminal)
  }

  // MARK: - Selection upkeep

  @Test("Nothing shown: the first loaded session shown at the last run is shown")
  func upkeepPrefersRestored() {
    let model = SessionDetailStateModel()
    model.restore(["claude-gone", "claude-b", "claude-a"], provider: .claude)
    let decision = model.selectionUpkeep(
      primarySessionId: nil, availableIDs: ["claude-a", "claude-b", "codex-x"])
    #expect(decision == .select("claude-b"))
  }

  @Test("Nothing shown and nothing restored: pick the newest session")
  func upkeepFallsBackToNewest() {
    let model = SessionDetailStateModel()
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: ["claude-a"]) == .selectFirstAvailable)
  }

  @Test("No upkeep while the shown session is loaded, or while nothing is loaded")
  func upkeepDoesNothing() {
    let model = SessionDetailStateModel()
    #expect(model.selectionUpkeep(primarySessionId: "claude-a", availableIDs: ["claude-a"]) == .none)
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: []) == .none)
  }

  @Test("The shown session went away: pick another")
  func upkeepReplacesGoneSession() {
    let model = SessionDetailStateModel()
    _ = model.selectionUpkeep(primarySessionId: "claude-a", availableIDs: ["claude-a", "claude-b"])
    #expect(model.selectionUpkeep(primarySessionId: "claude-a", availableIDs: ["claude-b"]) == .selectFirstAvailable)
  }

  @Test("A shown session that has not loaded yet is kept")
  func upkeepKeepsLoadingSession() {
    let model = SessionDetailStateModel()
    #expect(model.selectionUpkeep(primarySessionId: "claude-new", availableIDs: ["claude-b"]) == .none)
  }

  @Test("A shown launch that resolved before the navigation model caught up shows its real session")
  func upkeepFollowsResolvedLaunch() {
    let model = SessionDetailStateModel()
    let pendingID = UUID()
    let pendingKey = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    _ = model.selectionUpkeep(primarySessionId: pendingKey, availableIDs: ["claude-a", pendingKey])

    // The pending row went away and the real one appeared; primary is still pending.
    let histories: [(SessionProviderKind, [UUID: String])] = [(.claude, [pendingID: "real"]), (.codex, [:])]
    #expect(
      model.selectionUpkeep(
        primarySessionId: pendingKey, availableIDs: ["claude-a", "claude-real"], resolvedHistories: histories)
        == .select("claude-real"))
    // Resolved but the real session has not loaded yet: keep waiting.
    #expect(
      model.selectionUpkeep(primarySessionId: pendingKey, availableIDs: ["claude-a"], resolvedHistories: histories)
        == .none)
    // The other provider's history never matches.
    #expect(
      model.selectionUpkeep(
        primarySessionId: pendingKey, availableIDs: ["claude-a"],
        resolvedHistories: [(.codex, [pendingID: "real"])])
        == .selectFirstAvailable)
  }

  @Test("Once a session was shown, the launch-time restored session is no longer preferred")
  func restoredClearedAfterShow() {
    let model = SessionDetailStateModel()
    model.restore(["claude-b"], provider: .claude)
    model.show("claude-a")
    #expect(model.restoredIDs.isEmpty)
    #expect(model.selectionUpkeep(primarySessionId: nil, availableIDs: ["claude-a", "claude-b"]) == .selectFirstAvailable)

    // A provider whose saved state is read later adds nothing either.
    model.restore(["codex-x"], provider: .codex)
    #expect(model.restoredIDs.isEmpty)
  }

  @Test("Per-session state of gone sessions is pruned; launching sessions keep theirs")
  func pruneGoneSessionState() {
    let model = SessionDetailStateModel()
    let pendingKey = SidebarSessionItemID.pending(provider: .claude, pendingId: UUID())
    model.setContentMode(.chat, for: "claude-a", defaultProjectPath: "/p")
    model.setContentMode(.chat, for: "claude-gone", defaultProjectPath: "/p")
    model.setContentMode(.chat, for: pendingKey, defaultProjectPath: "/p")
    model.setSidePanelSegment(.plan, for: "claude-gone")

    model.prune(availableIDs: ["claude-a"])

    #expect(model.contentMode(for: "claude-a") == .chat)
    #expect(model.contentMode(for: pendingKey) == .chat)
    #expect(model.editorStates["claude-gone"] == nil)
    #expect(model.sidePanelSegments["claude-gone"] == nil)
  }

  // MARK: - Persistence

  @Test("Each new shown session is reported once; pending launches are not")
  func showReports() {
    let model = SessionDetailStateModel()
    var reported: [String] = []
    model.onShownChanged = { reported.append($0) }
    model.show("claude-a")
    model.show("claude-a")
    model.show(SidebarSessionItemID.pending(provider: .claude, pendingId: UUID()))
    model.show(nil)
    model.show("codex-b")
    #expect(reported == ["claude-a", "codex-b"])
  }

  @Test("Restore runs once per provider, without pending launches")
  func restoreOncePerProvider() {
    let model = SessionDetailStateModel()
    model.restore(["claude-a", "pending-claude-x"], provider: .claude)
    model.restore(["claude-z"], provider: .claude)
    #expect(model.restoredIDs == ["claude-a"])
    #expect(model.hasRestored(.claude))
    #expect(!model.hasRestored(.codex))
  }

  @Test("A session shown before the read is reported again after it")
  func restoreReportsShownSession() {
    let model = SessionDetailStateModel()
    var reported: [String] = []
    model.onShownChanged = { reported.append($0) }
    model.show("claude-early")
    reported.removeAll()
    model.restore(["claude-a"], provider: .claude)
    #expect(reported == ["claude-early"])
  }

  @Test("Saved ids are per provider")
  func persistedIDsFilter() {
    #expect(SessionDetailStateModel.persistedIDs(in: ["claude-a"], for: .claude) == ["claude-a"])
    #expect(SessionDetailStateModel.persistedIDs(in: ["claude-a"], for: .codex).isEmpty)
  }

  @Test("The shown session survives a relaunch through the workspace state")
  func persistenceRoundTrip() async throws {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "shown_\(UUID().uuidString).sqlite").path
    let store = try SessionMetadataStore(path: path)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(openSessionTabIds: SessionDetailStateModel.persistedIDs(in: ["codex-b"], for: .claude)),
      for: .claude)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(openSessionTabIds: SessionDetailStateModel.persistedIDs(in: ["codex-b"], for: .codex)),
      for: .codex)

    let restored = SessionDetailStateModel()
    restored.restore(try store.readWorkspaceState(for: .claude).openSessionTabIds, provider: .claude)
    restored.restore(try store.readWorkspaceState(for: .codex).openSessionTabIds, provider: .codex)
    #expect(restored.selectionUpkeep(primarySessionId: nil, availableIDs: ["claude-a", "codex-b"]) == .select("codex-b"))
  }

  // MARK: - Commit and Claude theme hint

  @Test("Commit action opens review independently of displayed diff counts")
  func commitWording() {
    #expect(CommitChangesAction.title(fileCount: 0) == "Review commit…")
    #expect(CommitChangesAction.title(fileCount: 3) == "Review commit…")
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
