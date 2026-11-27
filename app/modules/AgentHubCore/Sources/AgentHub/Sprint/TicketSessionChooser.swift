import SwiftUI

struct TicketSessionProviderDescriptor {
  let id: String
  let name: String

  static let catalog = [
    Self(id: SessionProviderKind.claude.rawValue, name: SessionProviderKind.claude.agentDisplayName),
    Self(id: SessionProviderKind.codex.rawValue, name: SessionProviderKind.codex.agentDisplayName)
  ]
}

/// A descriptor remains visible when Workbench has no launch adapter for it.
struct TicketSessionProviderOption: Identifiable {
  let id: String
  let name: String
  let provider: SessionProviderKind?
  let isInstalled: Bool

  static func resolve(
    _ descriptors: [TicketSessionProviderDescriptor],
    adapter: (String) -> (provider: SessionProviderKind, isInstalled: Bool)?
  ) -> [Self] {
    descriptors.map { descriptor in
      let capability = adapter(descriptor.id)
      return Self(
        id: descriptor.id, name: descriptor.name,
        provider: capability?.provider, isInstalled: capability?.isInstalled == true)
    }
  }

  var unavailableReason: String? {
    guard let provider else { return "Unavailable in this version of Workbench." }
    return isInstalled ? nil : provider.notInstalledHelp
  }
}

struct TicketSessionRequest: Identifiable {
  let id: String
  let key: String
  let title: String
  let start: @MainActor (SessionProviderKind, String) async -> String?
}

@MainActor
@Observable
final class TicketSessionChooserModel {
  private(set) var options: [TicketSessionProviderOption] = []
  private(set) var hasCheckedAgents = false
  private(set) var isStarting = false
  private(set) var didStart = false
  private(set) var error: String?

  func refresh(_ options: [TicketSessionProviderOption]) {
    self.options = options
    hasCheckedAgents = true
  }

  func start(
    providerID: String,
    repositoryPath: String?,
    repositories: [SelectedRepository],
    readOptions: () -> [TicketSessionProviderOption],
    directoryExists: (String) -> Bool = TicketSessionChooserModel.directoryExists,
    launch: @MainActor (SessionProviderKind, String) async -> String?
  ) async -> Bool {
    guard !isStarting, !didStart else { return false }
    error = nil
    refresh(readOptions())
    guard let option = options.first(where: { $0.id == providerID }),
      let provider = option.provider, option.isInstalled
    else {
      error = options.first { $0.id == providerID }?.unavailableReason
        ?? "This agent is no longer available."
      return false
    }
    guard let repositoryPath else {
      error = "Choose a repository."
      return false
    }
    guard repositories.contains(where: { $0.path == repositoryPath }),
      directoryExists(repositoryPath)
    else {
      error = "This repository is no longer available. Choose another repository."
      return false
    }
    // Reserve before the first suspension. A success stays reserved until dismissal.
    isStarting = true
    defer { isStarting = false }
    error = await launch(provider, repositoryPath)
    didStart = error == nil
    if !didStart { refresh(readOptions()) }
    return didStart
  }

  nonisolated static func directoryExists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

struct TicketSessionChooser: View {
  let request: TicketSessionRequest
  let repositories: [SelectedRepository]
  let readOptions: () -> [TicketSessionProviderOption]
  let onStarted: (String) -> Void

  @State private var model = TicketSessionChooserModel()
  @State private var repositoryPath: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focus: Focus?
  @AccessibilityFocusState private var isErrorFocused: Bool

  fileprivate enum Focus: Hashable {
    case repository
    case provider(String)
    case cancel
  }

