import SwiftUI

/// Read-only finish review. Opening it grants no publishing or cleanup permission.
struct FinishSummarySheet: View {
  let session: CLISession
  let provider: SessionProviderKind
  let acceptance: SessionResultDecisionSnapshot?
  let agentHub: AgentHubProvider
  @Environment(\.dismiss) private var dismiss
  @State private var model: FinishSummaryModel

  init(session: CLISession, provider: SessionProviderKind,
    acceptance: SessionResultDecisionSnapshot? = nil, agentHub: AgentHubProvider) {
    self.session = session
    self.provider = provider
    self.acceptance = acceptance
    self.agentHub = agentHub
    _model = State(initialValue: FinishSummaryModel(
      git: FinishGitInspectionService(), gitHub: agentHub.gitHubPRObservationService,
      resultStore: agentHub.metadataStore))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text("Finish summary").wbText(.title3)
      ScrollView {
        if let summary = model.summary {
          FinishSummaryView(summary: summary)
        } else {
          ProgressView("Checking what remains…").padding()
        }
      }
      HStack {
        Button("Refresh") { Task { await load() } }
          .disabled(model.isLoading)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(WBSecondaryButtonStyle())
      }
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(width: DesignTokens.Width.sheet, height: 600)
    .background(Color.wbSurfaceRaised)
    .task { await load() }
  }

  private func load() async {
    let claude = agentHub.claudeSessionsViewModel
    let codex = agentHub.codexSessionsViewModel
    let repositories = ShellSessionItems.repositories(claude: claude, codex: codex)
    let match = WorktreeModuleResolver.bestMatch(for: session.projectPath, repositories: repositories)
    let root = WorktreeModuleResolver.normalizedDirectoryPath(match?.worktree.path ?? session.projectPath)
    let runtime = FinishRuntimeInventory.capture(claude: claude, codex: codex)
    let resources = runtime.sessions
    var servers: [FinishServerResource] = []
    let scoped = resources.filter {
      let path = WorktreeModuleResolver.normalizedDirectoryPath($0.path)
      return path == root || path.hasPrefix(root + "/")
    }
    let keys = Set(scoped.flatMap(FinishServerInventory.keys(for:)) + [root])
    servers = FinishServerInventory.resources(DevServerManager.shared.finishServerInventory,
      root: root, knownKeys: keys)
    for (kind, vm) in [(SessionProviderKind.claude, claude), (.codex, codex)] {
      for item in vm.allSessions where scoped.contains(where: { $0.id == "\(kind.rawValue):\(item.id)" }) {
        if vm.monitorStates[item.id]?.detectedLocalhostURL != nil {
          servers.append(FinishServerResource(id: "agent:\(kind.rawValue):\(item.id)",
            description: "Agent-reported server; current status unknown", blocksCleanup: true))
        }
      }
    }
    await model.load(session: session, provider: provider, repositories: repositories,
      sessions: resources, servers: servers, acceptance: acceptance, runtime: runtime,
      refreshRuntime: { FinishRuntimeInventory.capture(claude: claude, codex: codex) })
  }
}

struct FinishSummaryView: View {
  let summary: FinishSummary

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      section("Output", text: summary.acceptance)
      section("GitHub checks", text: summary.checks)
      section("Local checks", text: "Local test results are not recorded here.")
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        section("Publishing", text: summary.publishing)
        if let url = summary.pullRequestURL { Link("Open pull request", destination: url) }
      }
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text("Remaining resources").wbText(.headline)
        Text("\(summary.sessions.count) sessions · \(summary.servers.count) servers · 1 working folder")
          .wbText(.body)
        Text(summary.projectPath).wbText(.code).textSelection(.enabled)
        ForEach(summary.sessions) { session in
          Text(session.name).wbText(.body)
        }
        ForEach(summary.servers) { server in Text(server.description).wbText(.body) }
      }
      Divider()
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        Text("Cleanup proposal").wbText(.headline)
        Text(summary.cleanup.isCandidate ? "This worktree can be reviewed for cleanup." : "Keep this worktree.")
          .wbText(.body)
        ForEach(summary.cleanup.reasons, id: \.self) { reason in
          Text(reason).wbText(.callout).foregroundStyle(Color.wbTextSecondary)
        }
        Text("Nothing is stopped or deleted. Cleanup needs a separate decision.")
          .wbText(.callout).foregroundStyle(Color.wbTextSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textSelection(.enabled)
  }

  private func section(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(title).wbText(.headline)
      Text(text).wbText(.body)
    }
    .accessibilityElement(children: .combine)
  }
}
