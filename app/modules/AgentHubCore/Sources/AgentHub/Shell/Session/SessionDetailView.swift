//
//  SessionDetailView.swift
//  AgentHub
//
//  The Sessions detail of the new shell: the selected tab's header, its
//  content (terminal, chat, files or diffs) and the side panel.
//
//  Layout-loop safety (implementation plan, section 4): no split views and no
//  geometry-driven widths. The side panel is the custom
//  `ResizablePanelContainer` with fixed bounds; the legacy
//  `MultiProviderMonitoringPanelView` (and its workflow-comparison
//  `HSplitView`) is not used here.
//

import AgentHubGitDiff
import AgentHubGitHub
import SwiftUI

struct SessionDetailView: View {
  @Bindable var claudeViewModel: CLISessionsViewModel
  @Bindable var codexViewModel: CLISessionsViewModel
  @Bindable var workspaceViewModel: AgentWorkspacesViewModel

  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.sessionNavigationModel) private var navigationModel
  @Environment(\.sessionsActionCoordinator) private var actionCoordinator
  @Environment(SessionTabsModel.self) private var tabsModel

  @AppStorage(AgentHubDefaults.selectedSidePanelProvider)
  private var selectedProviderRaw: String = "Claude"

  var body: some View {
    if let navigationModel {
      content(navigationModel: navigationModel)
    }
  }

  private func content(navigationModel: SessionNavigationModel) -> some View {
    VStack(spacing: 0) {
      WorktreeGenerationProgressBar()
      if let workspaceID = navigationModel.selectedWorkspaceID,
        let workspace = workspaceViewModel.workspace(id: workspaceID)
      {
        AgentWorkspaceDetailView(
          workspace: workspace,
          viewModel: workspaceViewModel,
          onRename: { name in
            Task { await workspaceViewModel.renameWorkspace(id: workspace.id, name: name) }
          },
          onClose: {
            actionCoordinator?.requestCloseWorkspace(
              workspace.id,
              workspaceViewModel: workspaceViewModel,
              navigationModel: navigationModel
            )
          }
        )
      } else if let item = selectedItem(navigationModel: navigationModel) {
        SessionDetailContent(
          item: item,
          viewModel: viewModel(for: item.providerKind),
          presentation: SessionTabPresentation.make(
            item: item,
            title: viewModel(for: item.providerKind).displayName(for: item.session),
            repositories: ShellSessionItems.repositories(claude: claudeViewModel, codex: codexViewModel)
          ),
          onFork: { sessionActions?.forkSession($0, targetProvider: $1) }
        )
        .id(item.id)
      } else {
        emptyState
      }
    }
    .onAppear {
      consumeRouterRequests()
      openFirstSessionIfNothingIsOpen()
    }
    .task { await workspaceViewModel.load() }
    .onChange(of: agentHub?.globalSessionSelectionRouter.selectionRequest?.id) { _, _ in
      consumeRouterRequests()
    }
    .onChange(of: agentHub?.globalSessionSelectionRouter.comparisonRequest?.id) { _, _ in
      consumeRouterRequests()
    }
    .onChange(of: navigationModel.workflowComparisonState.presentedComparison?.id) { _, _ in
      openPresentedComparisonAsTabs()
    }
    .onChange(of: itemIDs) { _, _ in
      consumeRouterRequests()
    }
    .onChange(of: claudeViewModel.pendingFileOpen?.filePath) { _, _ in
      consumePendingFileOpen(from: claudeViewModel, providerKind: .claude)
    }
    .onChange(of: codexViewModel.pendingFileOpen?.filePath) { _, _ in
      consumePendingFileOpen(from: codexViewModel, providerKind: .codex)
    }
  }

  private var emptyState: some View {
    WBEmptyState(
      systemImage: "rectangle.stack",
      title: "No open sessions",
      description: "Pick a session in the sidebar, or start a new one."
    ) {
      Button("New Session") { sessionActions?.startFocusedSession() }
        .buttonStyle(WBPrimaryButtonStyle())
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Items

  private var items: [ProjectableSessionItem] {
    ShellSessionItems.items(claude: claudeViewModel, codex: codexViewModel)
  }

  private var itemIDs: [String] { items.map(\.id) }

  private func selectedItem(navigationModel: SessionNavigationModel) -> ProjectableSessionItem? {
    guard let id = navigationModel.primarySessionId else { return nil }
    return items.first { $0.id == id }
  }

  private func viewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    provider == .claude ? claudeViewModel : codexViewModel
  }

  private var sessionActions: ShellSessionActions? {
    guard let agentHub, let actionCoordinator, let navigationModel else { return nil }
    return ShellSessionActions(
      agentHub: agentHub, coordinator: actionCoordinator, navigationModel: navigationModel)
  }

  // MARK: - Selection upkeep

  /// First visit with no tabs at all: open the newest session, like the
  /// legacy view always showed one. Closing every tab later leaves the empty
  /// state instead.
  private func openFirstSessionIfNothingIsOpen() {
    guard let navigationModel, tabsModel.openTabIDs.isEmpty, navigationModel.primarySessionId == nil
    else { return }
    let standalone = items.filter { item in
      item.isPending
        || workspaceViewModel.workspaceID(owningSession: item.session.id, provider: item.providerKind) == nil
    }
    navigationModel.ensurePrimarySelection(
      items: ShellSessionItems.snapshots(standalone),
      hasRouterRequest: agentHub?.globalSessionSelectionRouter.selectionRequest != nil
    )
  }

  private func consumeRouterRequests() {
    guard let navigationModel else { return }
    navigationModel.consumeGlobalSessionSelectionIfNeeded(
      router: agentHub?.globalSessionSelectionRouter,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      workspaceViewModel: workspaceViewModel,
      selectedSessionItems: { ShellSessionItems.snapshots(items) },
      colorScheme: colorScheme,
      // The new shell has no auxiliary shell dock.
      setAuxiliaryShellVisible: { _ in },
      selectedProviderRawSetter: { selectedProviderRaw = $0 }
    )
    navigationModel.consumeGlobalWorkflowComparisonIfNeeded(
      router: agentHub?.globalSessionSelectionRouter,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel,
      availableItemIDs: { Set(itemIDs) }
    )
  }

  /// The new shell has no side-by-side comparison yet: both sessions open as
  /// tabs and the implementation stays selected.
  private func openPresentedComparisonAsTabs() {
    guard let comparison = navigationModel?.workflowComparisonState.presentedComparison else { return }
    tabsModel.open(comparison.review.itemID)
    tabsModel.open(comparison.implementation.itemID)
    navigationModel?.selectSession(comparison.implementation.itemID)
  }

  /// Cmd+click on a file path in a terminal: show the file in that session's
  /// Files view (same routing as the legacy panel).
  private func consumePendingFileOpen(
    from viewModel: CLISessionsViewModel,
    providerKind: SessionProviderKind
  ) {
    guard let pending = viewModel.pendingFileOpen else { return }
    defer { viewModel.pendingFileOpen = nil }
    guard
      let session = viewModel.allSessions.first(where: { $0.id == pending.sessionId })
        ?? viewModel.monitoredSessions.first(where: { $0.session.id == pending.sessionId })?.session,
      let item = items.first(where: {
        $0.providerKind == providerKind && $0.session.id == pending.sessionId
      })
    else { return }
    let projectPath = TerminalFileOpenProjectResolver.projectPath(
      forFile: pending.filePath,
      sessionProjectPath: session.projectPath,
      repositories: ShellSessionItems.repositories(claude: claudeViewModel, codex: codexViewModel)
    )
    tabsModel.openFile(pending.filePath, lineNumber: pending.lineNumber, projectPath: projectPath, for: item.id)
    navigationModel?.selectSession(item.id)
  }
}