  init(
    request: TicketSessionRequest, repositories: [SelectedRepository],
    repositoryPath: String?, readOptions: @escaping () -> [TicketSessionProviderOption],
    onStarted: @escaping (String) -> Void
  ) {
    self.request = request
    self.repositories = repositories
    self.readOptions = readOptions
    self.onStarted = onStarted
    _repositoryPath = State(initialValue: repositoryPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
      ticketContext
      repositoryPicker
      agentChoices
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.circle")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityFocused($isErrorFocused)
          .accessibilityIdentifier("sprint.start.error")
      }
      footer
    }
    .padding(DesignTokens.Spacing.xl)
    .frame(width: DesignTokens.Width.sheet)
    .background(Color.wbSurfaceRaised)
    .accessibilityIdentifier("sprint.start.chooser")
    .task {
      model.refresh(readOptions())
      focus = repositoryPath == nil && !repositories.isEmpty ? .repository : .cancel
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.refresh(readOptions()) }
    }
    .onChange(of: model.error) { _, error in
      isErrorFocused = error != nil
    }
    .interactiveDismissDisabled(model.isStarting)
    .onKeyPress(.return, phases: .repeat) { _ in .handled }
    .onKeyPress(.return, phases: .down) { _ in
      guard case .provider(let id) = focus,
        let option = model.options.first(where: { $0.id == id }), canStart(option)
      else { return .ignored }
      start(id)
      return .handled
    }
  }

  private var ticketContext: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text("Choose an agent").wbText(.title3).accessibilityAddTraits(.isHeader)
      Text(request.key).wbText(.code).foregroundStyle(Color.wbTextSecondary)
      Text(request.title)
        .wbText(.body)
        .lineLimit(3)
        .help(request.title)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var repositoryPicker: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Picker("Repository", selection: $repositoryPath) {
        Text("Choose a repository").tag(String?.none)
        if let repositoryPath, !hasSelectedRepository {
          Text("Repository unavailable").tag(Optional(repositoryPath))
        }
        ForEach(repositories) { repository in
          Text(repository.name).tag(Optional(repository.path))
        }
      }
      .pickerStyle(.menu)
      .focused($focus, equals: .repository)
      .disabled(repositories.isEmpty || model.isStarting)
      .accessibilityIdentifier("sprint.start.repository")

      if repositories.isEmpty {
        Text("Add a repository in Sessions, then come back to this ticket.")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var hasSelectedRepository: Bool {
    repositories.contains { $0.path == repositoryPath }
  }

  private var agentChoices: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      if !model.hasCheckedAgents {
        ProgressView("Checking agents…")
          .controlSize(.small)
      } else if model.options.isEmpty {
        Text("No agents are available.")
          .wbText(.callout)
          .foregroundStyle(Color.wbTextSecondary)
      }
      ForEach(model.options) { option in
        TicketSessionAgentRow(
          option: option, canStart: canStart(option),
          focus: $focus, onStart: { start(option.id) },
          onCheckAgain: { model.refresh(readOptions()) })
      }
    }
    .disabled(model.isStarting)
  }

  private var footer: some View {
    HStack {
      if model.isStarting {
        ProgressView().controlSize(.small)
        Text("Starting session…").wbText(.callout)
      }
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }
        .buttonStyle(.wbSecondary)
        .keyboardShortcut(.cancelAction)
        .focused($focus, equals: .cancel)
        .disabled(model.isStarting)
        .accessibilityIdentifier("sprint.start.cancel")
    }
  }

  private func canStart(_ option: TicketSessionProviderOption) -> Bool {
    option.unavailableReason == nil && hasSelectedRepository && !model.isStarting && !model.didStart
  }

  private func start(_ providerID: String) {
    Task {
      let didStart = await model.start(
        providerID: providerID, repositoryPath: repositoryPath, repositories: repositories,
        readOptions: readOptions, launch: request.start)
      if didStart, let repositoryPath {
        onStarted(repositoryPath)
        dismiss()
      }
    }
  }
}

private struct TicketSessionAgentRow: View {
  let option: TicketSessionProviderOption
  let canStart: Bool
  let focus: FocusState<TicketSessionChooser.Focus?>.Binding
  let onStart: () -> Void
  let onCheckAgain: () -> Void

  @State private var showsSetup = false

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      HStack {
        Button("Start with \(option.name)", action: onStart)
          .buttonStyle(.wbSecondary)
          .disabled(!canStart)
          .focused(focus, equals: .provider(option.id))
          .accessibilityIdentifier("sprint.start.provider.\(option.id)")
        if option.unavailableReason != nil, let provider = option.provider {
          Button("Set up \(option.name)") { showsSetup = true }
            .buttonStyle(.wbPlain)
            .popover(isPresented: $showsSetup) {
              AgentSetupRecoveryView(provider: provider, onCheckAgain: onCheckAgain)
            }
        }
      }
      if let reason = option.unavailableReason {
        Text(reason).wbText(.callout).foregroundStyle(Color.wbTextSecondary)
      }
    }
    .onChange(of: option.isInstalled) { _, isInstalled in
      if isInstalled { showsSetup = false }
    }
  }
}
