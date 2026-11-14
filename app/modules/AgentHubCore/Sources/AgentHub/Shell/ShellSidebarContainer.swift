//
//  ShellSidebarContainer.swift
//  AgentHub
//
//  SIDEBAR SLOT of the new shell. Fixed width (`DesignTokens.Width.sidebar`),
//  `surfaceSidebar` background, content starts below the 52 pt title bar
//  where the traffic lights and the sidebar toggle sit.
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SessionTreeView()
        .frame(maxHeight: .infinity, alignment: .top)
      SidebarFooter(openProject: openProject)
    }
    .padding(.top, DesignTokens.Size.titlebar)
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