// MARK: - One session

/// Header, content and side panel of one session. Keyed by item id, so its
/// per-session state (GitHub quick access, sheets) starts fresh per tab while
/// the terminal itself lives on in the view model.
private struct SessionDetailContent: View {
  let item: ProjectableSessionItem
  let viewModel: CLISessionsViewModel
  let presentation: SessionTabPresentation
  let onFork: (CLISession, SessionProviderKind) -> Void

  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(WorkbenchShellModel.self) private var shellModel
  @Environment(SessionTabsModel.self) private var tabsModel

  @State private var quickAccessViewModel = SessionGitHubQuickAccessViewModel()
  @State private var liveTerminalStatus: String?
  @State private var isDragging = false
  @State private var isSidePanelExpanded = false
  @State private var showingNameSheet = false
  @State private var showingFilePicker = false
  @State private var gitHubPopOut: SessionGitHubPopOut?
  @State private var transcript: SessionTranscript?
  @State private var claudeTheme: String?
  @AppStorage(AgentHubDefaults.chatEnabled) private var chatEnabled = false
  @AppStorage(AgentHubDefaults.diffDisplayMode)
  private var diffDisplayModeRawValue: String = DiffDisplayMode.inline.rawValue

  private var session: CLISession { item.session }
  private var providerKind: SessionProviderKind { item.providerKind }
  private var hubProvider: AgentHubProvider? { viewModel.agentHubProvider ?? agentHub }

