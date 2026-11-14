//
//  SessionTreeView.swift
//  AgentHub
//
//  The sidebar's repo > branch > session tree (`SessionTree` in the
//  prototype). A `ScrollView` with one `LazyVStack` of flat rows, not `List`
//  or `OutlineGroup`: those are AppKit tables with their own selection look.
//
//  `SessionTreeView` reads the view models and projects the tree once per
//  change; `SessionTreeList` only draws rows, each an `Equatable` value, so a
//  status change re-renders one row, not the tree.
//

import SwiftUI

struct SessionTreeView: View {
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.agentHub) private var agentHub
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var coordinator

  /// Kept here, outside the projecting view, so recording it does not
  /// project the tree again.
  @State private var lastWorkspaceOpen: SidebarWorkspaceOpen?

  var body: some View {
    if let agentHub, let navigationModel, let coordinator {
      SessionTreeContent(
        agentHub: agentHub,
        actions: makeActions(agentHub: agentHub, navigationModel: navigationModel, coordinator: coordinator),
        lastWorkspaceOpen: $lastWorkspaceOpen
      )
      .background(WorkflowDiscoveryDriver(viewModel: agentHub.workflowDashboardViewModel))
    }
  }

  private func makeActions(
    agentHub: AgentHubProvider,
    navigationModel: SessionNavigationModel,
    coordinator: SessionsActionCoordinator
  ) -> SidebarTreeActions {
    let actions = SidebarTreeActions(
      agentHub: agentHub,
      shellModel: shellModel,
      navigationModel: navigationModel,
      coordinator: coordinator
    )
    let record = $lastWorkspaceOpen
    actions.onWorkspaceOpen = { record.wrappedValue = $0 }
    return actions
  }
}

/// Projects the view models into rows. Its body is the only place the
/// projection runs, so it runs once per observed change, never per row.
private struct SessionTreeContent: View {
  let agentHub: AgentHubProvider
  let actions: SidebarTreeActions
  @Binding var lastWorkspaceOpen: SidebarWorkspaceOpen?

  /// "Load more" pages per branch id. View state: it resets with the window.
  @State private var loadedPages: [String: Int] = [:]

  var body: some View {
    SessionTreeSelectionReader(
      snapshot: SessionTreeSnapshot(agentHub: agentHub, loadedPages: loadedPages),
      actions: actions,
      lastWorkspaceOpen: $lastWorkspaceOpen,
      onLoadMore: { model in
        MainThreadStallMonitor.breadcrumb("tree: load more \(model.repositoryName)")
        // The only animated tree change: the new rows fade in where they
        // land (motion plan item 9). Expand, collapse and selection stay instant.
        withAnimation(.wbAnimation(DesignTokens.Motion.fast)) {
          loadedPages[model.branchID, default: 1] += 1
        }
      }
    )
  }
}

/// Reads the selection in its own body, so selecting a session re-renders
/// the list without projecting the tree again.
private struct SessionTreeSelectionReader: View {
  let snapshot: SessionTreeSnapshot
  let actions: SidebarTreeActions
  @Binding var lastWorkspaceOpen: SidebarWorkspaceOpen?
  let onLoadMore: (LoadMoreRowModel) -> Void

  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(\.sessionNavigationModel) private var navigationModel

  var body: some View {
    SessionTreeList(
      snapshot: snapshot,
      selectedSessionID: SidebarTreeSelection.highlightedSessionID(
        primarySessionId: navigationModel?.primarySessionId,
        selectedWorkspaceID: navigationModel?.selectedWorkspaceID,
        lastWorkspaceOpen: lastWorkspaceOpen
      ),
      isElsewhere: shellModel.destination != .sessions,
      actions: actions,
      onLoadMore: onLoadMore
    )
  }
}

/// One projection pass: the rows, plus every session each repo and branch
/// holds. The session lists are unpaged: context-menu actions and counts
/// cover sessions "Load more" has not shown yet.
struct SessionTreeSnapshot {
  let rows: [SidebarTreeRow]
  let sessionsByRepo: [String: [SessionNode]]
  let sessionsByBranch: [String: [SessionNode]]
  /// Repository of every session, including those in collapsed repositories.
  let repoPathBySessionID: [String: String]

  /// - Parameters:
  ///   - repos: The paged tree that is drawn.
  ///   - unpagedRepos: The same tree with all sessions; defaults to `repos`.
  init(
    repos: [RepoNode],
    unpagedRepos: [RepoNode]? = nil,
    collapsedRepoPaths: Set<String>,
    decorations: BranchWorkflowDecorationIndex,
    title: (SessionNode) -> String
  ) {
    var sessionsByRepo: [String: [SessionNode]] = [:]
    var sessionsByBranch: [String: [SessionNode]] = [:]
    var repoPathBySessionID: [String: String] = [:]
    for repo in unpagedRepos ?? repos {
      sessionsByRepo[repo.path] = repo.branches.flatMap(\.sessions)
      for branch in repo.branches {
        sessionsByBranch[branch.id] = branch.sessions
        for session in branch.sessions {
          repoPathBySessionID[session.id] = repo.path
        }
      }
    }
    self.rows = SidebarTreeRows.rows(
      repos: repos,
      collapsedRepoPaths: collapsedRepoPaths,
      decorations: decorations,
      title: title
    )
    self.sessionsByRepo = sessionsByRepo
    self.sessionsByBranch = sessionsByBranch
    self.repoPathBySessionID = repoPathBySessionID
  }

