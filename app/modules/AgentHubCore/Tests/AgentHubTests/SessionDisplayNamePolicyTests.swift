import AgentHubCLIKit
import Foundation
import Observation
import Testing
@testable import AgentHubCore

// MARK: - TES-317: Surfaces that bypass the central displayName policy

/// The title policy is: manual rename > origin (ticket/PR) title > provider slug > untitled fallback.
/// `CLISessionsViewModel.displayName(for:)` implements it. These tests verify that:
///   1. The voice session list (`listSessions`) uses the policy, not just `sessionCustomNames`.
///   2. The voice session status (`sessionStatus`) uses the policy.
///   3. A manual rename still wins over an origin title on both surfaces.
///
/// This suite verifies the voice adapter with a test manager. Persisted launch titles and
/// manual rename precedence are covered by SessionLaunchOriginTests. Archive UI is separate.

@MainActor
@Observable
private final class StubVoiceSessionManager: VoiceSessionManaging {
  let providerKind: SessionProviderKind
  var voiceSessions: [CLISession] = []
  var selectedRepositories: [SelectedRepository] = []
  var sessionCustomNames: [String: String] = [:]
  var monitorStates: [String: SessionMonitorState] = [:]
  var sessionStatuses: [String: SessionStatus] = [:]
  var pendingHubSessions: [PendingHubSession] = []
  var resolvedPendingSessions: [UUID: String] = [:]
  var lastCreatedPendingId: UUID?

  /// The name the policy should return for a session. Mirrors
  /// `CLISessionsViewModel.displayName(for:)`: custom > origin > slug > untitled.
  var originDisplayNames: [String: String] = [:]

  init(providerKind: SessionProviderKind) {
    self.providerKind = providerKind
  }

  func displayName(for session: CLISession) -> String {
    sessionCustomNames[session.id]
      ?? originDisplayNames[session.id]
      ?? session.slug
      ?? "Untitled session \u{00B7} \(session.shortId)"
  }

  func sendPromptToActiveTerminal(forKey key: String, prompt: String) -> Bool { false }
  func showTerminalWithPrompt(for session: CLISession, prompt: String) {}
  func focusTerminal(forKey key: String) {}
  func respondToApproval(
    sessionId: String,
    decision: ApprovalDecision,
    terminalKey: String?
  ) -> ApprovalResponseOutcome { .sent }
  func voiceStartNewSessionInHub(_ worktree: WorktreeBranch, initialPrompt: String?) {}
}

private struct NoOpTranscriptReader: VoiceSessionTranscriptReading {
  func latestAssistantText(atPath: String, provider: SessionProviderKind) async -> String? { nil }
  func recentTurns(
    atPath: String, provider: SessionProviderKind, turnLimit: Int
  ) async -> [VoiceTranscriptTurn] { [] }
}

@MainActor
private final class FixedTargetResolver: VoiceSessionTargetResolving {
  var target: VoiceSessionTarget?
  func resolve(manualSessionId: String?) -> VoiceSessionTarget? { target }
  func candidates() -> [VoiceSessionTarget] { target.map { [$0] } ?? [] }
}

// MARK: - Tests

@Suite("TES-317 — session display name policy on all surfaces")
@MainActor
struct SessionDisplayNamePolicyTests {

  // MARK: Voice — listSessions

  @Test("listSessions returns the origin title when no custom name is set")
  func listSessionsUsesOriginTitle() {
    let (executor, claude) = makeExecutor()

    let session = CLISession(
      id: "ticket-session",
      projectPath: "/repo",
      lastActivityAt: Date(),
      isActive: true,
      slug: "some-slug"
    )
    claude.voiceSessions = [session]
    claude.originDisplayNames["ticket-session"] = "TES-100 Fix the title bug"

    let summary = executor.listSessions()
    let entry = summary.sessions.first { $0.id == "ticket-session" }

    #expect(entry != nil, "Session must appear in the summary")
    #expect(
      entry?.name == "TES-100 Fix the title bug",
      "Expected origin title, got \(entry?.name ?? "<nil>")"
    )
  }

  @Test("listSessions prefers a manual rename over an origin title")
  func listSessionsManualRenameWins() {
    let (executor, claude) = makeExecutor()

    let session = CLISession(
      id: "renamed-session",
      projectPath: "/repo",
      lastActivityAt: Date(),
      isActive: true,
      slug: "some-slug"
    )
    claude.voiceSessions = [session]
    claude.originDisplayNames["renamed-session"] = "TES-100 Fix the title bug"
    claude.sessionCustomNames["renamed-session"] = "My custom name"

    let summary = executor.listSessions()
    let entry = summary.sessions.first { $0.id == "renamed-session" }

    #expect(entry?.name == "My custom name")
  }

  // MARK: Voice — sessionStatus

  @Test("sessionStatus returns the origin title when no custom name is set")
  func sessionStatusUsesOriginTitle() {
    let (executor, claude) = makeExecutor()

    let session = CLISession(
      id: "status-session",
      projectPath: "/repo",
      lastActivityAt: Date(),
      isActive: true,
      slug: "another-slug"
    )
    claude.voiceSessions = [session]
    claude.originDisplayNames["status-session"] = "TES-200 Session status title"

    let detail = executor.sessionStatus(sessionId: "status-session")

    #expect(detail != nil, "Session status must be returned")
    #expect(
      detail?.name == "TES-200 Session status title",
      "Expected origin title, got \(detail?.name ?? "<nil>")"
    )
  }

  @Test("sessionStatus prefers a manual rename over an origin title")
  func sessionStatusManualRenameWins() {
    let (executor, claude) = makeExecutor()

    let session = CLISession(
      id: "status-renamed",
      projectPath: "/repo",
      lastActivityAt: Date(),
      isActive: true,
      slug: "another-slug"
    )
    claude.voiceSessions = [session]
    claude.originDisplayNames["status-renamed"] = "TES-200 Session status title"
    claude.sessionCustomNames["status-renamed"] = "Renamed status"

    let detail = executor.sessionStatus(sessionId: "status-renamed")

    #expect(detail?.name == "Renamed status")
  }

  // MARK: Helpers

  private func makeExecutor() -> (VoiceAgentToolExecutor, StubVoiceSessionManager) {
    let claude = StubVoiceSessionManager(providerKind: .claude)
    let codex = StubVoiceSessionManager(providerKind: .codex)
    let resolver = FixedTargetResolver()
    let executor = VoiceAgentToolExecutor(
      claudeViewModel: claude,
      codexViewModel: codex,
      selectionRouter: GlobalSessionSelectionRouter(),
      targetResolver: resolver,
      transcriptReader: NoOpTranscriptReader()
    )
    return (executor, claude)
  }
}
