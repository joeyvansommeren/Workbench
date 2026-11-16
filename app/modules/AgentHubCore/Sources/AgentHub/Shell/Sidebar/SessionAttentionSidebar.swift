import SwiftUI

struct SessionAttentionSidebar: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var coordinator
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(SessionDetailStateModel.self) private var resultDetailState
  @State private var resultItem: AttentionResultTarget?

  var body: some View {
    @Bindable var shellModel = shellModel
    VStack(spacing: 8) {
      Picker("Sessions filter", selection: $shellModel.needsYouFilter) {
        Text("All sessions").tag(false)
        Text("Needs you (\(agentHub?.sessionAttentionModel.items.count ?? 0))").tag(true)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 10)
      if shellModel.needsYouFilter, let agentHub {
        SessionAttentionQueue(
          items: agentHub.sessionAttentionModel.items,
          selectedID: navigationModel?.primarySessionId ?? shellModel.attentionTargetID,
          resultIDs: Set(agentHub.sessionResultLibrary.records.keys),
          onOpen: { open($0, agentHub: agentHub) },
          onResult: { showResult($0, agentHub: agentHub) })
      } else {
        SessionTreeView()
      }
    }
    .sheet(item: $resultItem) { target in
      if let agentHub {
        SessionResultView(
          session: target.session, provider: target.provider, agentHub: agentHub,
          filesActionLabel: "Reveal files",
          onTerminal: {
            resultDetailState.setShowsResult(false, for: target.id)
            resultDetailState.setContentMode(
              .terminal, for: target.id, defaultProjectPath: target.session.projectPath)
            resultItem = nil
            if let navigationModel, let coordinator,
              let item = agentHub.sessionAttentionModel.items.first(where: { $0.id == target.id })
            {
              agentHub.sessionAttentionModel.open(
                item, agentHub: agentHub, navigationModel: navigationModel,
                shellModel: shellModel, coordinator: coordinator, detailState: resultDetailState,
                routeToReason: false)
            }
          },
          onFiles: {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.session.projectPath)
          },
          onChecks: {
            resultItem = nil
            if let navigationModel, let coordinator {
              SidebarTreeActions(
                agentHub: agentHub, shellModel: shellModel,
                navigationModel: navigationModel, coordinator: coordinator
              ).showGitHub(path: target.session.projectPath)
            }
          }
        )
        .frame(minWidth: 700, minHeight: 550)
      }
    }
  }

  private func open(_ item: SessionAttentionItem, agentHub: AgentHubProvider) {
    guard let navigationModel, let coordinator else { return }
    agentHub.sessionAttentionModel.open(
      item, agentHub: agentHub,
      navigationModel: navigationModel, shellModel: shellModel,
      coordinator: coordinator, detailState: resultDetailState)
  }

  private func showResult(_ item: SessionAttentionItem, agentHub: AgentHubProvider) {
    if let target = ShellSessionItems.items(
      claude: agentHub.claudeSessionsViewModel,
      codex: agentHub.codexSessionsViewModel
    ).first(where: { $0.id == item.id }) {
      resultItem = AttentionResultTarget(
        id: target.id, session: target.session, provider: target.providerKind)
    }
  }
}

/// Uses the model's retained order, never activity timestamps or geometry measurements.
struct SessionAttentionQueue: View {
  let items: [SessionAttentionItem]
  let selectedID: String?
  let resultIDs: Set<String>
  let onOpen: (SessionAttentionItem) -> Void
  let onResult: (SessionAttentionItem) -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Next session · ⌘J")
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
              Text("No sessions need you").foregroundStyle(.secondary).padding()
            }
            ForEach(items) { item in
              SessionAttentionQueueRow(
                item: item, isSelected: item.id == selectedID,
                hasResult: resultIDs.contains(item.id),
                onOpen: {
                  isFocused = true
                  onOpen(item)
                },
                onResult: { onResult(item) }
              )
              .id(item.id)
            }
          }.padding(.horizontal, 10)
        }
        .focusable().focused($isFocused).focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
          guard
            let item = SessionAttentionProjection.next(
              after: selectedID, in: items, forward: press.key == .downArrow)
          else { return .ignored }
          onOpen(item)
          return .handled
        }
        .onChange(of: selectedID, initial: true) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions that need you")
      }
    }
  }
}

struct SessionAttentionQueueRow: View {
  let item: SessionAttentionItem
  let isSelected: Bool
  let hasResult: Bool
  let onOpen: () -> Void
  let onResult: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title).lineLimit(2)
          Text(item.reason).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.accessibilityLabel)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      if hasResult {
        Button("Result", action: onResult)
          .buttonStyle(.borderless).padding(.top, 8).padding(.trailing, 8)
          .accessibilityLabel("Open result for \(item.title)")
      }
    }
    .background(
      isSelected ? Color.wbSurfaceSelected : isHovered ? Color.wbSurfaceHover : .clear,
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
    )
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
  }
}

private struct AttentionResultTarget: Identifiable {
  let id: String
  let session: CLISession
  let provider: SessionProviderKind
}
