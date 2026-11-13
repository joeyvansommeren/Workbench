//
//  ShellSidebarContainer.swift
//  AgentHub
//
//  SIDEBAR SLOT of the new shell. Fixed width (`DesignTokens.Width.sidebar`),
//  `surfaceSidebar` background, content starts below the 52 pt title bar
//  where the traffic lights and the sidebar toggle sit.
//
//  Contents (P5, `Shell/Sidebar/`): the Reviews and Sprint nav rows, the
//  repo > branch > session tree, and the Open project footer.
//

import SwiftUI

struct ShellSidebarContainer: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var coordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarNavSection()
        .padding(.horizontal, DesignTokens.Inset.sidebar)
      SessionTreeView()
        .padding(.top, DesignTokens.Spacing.lg)
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

/// One 30 pt sidebar row: lead icon, title, trailing count. Selected rows sit
/// on `surfaceRaised` with the raised elevation, like `.nav-row` in the
/// prototype.
struct ShellSidebarRow<Lead: View>: View {
  let title: String
  let titleStyle: WorkbenchTextStyle
  let count: Int?
  let isSelected: Bool
  let action: () -> Void
  @ViewBuilder let lead: Lead

  @State private var isHovered = false

  init(
    title: String,
    titleStyle: WorkbenchTextStyle = .body,
    count: Int? = nil,
    isSelected: Bool,
    action: @escaping () -> Void,
    @ViewBuilder lead: () -> Lead
  ) {
    self.title = title
    self.titleStyle = titleStyle
    self.count = count
    self.isSelected = isSelected
    self.action = action
    self.lead = lead()
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignTokens.Spacing.smPlus) {
        lead
          .frame(width: DesignTokens.Size.tile)
        Text(title)
          .wbText(titleStyle)
          .foregroundStyle(Color.wbTextPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        if let count, count > 0 {
          Text("\(count)")
            .wbText(.callout)
            .monospacedDigit()
            .foregroundStyle(Color.wbTextSecondary)
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.smPlus)
      .frame(height: DesignTokens.Size.row)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(background)
    .onHover { isHovered = $0 }
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.row, style: .continuous)
    if isSelected {
      shape.fill(Color.wbSurfaceRaised).wbElevation(.raised)
    } else if isHovered {
      shape.fill(Color.wbSurfaceHover)
    }
  }
}
