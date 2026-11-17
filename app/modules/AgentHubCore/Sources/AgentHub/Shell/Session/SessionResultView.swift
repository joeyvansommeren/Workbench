import SwiftUI

struct SessionResultView: View {
  let session: CLISession
  let provider: SessionProviderKind
  private let agentHub: AgentHubProvider?
  private let library: SessionResultLibrary
  private let sessionViewModel: CLISessionsViewModel
  private let attentionModel: SessionAttentionModel
  let onTerminal: () -> Void
  let onFiles: () -> Void
  let filesActionLabel: String
  let onChecks: () -> Void
  @State private var model: SessionResultViewModel
  @State private var editing = false
  @State private var showingFinish = false
  @State private var correction = ""
  @State private var alternativeID: UUID?

  init(session: CLISession, provider: SessionProviderKind, agentHub: AgentHubProvider,
    filesActionLabel: String = "Files", onTerminal: @escaping () -> Void,
    onFiles: @escaping () -> Void, onChecks: @escaping () -> Void) {
    self.init(session: session, provider: provider,
      library: agentHub.sessionResultLibrary,
      sessionViewModel: provider == .claude ? agentHub.claudeSessionsViewModel : agentHub.codexSessionsViewModel,
      attentionModel: agentHub.sessionAttentionModel,
      model: SessionResultViewModel(recipeStore: agentHub.metadataStore),
      agentHub: agentHub, filesActionLabel: filesActionLabel,
      onTerminal: onTerminal, onFiles: onFiles, onChecks: onChecks)
  }

  /// Inject the owning services so previews and native layout tests do not start an application provider.
  init(session: CLISession, provider: SessionProviderKind, library: SessionResultLibrary,
    sessionViewModel: CLISessionsViewModel, attentionModel: SessionAttentionModel,
    model: SessionResultViewModel, agentHub: AgentHubProvider? = nil,
    filesActionLabel: String = "Files", onTerminal: @escaping () -> Void,
    onFiles: @escaping () -> Void, onChecks: @escaping () -> Void) {
    self.session = session
    self.provider = provider
    self.agentHub = agentHub
    self.library = library
    self.sessionViewModel = sessionViewModel
    self.attentionModel = attentionModel
    self.filesActionLabel = filesActionLabel
    self.onTerminal = onTerminal
    self.onFiles = onFiles
    self.onChecks = onChecks
    _model = State(initialValue: model)
  }