  private var pending: PendingHubSession? {
    guard let pendingID = item.pendingID else { return nil }
    return viewModel.pendingHubSessions.first { $0.id == pendingID }
  }

  private var state: SessionMonitorState? {
    item.isPending ? nil : viewModel.monitorStates[session.id]
  }

  private var terminalKey: String {
    if let pendingID = item.pendingID { return "pending-\(pendingID.uuidString)" }
    return session.id
  }

  private var diffDisplayMode: DiffDisplayMode {
    DiffDisplayMode(rawValue: diffDisplayModeRawValue) ?? .inline
  }

  private var availableContentModes: [MonitoringCardContentMode] {
    MonitoringEditorStateStore.availableContentModes(
      diffDisplayMode: diffDisplayMode,
      diffAvailabilityStatus: viewModel.diffAvailabilityStatus(for: session.projectPath),
      chatEnabled: chatEnabled
    )
  }

  private var editorState: MonitoringEditorState {
    tabsModel.editorState(for: item.id, defaultProjectPath: session.projectPath)
  }

  private var effectiveContentMode: MonitoringCardContentMode {
    MonitoringEditorStateStore.coercedContentMode(
      editorState.contentMode, availableModes: availableContentModes)
  }

  private var contentModeBinding: Binding<MonitoringCardContentMode> {
    Binding(
      get: { effectiveContentMode },
      set: { mode in
        tabsModel.setContentMode(mode, for: item.id, defaultProjectPath: session.projectPath)
        if mode == .terminal { viewModel.focusTerminal(forKey: terminalKey) }
      }
    )
  }

  private var selectedEditorFilePath: Binding<String?> {
    Binding(
      get: { editorState.selectedFilePath },
      set: { tabsModel.setSelectedFilePath($0, for: item.id, defaultProjectPath: session.projectPath) }
    )
  }

  private var linkedPullRequests: [GitHubPullRequestURLReference] {
    SessionCardEffects.linkedPullRequests(
      session: session, state: state, providerKind: providerKind, hubProvider: hubProvider)
  }

  private var isDark: Bool { colorScheme == .dark }