  @MainActor
  init(agentHub: AgentHubProvider, loadedPages: [String: Int]) {
    let claude = agentHub.claudeSessionsViewModel
    let codex = agentHub.codexSessionsViewModel
    let repositories = ShellSessionItems.repositories(claude: claude, codex: codex)
    let items = ShellSessionItems.items(claude: claude, codex: codex)
    let decorations = BranchWorkflowDecorationIndex(
      branches: agentHub.workflowDashboardViewModel.detectedBranches)
    let projected = SessionTreeProjection.project(
      items: items,
      repositories: repositories,
      loadedPages: loadedPages
    )
    self.init(
      repos: SessionTreeWorkflowMerge.merge(
        repos: projected, repositories: repositories, decorations: decorations),
      unpagedRepos: SessionTreeProjection.project(
        items: items, repositories: repositories, paged: false),
      collapsedRepoPaths: Set(
        repositories.filter { !$0.isExpanded }
          .map { WorktreeModuleResolver.normalizedDirectoryPath($0.path) }),
      decorations: decorations,
      title: { node in
        (node.providerKind == .claude ? claude : codex).displayName(for: node.session)
      }
    )
  }
}

/// Draws the rows and handles the arrow keys.
struct SessionTreeList: View {
  let snapshot: SessionTreeSnapshot
  let selectedSessionID: String?
  let isElsewhere: Bool
  let actions: SidebarTreeActions
  let onLoadMore: (LoadMoreRowModel) -> Void

  @FocusState private var isFocused: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(snapshot.rows) { row in
            rowView(row)
              .id(row.id)
          }
        }
        .padding(.horizontal, DesignTokens.Inset.sidebar)
        .padding(.bottom, DesignTokens.Spacing.sm)
      }
      .scrollIndicators(.automatic)
      .focusable()
      .focused($isFocused)
      .focusEffectDisabled()
      .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
        handleKey(press.key, proxy: proxy)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Sessions")
    }
  }

  @ViewBuilder
  private func rowView(_ row: SidebarTreeRow) -> some View {
    switch row {
    case .repo(let model):
      RepoHeaderRow(
        model: model,
        sessions: snapshot.sessionsByRepo[model.path] ?? [],
        actions: actions
      )
      .equatable()
    case .branch(let model):
      BranchRow(model: model, sessions: snapshot.sessionsByBranch[model.id] ?? [], actions: actions)
        .equatable()
    case .session(let model):
      SessionTreeRow(
        model: model,
        isSelected: model.id == selectedSessionID,
        isElsewhere: isElsewhere,
        actions: actions
      )
      .equatable()
      .simultaneousGesture(TapGesture().onEnded { isFocused = true })
      // Only runs inside an animated transaction ("Load more"); never slides.
      .transition(.opacity)
    case .loadMore(let model):
      LoadMoreRow(model: model, action: { onLoadMore(model) })
        .equatable()
    }
  }

  /// Up and down open the previous or next session; left and right collapse
  /// or expand the selected session's repository (found even while it is
  /// collapsed and the row is hidden).
  private func handleKey(_ key: KeyEquivalent, proxy: ScrollViewProxy) -> KeyPress.Result {
    switch key {
    case .upArrow, .downArrow:
      guard
        let nextID = SidebarTreeRows.adjacentSessionID(
          in: snapshot.rows,
          from: selectedSessionID,
          forward: key == .downArrow,
          repoPathBySessionID: snapshot.repoPathBySessionID
        ),
        let node = sessionNode(nextID)
      else {
        return .ignored
      }
      actions.open(node)
      proxy.scrollTo(nextID)
      return .handled
    case .leftArrow, .rightArrow:
      guard let selectedSessionID,
        let repoPath = snapshot.repoPathBySessionID[selectedSessionID],
        let repo = repoModel(repoPath)
      else {
        return .ignored
      }
      actions.setRepository(repo, collapsed: key == .leftArrow)
      return .handled
    default:
      return .ignored
    }
  }

  private func sessionNode(_ id: String) -> SessionNode? {
    for row in snapshot.rows {
      if case .session(let model) = row, model.id == id { return model.node }
    }
    return nil
  }

  private func repoModel(_ path: String) -> RepoHeaderRowModel? {
    for row in snapshot.rows {
      if case .repo(let model) = row, model.path == path { return model }
    }
    return nil
  }
}

/// Keeps the workflow dashboard's detection running while the sidebar shows,
/// so branch rows get their pull requests and roles. A separate view so the
/// (broad) `sessionRevision` read re-renders only this empty view.
private struct WorkflowDiscoveryDriver: View {
  let viewModel: AgentWorkflowDashboardViewModel

  /// `load()` asks both providers for their full session inventory, which
  /// the app otherwise defers. Wait until launch has settled.
  private static let loadDelay: Duration = .seconds(3)
  /// Session activity changes the revision often; coalesce refreshes.
  private static let refreshDebounce: Duration = .seconds(1)

  var body: some View {
    Color.clear
      .task {
        try? await Task.sleep(for: Self.loadDelay)
        guard !Task.isCancelled else { return }
        await viewModel.load()
      }
      .task(id: viewModel.sessionRevision) {
        try? await Task.sleep(for: Self.refreshDebounce)
        guard !Task.isCancelled else { return }
        await viewModel.refreshDetectedWorkflows()
      }
      .accessibilityHidden(true)
  }
}
