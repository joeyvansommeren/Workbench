import SwiftUI

/// Setup stays beside the form. Workbench never runs an installer.
struct AgentSetupRecoveryView: View {
  let provider: SessionProviderKind
  let onCheckAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
      Text("Set up \(provider.agentDisplayName)").wbText(.title3)
      Text("Install the agent, then check again. Your session choices stay here.")
        .wbText(.body)
        .foregroundStyle(Color.wbTextSecondary)
      Link("Open installation guide", destination: provider.installationGuideURL)
      Button("Check again", action: onCheckAgain)
        .buttonStyle(WBSecondaryButtonStyle())
        .accessibilityIdentifier("newSession.checkAgent")
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 340)
  }
}

extension SessionProviderKind {
  var installationGuideURL: URL {
    switch self {
    case .claude: return URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!
    case .codex: return URL(string: "https://github.com/openai/codex")!
    }
  }
}
