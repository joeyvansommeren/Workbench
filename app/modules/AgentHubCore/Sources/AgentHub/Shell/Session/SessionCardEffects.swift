//
//  SessionCardEffects.swift
//  AgentHub
//
//  Every side effect a visible session runs: preview-candidate, capability,
//  diff and MCP-app loading, Jira keys, measurements and Studio items, GitHub
//  PR observation, the coalesced activity refresh, the chat's live terminal
//  status poll, and drag-and-drop into the terminal.
//
//  Moved out of `MonitoringCardView` so the legacy card and the new shell's
//  `SessionDetailView` run the exact same effects from one place.
//

import AgentHubGitHub
import SwiftUI
import UniformTypeIdentifiers

struct SessionCardEffects: ViewModifier {
  let session: CLISession
  let state: SessionMonitorState?
  let providerKind: SessionProviderKind
  let viewModel: CLISessionsViewModel?
  let terminalKey: String?
  let quickAccessViewModel: SessionGitHubQuickAccessViewModel
  let linkedPullRequests: [GitHubPullRequestURLReference]
  /// The live status poll only runs for the active session while its chat shows.
  let isPrimarySession: Bool
  let isChatVisible: Bool
  @Binding var liveTerminalStatus: String?
  @Binding var contentMode: MonitoringCardContentMode
  @Binding var isDragging: Bool

  @Environment(\.agentHub) private var agentHub
  @State private var activityRefreshTask: Task<Void, Never>?
  @State private var pendingActivityTimestamp: Date?

  private var hubProvider: AgentHubProvider? {
    viewModel?.agentHubProvider ?? agentHub
  }

  private var mcpAppInvocationResolutionKey: String {
    (state?.detectedMCPAppInvocations ?? []).map(\.id).joined(separator: ",")
  }

