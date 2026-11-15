import SwiftUI

struct SessionAttentionSidebar: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var coordinator
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(SessionDetailStateModel.self) private var resultDetailState
  @State private var needsYou = false
  @State private var resultItem: AttentionResultTarget?

  var body: some View {
    VStack(spacing: 8) {
      Picker("Sessions filter", selection: $needsYou) {
        Text("All sessions").tag(false)
        Text("Needs you").tag(true)
      }.pickerStyle(.segmented).padding(.horizontal, 10)
      if needsYou, let agentHub {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            if agentHub.sessionAttentionModel.items.isEmpty {
              Text("No sessions need you").foregroundStyle(.secondary).padding()
            }
            ForEach(agentHub.sessionAttentionModel.items) { item in
              attentionRow(item, agentHub: agentHub)
            }
          }.padding(.horizontal, 10)
        }
      } else { SessionTreeView() }
    }
    .sheet(item: $resultItem) { target in
      if let agentHub {
        SessionResultView(session: target.session, provider: target.provider, agentHub: agentHub,
          filesActionLabel: "Reveal files",
          onTerminal: {
            resultDetailState.setShowsResult(false, for: target.id)
            resultDetailState.setContentMode(.terminal, for: target.id, defaultProjectPath: target.session.projectPath)
            resultItem = nil
            if let navigationModel, let coordinator,
              let item = agentHub.sessionAttentionModel.items.first(where: { $0.id == target.id }) {
              agentHub.sessionAttentionModel.open(item, agentHub: agentHub, navigationModel: navigationModel,
                shellModel: shellModel, coordinator: coordinator, detailState: resultDetailState)
            }
          },
          onFiles: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.session.projectPath) },
          onChecks: {
            resultItem = nil
            if let navigationModel, let coordinator {
              SidebarTreeActions(agentHub: agentHub, shellModel: shellModel,
                navigationModel: navigationModel, coordinator: coordinator).showGitHub(path: target.session.projectPath)
            }
          })
          .frame(minWidth: 700, minHeight: 550)
      }
    }
  }

  private func attentionRow(_ item: SessionAttentionItem, agentHub: AgentHubProvider) -> some View {
    HStack(alignment: .top) {
      Button {
        guard let navigationModel, let coordinator else { return }
        agentHub.sessionAttentionModel.open(item, agentHub: agentHub,
          navigationModel: navigationModel, shellModel: shellModel, coordinator: coordinator, detailState: resultDetailState)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).lineLimit(2)
          Text(item.reason).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }.buttonStyle(.plain).accessibilityLabel("\(item.title), \(item.reason)")
      if agentHub.sessionResultLibrary.records[item.id] != nil {
        Button("Result") {
          if let target = ShellSessionItems.items(claude: agentHub.claudeSessionsViewModel,
            codex: agentHub.codexSessionsViewModel).first(where: { $0.id == item.id }) {
            resultItem = AttentionResultTarget(id: target.id, session: target.session, provider: target.providerKind)
          }
        }.buttonStyle(.borderless)
      }
    }
  }
}

private struct AttentionResultTarget: Identifiable {
  let id: String
  let session: CLISession
  let provider: SessionProviderKind
}
