//
//  ShellOverlays.swift
//  AgentHub
//
//  The new shell's overlays, attached once at the window root: the command
//  palette (⌘K, toolbar Search) and the New session sheet (⌘N, toolbar "+",
//  palette, branch-row "+"). Per window, like the rest of the shell state.
//

import SwiftUI

/// Per-window overlay state. Only the palette lives here; the New session
/// request lives on the window's `SessionsActionCoordinator`, so any view with
/// `ShellSessionActions` can ask for the sheet.
@MainActor
@Observable
final class ShellOverlayModel {
  private(set) var isPaletteOpen = false

  func openPalette() {
    guard !isPaletteOpen else { return }
    isPaletteOpen = true
    MainThreadStallMonitor.breadcrumb("palette: open")
  }

  func closePalette() {
    guard isPaletteOpen else { return }
    isPaletteOpen = false
    MainThreadStallMonitor.breadcrumb("palette: close")
  }

  func togglePalette() {
    isPaletteOpen ? closePalette() : openPalette()
  }
}

/// Presents the palette and the New session sheet over the shell, and runs
/// what the palette picks.
struct ShellOverlayHost: ViewModifier {
  let agentHub: AgentHubProvider
  let overlays: ShellOverlayModel
  let shellModel: WorkbenchShellModel
  @Bindable var coordinator: SessionsActionCoordinator
  let navigationModel: SessionNavigationModel
  let onNewSession: () -> Void
  let onResumeSessionByID: () -> Void

  @Environment(\.openSettings) private var openSettings
  /// Set by "More options…"; presented once the sheet is gone (two sheets
  /// cannot show at once).
  @State private var legacyLauncherFollowUp: MultiSessionLaunchViewModel?

  func body(content: Content) -> some View {
    content
      .overlay {
        ZStack(alignment: .top) {
          if overlays.isPaletteOpen {
            Color.wbSurfaceScrim
              .ignoresSafeArea()
              .onTapGesture { overlays.closePalette() }
              .transition(.opacity)
            WorkbenchCommandPalette(
              sessions: paletteSessions,
              pullRequests: palettePullRequests,
              onRun: run,
              onClose: { overlays.closePalette() }
            )
            .padding(.top, 104)
            // Opacity only, no scale (Joey's rule). A 120 ms fade in and out
            // softens the scrim without delaying typing: the field takes focus
            // on the first frame. Instant under Reduce Motion.
            .transition(.opacity)
          }
        }
        .animation(.wbAnimation(DesignTokens.Motion.fast), value: overlays.isPaletteOpen)
      }
      .sheet(item: $coordinator.newSessionSheetRequest, onDismiss: presentLegacyLauncherIfRequested) {
        request in
        NewSessionSheetContainer(
          model: request.model,
          onCancel: { coordinator.newSessionSheetRequest = nil },
          onMoreOptions: {
            request.model.applyToLaunchViewModel()
            legacyLauncherFollowUp = request.model.launchViewModel
            coordinator.newSessionSheetRequest = nil
          },
          onLaunchStarted: {
            shellModel.select(.sessions)
            coordinator.newSessionSheetRequest = nil
          }
        )
        .wbRedrawsOnPaletteChange()
      }
  }

  private func presentLegacyLauncherIfRequested() {
    guard let launchViewModel = legacyLauncherFollowUp else { return }
    legacyLauncherFollowUp = nil
    coordinator.startSessionSheetContext = StartSessionSheetContext(launchViewModel: launchViewModel)
  }

  // MARK: Palette inputs

  private var paletteSessions: [CommandPaletteSessionInput] {
    let claude = agentHub.claudeSessionsViewModel
    let codex = agentHub.codexSessionsViewModel
    return ShellSessionItems.items(claude: claude, codex: codex).map { item in
      let viewModel = item.providerKind == .claude ? claude : codex
      return CommandPaletteSessionInput(
        itemID: item.id,
        title: viewModel.displayName(for: item.session),
        branch: item.session.branchName ?? item.session.projectName,
        status: item.status,
        isPending: item.isPending
      )
    }
  }

  private var palettePullRequests: [CommandPalettePullRequestInput] {
    agentHub.gitHubReviewsViewModel.pullRequests.map {
      CommandPalettePullRequestInput(
        id: $0.id,
        title: $0.title,
        number: $0.number,
        repositoryName: $0.repositoryName,
        repositoryNameWithOwner: $0.repositoryNameWithOwner
      )
    }
  }

  // MARK: Running a pick

  private func run(_ target: CommandPaletteTarget) {
    overlays.closePalette()
    // Next turn: let the palette leave before a sheet or Settings opens.
    DispatchQueue.main.async { perform(target) }
  }

  private func perform(_ target: CommandPaletteTarget) {
    switch target {
    case .session(let itemID):
      shellModel.select(.sessions)
      navigationModel.selectSession(itemID)
      navigationModel.scrollToSessionId = itemID
    case .pullRequest(_, let nameWithOwner, let number):
      let parts = nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
      if parts.count == 2 {
        agentHub.gitHubReviewsViewModel.focusPullRequest(owner: parts[0], repository: parts[1], number: number)
      }
      shellModel.select(.reviews)
    case .destination(let destination):
      shellModel.select(destination)
    case .command(let command):
      perform(command)
    }
  }

  private func perform(_ command: CommandPaletteCommand) {
    switch command {
    case .newSession: onNewSession()
    case .resumeSessionByID: onResumeSessionByID()
    case .toggleSidePanel: shellModel.toggleSidePanel()
    case .toggleSidebar: shellModel.toggleSidebar()
    case .openSettings: openSettings()
    case .switchAppearance:
      let next = WorkbenchAppearanceController.toggledAppearance(
        currentlyDark: WorkbenchAppearanceController.isShowingDark
      )
      MainThreadStallMonitor.breadcrumb("appearance: \(next.rawValue)")
      // One window crossfade instead of a brightness cut (motion plan item 13).
      ThemeCrossfade.perform(in: NSApp.keyWindow) {
        WorkbenchAppearanceController.selectAppearance(next)
      }
    }
  }
}

/// Closes the sheet when a launch starts: progress then shows in the window,
/// as with the legacy launcher.
private struct NewSessionSheetContainer: View {
  let model: NewSessionSheetModel
  let onCancel: () -> Void
  let onMoreOptions: () -> Void
  let onLaunchStarted: () -> Void

  var body: some View {
    NewSessionSheet(model: model, onCancel: onCancel, onMoreOptions: onMoreOptions)
      .onChange(of: model.launchViewModel.isLaunching) { wasLaunching, isLaunching in
        if !wasLaunching, isLaunching { onLaunchStarted() }
      }
  }
}
