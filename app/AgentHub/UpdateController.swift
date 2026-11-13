//
//  UpdateController.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/23/26.
//

import Combine
import Sparkle
import SwiftUI

/// Controller for managing Sparkle software updates
@Observable
@MainActor
final class UpdateController {
  private let updaterController: SPUStandardUpdaterController
  private var cancellable: AnyCancellable?

  var canCheckForUpdates = false

  init() {
    // Workbench has no release feed of its own. The upstream feed would replace
    // this fork with upstream builds, so the updater never starts. Pull upstream
    // changes with git instead (see WORKBENCH.md).
    updaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    // Observe when updates can be checked
    cancellable = updaterController.updater.publisher(for: \.canCheckForUpdates)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] canCheck in
        self?.canCheckForUpdates = canCheck
      }
  }

  /// Manually check for updates
  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  /// The underlying updater for advanced configuration
  var updater: SPUUpdater {
    updaterController.updater
  }
}

// MARK: - SwiftUI View for Check for Updates Menu Item

struct CheckForUpdatesView: View {
  var updateController: UpdateController

  var body: some View {
    Button("Check for Updates...") {
      updateController.checkForUpdates()
    }
    .disabled(!updateController.canCheckForUpdates)
  }
}