  private var gitHubObservationTaskID: String {
    SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: session.projectPath,
      branchName: session.branchName,
      linkedPullRequests: linkedPullRequests
    )
  }

  private var liveStatusPollKey: String {
    "\(isPrimarySession)|\(isChatVisible)|\(terminalKey ?? session.id)"
  }

  func body(content: Content) -> some View {
    content
      .task(id: session.projectPath) {
        await loadWebPreviewCandidateIfNeeded()
      }
      .task(id: liveStatusPollKey) {
        await pollLiveTerminalStatus()
      }
      .task {
        // Project keys come from Jira; without them branch names can't be matched.
        await hubProvider?.jiraSprintViewModel.loadIfNeeded()
      }
      .task(id: session.projectPath) {
        await viewModel?.ensureProjectCapabilities(for: session.projectPath)
      }
      .task(id: session.projectPath) {
        await viewModel?.ensureDiffAvailability(for: session.projectPath, forceRefresh: true)
      }
      .task(id: session.projectPath) {
        await viewModel?.ensureLocalDiffSummary(for: session.projectPath, forceRefresh: true)
      }
      .task(id: mcpAppInvocationResolutionKey) {
        await viewModel?.ensureMCPAppRenderItems(for: session, state: state)
      }
      // Measurements outlive the session that filed them, so the button has to reflect
      // what this project already holds — not just what this session produced.
      .task(id: session.projectPath) {
        viewModel?.loadMeasurements(for: session)
        viewModel?.loadStudioArtifacts(for: session)
      }
      .task(id: gitHubObservationTaskID) {
        await observeGitHub()
      }
      .onDisappear {
        quickAccessViewModel.stopPolling()
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
      }
      .onChange(of: state?.lastActivityAt) { _, newValue in
        scheduleActivityRefresh(newValue)
      }
      .onChange(of: state?.detectedLocalhostURL) { _, newValue in
        guard newValue == nil else { return }
        Task {
          await loadWebPreviewCandidateIfNeeded()
        }
      }
      .onDrop(
        of: [.agentHubGitHubContextItem, .fileURL, .png, .tiff, .image, .pdf],
        isTargeted: $isDragging
      ) { providers in
        handleDroppedItems(providers)
        return true
      }
  }

  // MARK: - GitHub

  private func observeGitHub() async {
    if linkedPullRequests.isEmpty {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
    }
    if let notifier = viewModel?.agentHubProvider?.gitHubCIFailureNotifier
      ?? agentHub?.gitHubCIFailureNotifier
    {
      let context = GitHubCIFailureSessionContext(
        sessionId: session.id,
        providerKind: providerKind,
        projectPath: session.projectPath,
        branchName: session.branchName
      )
      quickAccessViewModel.onSnapshotApplied = { snapshot in
        notifier.evaluate(snapshot: snapshot, context: context)
      }
    }
    await quickAccessViewModel.load(
      projectPath: session.projectPath,
      branchName: session.branchName,
      linkedPullRequests: linkedPullRequests,
      coordinator: viewModel?.agentHubProvider?.gitHubQuickAccessCoordinator
        ?? agentHub?.gitHubQuickAccessCoordinator,
      observationService: viewModel?.agentHubProvider?.gitHubPRObservationService
        ?? agentHub?.gitHubPRObservationService
    )
    if let lastActivityAt = state?.lastActivityAt {
      await quickAccessViewModel.notifySessionActivity(at: lastActivityAt)
    }
  }

  /// Pull requests this session works on: links detected in its transcript
  /// plus the ones Reviews associated with it, without duplicates.
  @MainActor
  static func linkedPullRequests(
    session: CLISession,
    state: SessionMonitorState?,
    providerKind: SessionProviderKind,
    hubProvider: AgentHubProvider?
  ) -> [GitHubPullRequestURLReference] {
    let resourceLinks = state?.detectedResourceLinks ?? []
    let detected = GitHubPullRequestURLReferenceCache.references(in: resourceLinks.map(\.url))
    let itemID = SidebarSessionItemID.monitored(provider: providerKind, sessionId: session.id)
    let associated =
      hubProvider?.gitHubReviewsViewModel
      .linkedPullRequestReferencesByItemID(provider: providerKind)[itemID] ?? []
    var seen: Set<GitHubPullRequestURLReference> = []
    return (detected + associated).filter { seen.insert($0).inserted }
  }

  // MARK: - Activity refresh

  private func scheduleActivityRefresh(_ newValue: Date?) {
    guard let newValue else { return }
    // Coalesce to one refresh pass per 2s: this fires on every parsed JSONL
    // activity while the agent streams, and per-tick forced git refreshes
    // thrash the observable dictionaries and the diff actors. The trailing
    // task picks up the latest timestamp at fire time.
    pendingActivityTimestamp = newValue
    guard activityRefreshTask == nil else { return }
    activityRefreshTask = Task { @MainActor in
      defer { activityRefreshTask = nil }
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, let timestamp = pendingActivityTimestamp else { return }
      pendingActivityTimestamp = nil
      await quickAccessViewModel.notifySessionActivity(at: timestamp)
      await loadWebPreviewCandidateIfNeeded()
      await viewModel?.ensureDiffAvailability(for: session.projectPath, forceRefresh: true)
      await viewModel?.ensureLocalDiffSummary(for: session.projectPath, forceRefresh: true)
    }
  }

  @MainActor
  private func loadWebPreviewCandidateIfNeeded() async {
    guard state?.detectedLocalhostURL == nil else { return }
    await viewModel?.ensureWebPreviewCandidate(for: session.projectPath)
  }

  // MARK: - Live terminal status

  /// Whether this session reads its agent tab's screen: only the active one,
  /// only while its chat is on screen. One bounded read of a few rows every two
  /// seconds; no file I/O, no other terminals.
  private func pollLiveTerminalStatus() async {
    guard isPrimarySession, isChatVisible else {
      liveTerminalStatus = nil
      return
    }
    let key = terminalKey ?? session.id
    while !Task.isCancelled {
      let tail = viewModel?.agentTerminalScreenTail(forKey: key, maxRows: Self.liveStatusRows)
      let status = tail.flatMap(TerminalLiveStatusDetector.status(in:))
      if status != liveTerminalStatus { liveTerminalStatus = status }
      try? await Task.sleep(for: .seconds(2))
    }
    liveTerminalStatus = nil
  }

  private static let liveStatusRows = 12

  // MARK: - Drag and drop

  /// Handles dropped providers by typing context into the terminal without submitting.
  private func handleDroppedItems(_ providers: [NSItemProvider]) {
    guard let key = terminalKey, let viewModel = viewModel else { return }

    if handleDroppedGitHubContext(providers, key: key, viewModel: viewModel) {
      return
    }

    handleDroppedFiles(providers, key: key, viewModel: viewModel)
  }

  private func handleDroppedGitHubContext(
    _ providers: [NSItemProvider],
    key: String,
    viewModel: CLISessionsViewModel
  ) -> Bool {
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(GitHubContextDragPayload.typeIdentifier)
      })
    else {
      return false
    }

    let contentMode = $contentMode
    GitHubContextDragPayload.load(from: provider) { payload in
      guard let payload else { return }

      Task { @MainActor in
        contentMode.wrappedValue = .terminal
        viewModel.typeToTerminal(forKey: key, text: payload.commandText + " ")
        viewModel.focusTerminal(forKey: key)
      }
    }

    return true
  }

  /// Handles dropped file providers by extracting paths and typing them into terminal.
  private func handleDroppedFiles(
    _ providers: [NSItemProvider],
    key: String,
    viewModel: CLISessionsViewModel
  ) {
    for provider in providers {
      // Handle file URLs (files dragged from Finder)
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
          guard let url = url, error == nil else { return }

          Task { @MainActor in
            let path = url.path
            let quotedPath = path.contains(" ") ? "\"\(path)\"" : path
            viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
          }
        }
      }
      // Handle PNG data (screenshots)
      else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
        Self.typeDroppedData(provider, type: .png, fileName: "screenshot", ext: "png", key: key, viewModel: viewModel)
      }
      // Handle TIFF data (another screenshot format)
      else if provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
        Self.typeDroppedData(provider, type: .tiff, fileName: "screenshot", ext: "tiff", key: key, viewModel: viewModel)
      }
      // Handle generic image data
      else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        Self.typeDroppedData(provider, type: .image, fileName: "dropped_image", ext: "png", key: key, viewModel: viewModel)
      }
      // Handle PDF data (documents dragged from Preview or other apps)
      else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        Self.typeDroppedData(provider, type: .pdf, fileName: "dropped_document", ext: "pdf", key: key, viewModel: viewModel)
      }
    }
  }

  /// Writes dropped data to a temporary file and types its quoted path.
  private static func typeDroppedData(
    _ provider: NSItemProvider,
    type: UTType,
    fileName: String,
    ext: String,
    key: String,
    viewModel: CLISessionsViewModel
  ) {
    _ = provider.loadDataRepresentation(for: type) { data, error in
      guard let data = data, error == nil else { return }

      Task { @MainActor in
        let tempURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("\(fileName)_\(UUID().uuidString).\(ext)")
        do {
          try data.write(to: tempURL)
          let quotedPath = tempURL.path.contains(" ") ? "\"\(tempURL.path)\"" : tempURL.path
          viewModel.typeToTerminal(forKey: key, text: quotedPath + " ")
        } catch {
          print("Failed to save dropped \(ext): \(error)")
        }
      }
    }
  }
}