  private var key: String { SessionResult.key(provider: provider, sessionID: session.id) }
  private var result: SessionResult? {
    guard let record = library.records[key], record.matches(projectPath: session.projectPath) else { return nil }
    return record
  }
  private var draft: SessionResult {
    SessionResultDraft.make(provider: provider, sessionID: session.id, projectPath: session.projectPath,
      state: sessionViewModel.monitorStates[session.id], recipe: model.recipe)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        if let result { definition(result) }
        else { unrecordedResult }
        if let error = model.error ?? library.loadError {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 10) {
            Button("Retry opening result") {
              let destination = result?.alternatives.first { $0.id == alternativeID }?.destination
              Task { await model.open(result: result ?? draft, destination: destination) }
            }
            .disabled(model.isOpening)
            Button("Edit launch recipe") { editing = true }
          }
        }
        if let destination = model.restartDestination {
          Button("Restart Workbench server") {
            Task { await model.open(result: result ?? draft, destination: destination, restart: true) }
          }
          .disabled(model.isOpening)
        }
        if let message = model.launchMessage { Text(message).foregroundStyle(.secondary) }
        Divider()
        ViewThatFits(in: .horizontal) {
          HStack { navigationButtons }.fixedSize(horizontal: true, vertical: false)
          VStack(alignment: .leading, spacing: 10) { navigationButtons }
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color.wbSurfaceContent)
    .task(id: key) { await library.load(); await model.load(projectPath: session.projectPath) }
    .onChange(of: sessionViewModel.monitorStates[session.id]?.lastActivityAt) { _, _ in
      model.invalidateSource()
    }
    .onChange(of: sessionViewModel.localDiffSummary(for: session.projectPath)) { _, _ in
      model.invalidateSource()
    }
    .sheet(isPresented: $editing) {
      SessionResultEditor(result: result ?? draft, recipe: model.recipe ?? model.suggestedRecipe,
        repositoryPath: model.source?.repositoryPath ?? session.projectPath) { definition, recipe in
          await model.save(definition, recipe: recipe, library: library)
        }
    }
    .sheet(isPresented: $showingFinish) {
      if let agentHub {
        FinishSummarySheet(session: session, provider: provider,
          acceptance: result?.acceptance(comparedTo: model.source?.identity), agentHub: agentHub)
      }
    }
  }

  private var unrecordedResult: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !draft.summary.isEmpty {
        Text("Latest agent report").font(.headline)
        Text(draft.summary).textSelection(.enabled)
        Text("Reported by the agent. Not verified or accepted.").font(.caption).foregroundStyle(.secondary)
      } else {
        Text("No change report received").font(.title3)
        Text("Record what changed when the result is ready.").foregroundStyle(.secondary)
      }
      if !draft.affectedTargets.isEmpty {
        Text("Files mentioned in observed edits").font(.headline)
        Text(draft.affectedTargets).font(.callout).textSelection(.enabled)
      }
      if let changes = sessionViewModel.localDiffSummary(for: session.projectPath) {
        Button("\(filesActionLabel) · \(changes.fileCount) changed · +\(changes.additions) −\(changes.deletions)", action: onFiles)
      }
      if !draft.destination.isEmpty {
        Text(draft.destination).font(.callout).textSelection(.enabled)
        Button(model.isOpening ? "Opening…" : draft.kind == .native ? "Reveal native build" : "Open result") { Task { await model.open(result: draft) } }
          .buttonStyle(.borderedProminent).disabled(model.isOpening)
        Text("Agent or saved destination. Check its route, state and version.").font(.caption).foregroundStyle(.secondary)
      }
      Button("Record or edit result") { editing = true }
      Text(attentionModel.checksLabel(for: key)).font(.callout)
    }
  }

  @ViewBuilder
  private var navigationButtons: some View {
    Button("Terminal", action: onTerminal)
    Button(filesActionLabel, action: onFiles)
    Button("Checks", action: onChecks)
    Button("Finish summary") { showingFinish = true }.disabled(agentHub == nil)
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack { headerContents }.fixedSize(horizontal: true, vertical: false)
      VStack(alignment: .leading, spacing: 10) { headerContents }
    }
  }

  @ViewBuilder
  private var headerContents: some View {
    Text("Result").font(.title2.weight(.semibold))
    Button("Refresh evidence") { Task { await model.load(projectPath: session.projectPath) } }
    if result != nil { Button("Edit result") { editing = true } }
  }

  private func definition(_ result: SessionResult) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(result.kind.label).font(.subheadline).foregroundStyle(.secondary)
      Text(result.summary).font(.title3).textSelection(.enabled)
      if !result.affectedTargets.isEmpty { Text(result.affectedTargets).textSelection(.enabled) }
      sourceStatus(result)
      if !result.versionLabel.isEmpty { Text("Version label: \(result.versionLabel)").foregroundStyle(.secondary) }
      if result.kind == .native {
        Text("Reveals the saved .app build in Finder. Use the Simulator action for mobile launch. External build folders are unsupported.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("The running page or build version is not verified.").font(.callout).foregroundStyle(.secondary)
      let expectedState = result.expectedState.isEmpty ? model.recipe?.expectedState ?? "" : result.expectedState
      if !expectedState.isEmpty {
        Text("Starting state and steps").font(.headline)
        Text(expectedState).textSelection(.enabled)
        Text("These steps are manual. A successful health check does not verify login, modal or component state.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if result.kind == .prototype, !result.alternatives.isEmpty {
        Picker("Alternative", selection: $alternativeID) {
          Text("Choose an alternative").tag(nil as UUID?)
          ForEach(result.alternatives) { Text($0.name).tag(Optional($0.id)) }
        }
      }
      if result.kind != .nonvisual || !result.destination.isEmpty {
        Button(model.isOpening ? "Opening…" : result.kind == .native ? "Reveal native build" : "Open result") {
          let destination = result.alternatives.first { $0.id == alternativeID }?.destination
          Task { await model.open(result: result, destination: destination) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isOpening || (result.kind == .prototype && !result.alternatives.isEmpty && alternativeID == nil))
        Text(result.kind == .native ? "Selects the exact build in Finder." : "Opens the exact destination in its app or browser.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(attentionModel.checksLabel(for: key)).font(.callout)
      decision(result)
    }
  }

  private func sourceStatus(_ result: SessionResult) -> some View {
    let freshness = result.freshness(comparedTo: model.source?.identity)
    return Label(freshness == .stale ? "Source changed since this result was recorded"
      : freshness == .current ? "Last source check matches the recorded content" : "Source version not verified",
      systemImage: freshness == .stale ? "exclamationmark.triangle" : "doc.text.magnifyingglass")
      .foregroundStyle(freshness == .stale ? Color.orange : Color.secondary)
  }

  private func decision(_ result: SessionResult) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()
      if result.decision == .accepted {
        Text("Recorded result accepted · \(result.decidedAt?.formatted() ?? "Time not recorded")")
        if result.freshness(comparedTo: model.source?.identity) != .current {
          Text("Current source is not confirmed. Refresh evidence before relying on this acceptance.")
            .foregroundStyle(.orange)
        }
        Text("Acceptance covers the recorded result. It does not approve publishing or cleanup.")
          .font(.caption).foregroundStyle(.secondary)
      } else if result.decision == .changesRequested {
        Text("Changes requested").font(.headline)
        Text(result.correction)
      }
      TextField("Correction for this result", text: $correction, axis: .vertical).lineLimit(2...5)
      VStack(alignment: .leading, spacing: 10) {
        Button("Save correction") {
          Task { await model.decide(.changesRequested, result: result, correction: correction, library: library) }
        }.disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Copy correction") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString("Result \(result.revision): \(result.destination)\n\(correction)", forType: .string)
        }.disabled(correction.isEmpty)
        Button("Accept recorded result") {
          Task { await model.decide(.accepted, result: result, library: library) }
        }.disabled(result.freshness(comparedTo: model.source?.identity) == .stale)
      }
      Text("Corrections stay here until you send them to the agent.").font(.caption).foregroundStyle(.secondary)
    }
  }
}
