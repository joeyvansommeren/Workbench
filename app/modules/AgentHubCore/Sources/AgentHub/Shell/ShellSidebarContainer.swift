//
//  ShellSidebarContainer.swift
//  AgentHub
//
//  SIDEBAR SLOT of the new shell. Fixed width (`DesignTokens.Width.sidebar`),
//  `surfaceSidebar` background, content starts below the 52 pt title bar
//  where the traffic lights and the sidebar toggle sit.
//
//  Contents: the Reviews and Sprint nav rows, then a placeholder flat session
//  list. P5 replaces `ShellPlaceholderSessionList` with the real tree.
//

import SwiftUI

struct ShellSidebarContainer: View {
  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      ShellSidebarNav()
      ShellPlaceholderSessionList()
    }
    .padding(.top, DesignTokens.Size.titlebar)
    .padding(.horizontal, DesignTokens.Inset.sidebar)
    .frame(width: DesignTokens.Width.sidebar, alignment: .topLeading)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.wbSurfaceSidebar.ignoresSafeArea())
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Sidebar")
  }
}

// MARK: - Nav rows

private struct ShellSidebarNav: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub

  var body: some View {
    VStack(spacing: 0) {
      ShellSidebarRow(
        systemImage: "arrow.triangle.pull",
        title: "Reviews",
        count: agentHub?.gitHubReviewsViewModel.pullRequests.count,
        isSelected: shellModel.destination == .reviews
      ) {
        shellModel.select(.reviews)
      }
      ShellSidebarRow(
        systemImage: "rectangle.split.3x1",
        title: "Sprint",
        count: sprintCount,
        isSelected: shellModel.destination == .sprint
      ) {
        shellModel.select(.sprint)
      }
    }
  }

  private var sprintCount: Int? {
    switch shellModel.sprintTracker {
    case .jira: return agentHub?.jiraSprintViewModel.myOpenTicketCount
    case .linear: return agentHub?.linearViewModel.myOpenIssueCount
    }
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

extension ShellSidebarRow where Lead == ShellSidebarIcon {
  init(
    systemImage: String,
    title: String,
    count: Int? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) {
    self.init(
      title: title,
      count: count,
      isSelected: isSelected,
      action: action,
      lead: { ShellSidebarIcon(systemImage: systemImage, isSelected: isSelected) }
    )
  }
}

struct ShellSidebarIcon: View {
  let systemImage: String
  let isSelected: Bool

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13))
      .foregroundStyle(isSelected ? Color.wbTextPrimary : Color.wbTextSecondary)
  }
}

// MARK: - Placeholder session list (P5 replaces this)

private struct ShellRepoHeader: View {
  let name: String
  let path: String

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.smPlus) {
      LetterTile(name: name, path: path)
      Text(name)
        .wbText(.headline)
        .foregroundStyle(Color.wbTextPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, DesignTokens.Spacing.smPlus)
    .frame(height: DesignTokens.Size.row)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A flat list of the window's open sessions, grouped under their repository.
/// Built from `SessionTreeProjection` so P5 can swap in the full tree.
private struct ShellPlaceholderSessionList: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(repoNodes) { repo in
          ShellRepoHeader(name: repo.name, path: repo.path)
            .padding(.top, repo.id == repoNodes.first?.id ? 0 : DesignTokens.Spacing.xl)
          ForEach(repo.branches.flatMap(\.sessions)) { node in
            sessionRow(node)
          }
        }
      }
    }
    .scrollIndicators(.never)
  }

  private func sessionRow(_ node: SessionNode) -> some View {
    let isSelected =
      shellModel.destination == .sessions && navigationModel?.primarySessionId == node.id
    return ShellSidebarRow(
      title: title(for: node),
      isSelected: isSelected,
      action: {
        navigationModel?.selectSession(node.id)
        shellModel.select(.sessions)
      },
      lead: {
        StatusGlyph(status: node.status, isPending: node.isPending)
          .fixedSize()
      }
    )
  }

  private func title(for node: SessionNode) -> String {
    guard let agentHub else { return node.session.displayName }
    let viewModel =
      node.providerKind == .claude
      ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel
    return viewModel.displayName(for: node.session)
  }

  private var repoNodes: [RepoNode] {
    guard let agentHub else { return [] }
    let claude = agentHub.claudeSessionsViewModel
    let codex = agentHub.codexSessionsViewModel
    return SessionTreeProjection.project(
      items: ShellSessionItems.items(claude: claude, codex: codex),
      repositories: ShellSessionItems.repositories(claude: claude, codex: codex)
    )
  }
}
