import Foundation
import Testing
@testable import AgentHubCore

struct SessionResultTests {
  @Test func decisionIsBoundToRecordedContent() {
    var result = SessionResult(provider: .claude, sessionID: "same", projectPath: "/tmp/work")
    result.sourceIdentity = "before"
    result.decision = .accepted
    result.decidedAt = Date()
    #expect(result.freshness(comparedTo: nil) == .unknown)
    #expect(result.freshness(comparedTo: "after") == .stale)
    #expect(result.acceptance(comparedTo: "before").decision == .accepted)
    let revision = result.revision
    result.revise(sourceIdentity: "after")
    #expect(result.revision != revision)
    #expect(result.decision == .none)
    #expect(result.decidedAt == nil)
  }

  @Test func identitiesIncludeProvider() {
    #expect(SessionResult.key(provider: .claude, sessionID: "same")
      != SessionResult.key(provider: .codex, sessionID: "same"))
  }

  @Test func unknownSourceNeverBecomesCurrent() {
    let result = SessionResult(provider: .claude, sessionID: "s", projectPath: "/tmp/work")
    #expect(result.freshness(comparedTo: "some-head") == .unknown)
    #expect(result.freshness(comparedTo: nil) == .unknown)
  }
}

struct ProjectLaunchRecipeTests {
  @Test func worktreeRecipeUsesItsActualRoot() throws {
    let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", workingSubdirectory: "app")
    #expect(try recipe.workingPath(in: "/tmp/worktree") == "/private/tmp/worktree/app"
      || recipe.workingPath(in: "/tmp/worktree") == "/tmp/worktree/app")
  }

  @Test func traversalAndAbsoluteSubdirectoryAreRejected() {
    for path in ["../other", "/tmp/main"] {
      let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", workingSubdirectory: path)
      #expect(throws: ResultLaunchError.self) { try recipe.workingPath(in: "/tmp/worktree") }
    }
  }

  @Test func exactRouteQueryAndFragmentArePreserved() throws {
    let value = "http://localhost:5173/settings?mode=edit#dialog"
    #expect(try ProjectLaunchRecipe.destinationURL(value, projectPath: "/tmp/work").absoluteString == value)
  }

  @Test func unsafeSchemesCredentialsAndEscapedFilesAreRejected() {
    for value in ["javascript:alert(1)", "https://user:secret@example.com/", "../private.txt", "file:///etc/passwd"] {
      #expect(throws: ResultLaunchError.self) {
        try ProjectLaunchRecipe.destinationURL(value, projectPath: "/tmp/work")
      }
    }
  }
}


struct SessionResultDraftTests {
  @Test func observedReportAndExactAgentRouteAreReusedWithoutAcceptance() {
    let state = SessionMonitorState(lastAssistantMessage: "Changed the label.",
      detectedLocalhostURL: URL(string: "http://localhost:3000/profile?tab=details"))
    let recipe = ProjectLaunchRecipe(repositoryPath: "/tmp/main", destination: "http://localhost:3000/")
    let draft = SessionResultDraft.make(provider: .claude, sessionID: "a", projectPath: "/tmp/work",
      state: state, recipe: recipe)
    #expect(draft.summary == "Changed the label.")
    #expect(draft.destination == "http://localhost:3000/profile?tab=details")
    #expect(draft.decision == .none)
    #expect(draft.sourceIdentity == nil)
  }

  @Test func absenceDoesNotInventAReportOrResult() {
    let draft = SessionResultDraft.make(provider: .codex, sessionID: "a", projectPath: "/tmp/work", state: nil, recipe: nil)
    #expect(draft.summary.isEmpty)
    #expect(draft.destination.isEmpty)
    #expect(draft.affectedTargets.isEmpty)
  }
}

@MainActor
struct SessionResultStateTests {
  @Test func requestRoutingShowsExactSessionsControlsWithoutChangingAnotherSession() {
    let model = SessionDetailStateModel()
    model.setShowsResult(true, for: "claude-a")
    model.setShowsResult(true, for: "codex-b")
    #expect(model.routePendingRequest(for: "codex-b", projectPath: "/tmp/b",
      status: .awaitingApproval(tool: "AskUserQuestion"), hasPermissionRequest: false))
    #expect(model.contentMode(for: "codex-b") == .terminal)
    #expect(!model.showsResult(for: "codex-b"))
    #expect(model.showsResult(for: "claude-a"))
    #expect(!model.routePendingRequest(for: "claude-a", projectPath: "/tmp/a",
      status: .waitingForUser, hasPermissionRequest: false))
    #expect(model.showsResult(for: "claude-a"))
  }

  @Test func terminalChoiceSurvivesPendingSessionResolution() {
    let model = SessionDetailStateModel()
    let pendingID = UUID()
    let pending = SidebarSessionItemID.pending(provider: .claude, pendingId: pendingID)
    model.setShowsResult(false, for: pending)
    model.migrateResolvedPendingSessions([pendingID: "real"], provider: .claude)
    #expect(!model.showsResult(for: SidebarSessionItemID.monitored(provider: .claude, sessionId: "real")))
    #expect(model.showsResult(for: "codex-unvisited"))
  }
}
