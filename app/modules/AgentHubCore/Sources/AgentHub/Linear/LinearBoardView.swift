//
//  LinearBoardView.swift
//  AgentHub
//
//  Linear board: workflow state columns, team switching, issue details,
//  and handing an issue to Claude or Codex.
//

import AgentWorkflowLinear
import SwiftUI

struct LinearBoardView: View {
  @Bindable var viewModel: LinearViewModel
  let repositories: [SelectedRepository]
  let linkedSessions: [String: [LinearLinkedSession]]

  let readStartOptions: () -> [TicketSessionProviderOption]
  let onStart: (LinearIssue, SessionProviderKind, String) async -> String?
  let onOpenSession: (LinearLinkedSession) -> Void

  @State private var sessionRequest: TicketSessionRequest?
  @FocusState private var isBoardFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .inspector(isPresented: isDetailPresented) {
      detail
        .inspectorColumnWidth(min: 340, ideal: 420, max: 560)
    }
    .sheet(item: $sessionRequest) { request in
      TicketSessionChooser(
        request: request, repositories: repositories, repositoryPath: viewModel.repositoryPath,
        readOptions: readStartOptions, onStarted: { viewModel.repositoryPath = $0 })
    }
    .task {
      if viewModel.loadState == .idle || viewModel.loadState == .noKey {
        await viewModel.load()
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.loadState {
    case .noKey:
      LinearConnectView(viewModel: viewModel)
    case .unauthorized:
      LinearErrorView(
        title: "Unauthorized",
        message: "The API key is invalid or revoked.",
        viewModel: viewModel,
        showReconnect: true
      )
    case .rateLimited:
      LinearErrorView(
        title: "Rate limited",
        message: "Linear asked Workbench to slow down. Try again in a moment.",
        viewModel: viewModel,
        showReconnect: false
      )
    case .failed(let message):
      LinearErrorView(
        title: "Could not load Linear",
        message: message,
        viewModel: viewModel,
        showReconnect: false
      )
    case .idle, .loading, .loaded:
      if viewModel.loadState == .loaded || !viewModel.issues.isEmpty {
        loadedContent
      } else {
        LinearBoardSkeleton()
      }
    }
  }

  @ViewBuilder
  private var loadedContent: some View {
    LinearBoardHeader(viewModel: viewModel)
    if viewModel.issues.isEmpty && viewModel.loadState == .loaded {
      VStack(spacing: DesignTokens.Spacing.sm) {
        if viewModel.isMyIssuesFallback {
          Text("No open issues assigned to you")
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        } else {
          Text("No issues in this cycle")
            .font(.secondaryDefault)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, DesignTokens.Spacing.xl)
    } else {
      board
    }
  }

  private var board: some View {
    GeometryReader { geometry in
      boardColumns(height: max(geometry.size.height - DesignTokens.Spacing.lg, 200))
    }
    .focusable()
    .focused($isBoardFocused)
    .focusEffectDisabled()
    .onAppear { isBoardFocused = true }
    .onKeyPress(.return, phases: .down) { _ in
      guard let issue = viewModel.selectedIssue,
        issue.state.type != "completed", (linkedSessions[issue.identifier] ?? []).isEmpty
      else { return .ignored }
      start(issue)
      return .handled
    }
    .onKeyPress(.escape) {
      guard viewModel.selectedIssueID != nil else { return .ignored }
      viewModel.closeIssue()
      return .handled
    }
    .overlay {
      if viewModel.filteredIssues.isEmpty && !viewModel.issues.isEmpty {
        ContentUnavailableView(
          "No matching issues",
          systemImage: "line.3.horizontal.decrease.circle",
          description: Text("Try another filter or clear the search.")
        )
        .allowsHitTesting(false)
      }
    }
  }

  private func boardColumns(height: CGFloat) -> some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
        ForEach(viewModel.columns) { column in
          LinearBoardColumnView(
            column: column,
            selectedIssueID: viewModel.selectedIssueID,
            startingIssueIDs: viewModel.startingIssueIDs,
            linkedSessions: linkedSessions,
            onOpen: {
              viewModel.openIssue($0.id)
              isBoardFocused = true
            },
            onOpenSession: onOpenSession,
            onStart: start
          )
        }
      }
      .frame(height: height, alignment: .top)
      .padding(.horizontal, DesignTokens.Spacing.lg)
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let issue = viewModel.selectedIssue {
      LinearIssueDetailView(
        issue: issue,
        cycleName: viewModel.activeCycle?.displayName,
        isLoadingDetail: viewModel.isLoadingDetail,
        repositoryPath: $viewModel.repositoryPath,
        repositories: repositories,
        linkedSessions: linkedSessions[issue.identifier] ?? [],
        isStartingSession: viewModel.startingIssueIDs.contains(issue.id),
        onStart: { start(issue) },
        onOpenSession: onOpenSession,
        onClose: viewModel.closeIssue
      )
    }
  }

