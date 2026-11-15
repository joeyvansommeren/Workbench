//
//  ShellSidebarContainer.swift
//  AgentHub
//
//  SIDEBAR SLOT of the new shell. Fixed width (`DesignTokens.Width.sidebar`),
//  `surfaceSidebar` background, content starts at the content panel's top
//  (`ShellLayout.contentTop`), below the title band where the traffic lights
//  and the sidebar toggle sit.
//
//  Contents (P5, `Shell/Sidebar/`): the repo > branch > session tree and
//  the Open project footer. Reviews, Jira and Linear are tabs in the title
//  row since P12.
//

import SwiftUI

struct ShellSidebarContainer: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var coordinator
  @Environment(WorkbenchShellModel.self) private var shellModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Includes the Open project footer, hidden on the first-run empty state.
      SidebarTreeOrEmptyState(openProject: openProject)
        .frame(maxHeight: .infinity, alignment: .top)
    }
    .padding(.top, ShellLayout.contentTop(titleBar: shellModel.titleBar))
    .padding(.bottom, DesignTokens.Inset.sidebar)
    .frame(width: DesignTokens.Width.sidebar, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.wbSurfaceSidebar.ignoresSafeArea())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")
  }

  private func openProject() {
    guard let agentHub, let coordinator, let navigationModel else { return }
    ShellSessionActions(agentHub: agentHub, coordinator: coordinator, navigationModel: navigationModel)
      .addRepository()
  }
}