  var body: some View {
    VStack(spacing: 0) {
      SessionHeaderView(
        presentation: presentation,
        contextFraction: state?.contextWindowUsagePercentage,
        availableContentModes: availableContentModes,
        contentMode: contentModeBinding,
        isSidePanelVisible: shellModel.sidePanelVisible,
        onToggleSidePanel: shellModel.toggleSidePanel
      ) { dismiss in
        SessionActionsMenu(
          session: session,
          providerKind: providerKind,
          isPending: item.isPending,
          viewModel: viewModel,
          quickAccessViewModel: quickAccessViewModel,
          onDismiss: dismiss,
          onViewTranscript: openTranscript,
          onRename: { showingNameSheet = true },
          onAddFiles: { showingFilePicker = true },
          onFork: { onFork(session, providerKind) },
          onCreatePullRequest: createPullRequest
        )
      }
      if showsClaudeThemeHint {
        ClaudeThemeHintBanner()
      }
      SessionSubagentsSection(
        session: session,
        providerKind: providerKind,
        refreshTrigger: state?.lastActivityAt,
        service: hubProvider?.subagentDiscoveryService,
        reader: hubProvider?.chatTranscriptReader ?? ChatTranscriptReader()
      )
      HStack(spacing: 0) {
        // Stays mounted while the side panel is expanded (hidden, zero width),
        // so the terminal view is not torn down.
        let hidesContent = shellModel.sidePanelVisible && isSidePanelExpanded
        contentArea
          .frame(width: hidesContent ? 0 : nil)
          .frame(maxWidth: hidesContent ? 0 : .infinity)
          .opacity(hidesContent ? 0 : 1)
          .allowsHitTesting(!hidesContent)
          .accessibilityHidden(hidesContent)
          .clipped()
        if shellModel.sidePanelVisible {
          sidePanel
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .modifier(
      SessionCardEffects(
        session: session,
        state: state,
        providerKind: providerKind,
        viewModel: viewModel,
        terminalKey: terminalKey,
        quickAccessViewModel: quickAccessViewModel,
        linkedPullRequests: linkedPullRequests,
        isPrimarySession: true,
        isChatVisible: effectiveContentMode == .chat,
        liveTerminalStatus: $liveTerminalStatus,
        contentMode: contentModeBinding,
        isDragging: $isDragging
      )
    )
    .overlay {
      if isDragging {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.container)
          .strokeBorder(Color.wbAccent, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .task(id: session.id) {
      // Codex sessions only stream while live monitoring runs for them.
      if providerKind == .codex, !item.isPending {
        viewModel.ensureLiveMonitoring(sessionId: session.id)
      }
      guard providerKind == .claude, AppleShellLaunchFlag.isEnabled else { return }
      claudeTheme = await ClaudeTUIThemeReader().currentTheme()
    }
    .sheet(item: $transcript) { transcript in
      SessionTranscriptSheetView(
        session: transcript.session,
        fileName: transcript.fileName,
        content: transcript.content,
        onDismiss: { self.transcript = nil }
      )
    }
    .sheet(isPresented: $showingNameSheet) {
      NameSessionSheet(
        session: session,
        currentName: viewModel.sessionCustomNames[session.id],
        onSave: { name in viewModel.setCustomName(name, for: session) },
        onDismiss: { showingNameSheet = false }
      )
    }
    .modalPanel(
      item: $gitHubPopOut,
      title: "GitHub",
      autosaveName: "com.agenthub.panel.github"
    ) { popOut in
      GitHubPanelView(
        projectPath: popOut.projectPath,
        branchName: popOut.session.branchName,
        linkedPullRequests: popOut.linkedPullRequests,
        onDismiss: { gitHubPopOut = nil },
        isEmbedded: false,
        session: popOut.session,
        viewModel: popOut.viewModel,
        onSendToSession: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) }
      )
      .onDisappear { popOut.viewModel.stopObserving() }
    }
    .fileImporter(
      isPresented: $showingFilePicker,
      allowedContentTypes: [.image, .pdf, .plainText, .data],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      for url in urls {
        let path = url.path
        viewModel.typeToTerminal(forKey: terminalKey, text: (path.contains(" ") ? "\"\(path)\"" : path) + " ")
      }
    }
  }

  private var showsClaudeThemeHint: Bool {
    ClaudeTUIThemeHint.shouldShow(
      claudeTheme: claudeTheme,
      providerKind: providerKind,
      isDarkTerminal: isDark,
      followsWorkbenchPalette: AppleShellLaunchFlag.isEnabled
    ) && effectiveContentMode == .terminal
  }

  // MARK: - Content

  private var contentArea: some View {
    MonitoringCardContentArea(
      session: session,
      state: state,
      providerKind: providerKind,
      viewModel: viewModel,
      hubProvider: hubProvider,
      terminalKey: terminalKey,
      cliConfiguration: viewModel.cliConfiguration(for: providerKind),
      initialPrompt: pending?.initialPrompt ?? viewModel.pendingPrompt(for: session.id),
      initialInputText: pending?.initialInputText,
      launchContext: pending?.launchContext,
      dangerouslySkipPermissions: pending?.dangerouslySkipPermissions ?? false,
      permissionModePlan: pending?.permissionModePlan ?? false,
      worktreeName: pending?.worktreeName,
      mode: effectiveContentMode,
      contentMode: contentModeBinding,
      selectedEditorFilePath: selectedEditorFilePath,
      editorProjectPath: editorState.projectPath,
      editorNavigationRequest: editorState.navigationRequest,
      isPrimarySession: true,
      liveTerminalStatus: liveTerminalStatus,
      onTerminalInteraction: nil,
      onRequestShowEditor: {
        tabsModel.setContentMode(.editor, for: item.id, defaultProjectPath: session.projectPath)
      },
      onInlineRequestSubmit: { prompt, sess in viewModel.showTerminalWithPrompt(for: sess, prompt: prompt) },
      chatBackground: Color.wbSurfaceContent
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.wbSurfaceTerminal)
  }

  // MARK: - Side panel

  private var sidePanelAvailability: SidePanelAvailability {
    let capabilities = viewModel.projectCapabilities(for: session.projectPath)
    return SidePanelAvailability(
      diffDisplayMode: diffDisplayMode,
      hasStorybook: capabilities?.hasStorybook == true,
      showsWebPreview: WebPreviewCandidateVisibility.shouldShow(
        candidateStatus: viewModel.webPreviewCandidateStatus(for: session.projectPath),
        detectedLocalhostURL: state?.detectedLocalhostURL
      ),
      queuedPreviewContextCount: viewModel.queuedWebPreviewContextStore.count(for: session.id),
      mcpAppCount: viewModel.mcpAppDisplayItems(for: session, state: state).count,
      measurementCount: viewModel.measurements(for: session).count,
      studioArtifactCount: viewModel.studioArtifacts(for: session).count,
      artifactCount: providerKind == .claude ? (state?.detectedArtifacts.count ?? 0) : 0,
      hasMermaidContent: state?.hasMermaidContent == true,
      isXcodeProject: capabilities?.isXcodeProject == true,
      hasPendingCodeChange: state?.pendingToolUse?.isCodeChangeTool == true
    )
  }

  private var segmentBinding: Binding<SidePanelSegment> {
    Binding(
      get: {
        SidePanelSegments.coerced(tabsModel.sidePanelSegment(for: item.id), availability: sidePanelAvailability)
      },
      set: { segment in
        if segment == .storybook {
          Task {
            await DevServerManager.shared.startStorybookServer(for: session.id, projectPath: session.projectPath)
          }
        }
        tabsModel.setSidePanelSegment(segment, for: item.id)
      }
    )
  }

  @ViewBuilder
  private var sidePanel: some View {
    let panel = SessionSidePanel(
      segment: segmentBinding,
      availability: sidePanelAvailability,
      diffSummary: viewModel.localDiffSummary(for: session.projectPath),
      onCommit: item.isPending ? nil : commitChanges
    ) {
      sidePanelBody
    }
    if isSidePanelExpanded {
      panel.frame(maxWidth: .infinity)
    } else {
      // Fixed bounds, no geometry: 400 default, 320–640 by drag.
      ResizablePanelContainer(
        side: .trailing,
        minWidth: 320,
        maxWidth: 640,
        defaultWidth: DesignTokens.Width.sidePanel,
        userDefaultsKey: AgentHubDefaults.sidePanelWidth
      ) {
        panel
      }
      .overlay(alignment: .leading) {
        Rectangle().fill(Color.wbBorderHairline).frame(width: 1).allowsHitTesting(false)
      }
    }
  }

  @ViewBuilder
  private var sidePanelBody: some View {
    let segment = segmentBinding.wrappedValue
    if let content = sidePanelContent(for: segment) {
      SidePanelContentView(
        content: content,
        providerKind: providerKind,
        viewModel: viewModel,
        onDismiss: {
          isSidePanelExpanded = false
          if shellModel.sidePanelVisible { shellModel.toggleSidePanel() }
        },
        onShowTerminalWithPrompt: { prompt, sess in
          contentModeBinding.wrappedValue = .terminal
          viewModel.showTerminalWithPrompt(for: sess, prompt: prompt)
        },
        onGitHubPopOut: { panelViewModel, popSession, projectPath, links in
          gitHubPopOut = SessionGitHubPopOut(
            session: popSession, projectPath: projectPath, linkedPullRequests: links, viewModel: panelViewModel)
        },
        isExpanded: isSidePanelExpanded,
        onToggleExpanded: { isSidePanelExpanded.toggle() },
        onCollapseExpandedAfterSend: { isSidePanelExpanded = false },
        openEditorFilePath: editorState.selectedFilePath
      )
      .id("\(item.id)|\(segment.rawValue)")
    } else {
      WBEmptyState(
        systemImage: "checklist",
        title: "No plan yet",
        description: "The plan shows here when the agent writes one."
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Maps a segment to the legacy panel content. Nil only for Plan without a plan.
  private func sidePanelContent(for segment: SidePanelSegment) -> SidePanelContent? {
    switch segment {
    case .diff:
      return .diff(sessionId: session.id, session: session, projectPath: session.projectPath)
    case .plan:
      guard let planState = state.flatMap({ PlanState.from(activities: $0.recentActivities) }) else {
        return nil
      }
      return .plan(sessionId: session.id, session: session, planState: planState)
    case .edits:
      return .edits(sessionId: session.id, session: session)
    case .storybook:
      return .webPreview(sessionId: session.id, session: session, projectPath: session.projectPath, mode: .storybook)
    case .preview:
      return .webPreview(sessionId: session.id, session: session, projectPath: session.projectPath, mode: .app)
    case .mcpApps:
      return .mcpApp(sessionId: session.id, session: session, projectPath: session.projectPath)
    case .measurements:
      return .measurements(sessionId: session.id, session: session)
    case .studio:
      return .studio(sessionId: session.id, session: session)
    case .artifact:
      return .claudeArtifact(sessionId: session.id, session: session)
    case .diagram:
      return .mermaid(sessionId: session.id, session: session)
    case .simulator:
      return .simulator(sessionId: session.id, session: session, projectPath: session.projectPath)
    case .gitHub:
      return .gitHub(
        sessionId: session.id, session: session, projectPath: session.projectPath,
        linkedPullRequests: linkedPullRequests)
    }
  }

  // MARK: - Actions

  private func openTranscript() {
    guard let fileURL = viewModel.sessionFileURL(for: session),
      let data = FileManager.default.contents(atPath: fileURL.path),
      let content = String(data: data, encoding: .utf8),
      !content.isEmpty
    else { return }
    transcript = SessionTranscript(session: session, fileName: fileURL.lastPathComponent, content: content)
  }

  private func commitChanges() {
    let fileCount = viewModel.localDiffSummary(for: session.projectPath)?.fileCount ?? 0
    contentModeBinding.wrappedValue = .terminal
    CommitChangesAction.perform(
      session: session, terminalKey: terminalKey, fileCount: fileCount, viewModel: viewModel)
  }

  private static let createPullRequestPrompt =
    "Make a PR for the current branch. Include the local changes in this worktree and use the session context for the title, body, and validation notes."

  /// Same prompt and cooldown as the legacy card's "Create PR".
  private func createPullRequest() {
    guard viewModel.beginCreatingPullRequest(for: session.id) else { return }
    contentModeBinding.wrappedValue = .terminal
    if !viewModel.sendPromptToActiveTerminal(forKey: terminalKey, prompt: Self.createPullRequestPrompt) {
      viewModel.showTerminalWithPrompt(for: session, prompt: Self.createPullRequestPrompt)
    }
    viewModel.focusTerminal(forKey: terminalKey)
    Task {
      try? await Task.sleep(for: .seconds(2))
      viewModel.endCreatingPullRequest(for: session.id)
    }
  }
}

private struct SessionTranscript: Identifiable {
  let id = UUID()
  let session: CLISession
  let fileName: String
  let content: String
}

private struct SessionGitHubPopOut: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
  let linkedPullRequests: [GitHubPullRequestURLReference]
  let viewModel: GitHubViewModel
}

/// One quiet line under the header when Claude's TUI theme is dark on a light terminal.
private struct ClaudeThemeHintBanner: View {
  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: "circle.lefthalf.filled")
        .font(.system(size: 11))
        .foregroundStyle(Color.wbTextSecondary)
      Text(ClaudeTUIThemeHint.message)
        .wbText(.callout)
        .foregroundStyle(Color.wbTextSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, DesignTokens.Spacing.xl)
    .frame(height: 28)
    .background(Color.wbSurfaceField)
    .accessibilityElement(children: .combine)
  }
}