  private var isDetailPresented: Binding<Bool> {
    Binding(
      get: { viewModel.selectedIssueID != nil },
      set: { if !$0 { viewModel.closeIssue() } }
    )
  }

  private func start(_ issue: LinearIssue) {
    guard sessionRequest == nil, !viewModel.startingIssueIDs.contains(issue.id) else { return }
    let detailed = viewModel.selectedIssue?.id == issue.id ? viewModel.selectedIssue ?? issue : issue
    sessionRequest = TicketSessionRequest(
      id: detailed.id, key: detailed.identifier, title: detailed.title
    ) { provider, path in
      guard viewModel.beginStartingSession(for: detailed.id) else {
        return "A session is already starting for this ticket."
      }
      defer { viewModel.endStartingSession(for: detailed.id) }
      return await onStart(detailed, provider, path)
    }
  }
}

// MARK: - LinearConnectView

/// Empty state: enter an API key to connect.
private struct LinearConnectView: View {
  @Bindable var viewModel: LinearViewModel
  @State private var apiKey = ""
  @State private var isConnecting = false
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.lg) {
      Text("Connect Linear")
        .font(.secondaryLarge)
      VStack(spacing: DesignTokens.Spacing.sm) {
        SecureField("API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 340)
          .focused($isFocused)
          .onSubmit { connect() }
        HStack(spacing: DesignTokens.Spacing.sm) {
          Button("Connect") { connect() }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
          if let url = URL(string: "https://linear.app/settings/account/security") {
            Link("Create a key", destination: url)
              .font(.secondarySmall)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 80)
    .onAppear { isFocused = true }
  }

  private func connect() {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    isConnecting = true
    Task {
      await viewModel.connect(apiKey: key)
      isConnecting = false
    }
  }
}

// MARK: - LinearErrorView

private struct LinearErrorView: View {
  let title: String
  let message: String
  @Bindable var viewModel: LinearViewModel
  let showReconnect: Bool

  @State private var apiKey = ""

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.lg) {
      VStack(spacing: DesignTokens.Spacing.sm) {
        Label(title, systemImage: "exclamationmark.triangle")
          .font(.secondaryLarge)
        Text(message)
          .font(.secondaryDefault)
          .foregroundStyle(.secondary)
      }
      if showReconnect {
        VStack(spacing: DesignTokens.Spacing.sm) {
          SecureField("New API key", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
            .onSubmit { reconnect() }
          HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Connect") { reconnect() }
              .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Disconnect") { viewModel.disconnect() }
          }
        }
      } else {
        Button("Retry") { Task { await viewModel.load() } }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 80)
  }

  private func reconnect() {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    Task { await viewModel.connect(apiKey: key) }
  }
}

// MARK: - LinearBoardSkeleton

private struct LinearBoardSkeleton: View {
  @State private var isPulsing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let cardCounts = [3, 4, 2, 3]

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
      ForEach(cardCounts.indices, id: \.self) { column in
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          RoundedRectangle(cornerRadius: 3)
            .frame(width: 90, height: 10)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
          ForEach(0..<cardCounts[column], id: \.self) { _ in
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
              .frame(height: 84)
          }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: LinearBoardColumnView.width, alignment: .top)
      }
    }
    .foregroundStyle(Color.primary.opacity(isPulsing ? 0.07 : 0.04))
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { isPulsing = true }
    }
    .accessibilityLabel("Loading issues")
  }
}
