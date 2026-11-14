//
//  AgentHubApp.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/11/26.
//

import AgentHubCore
import AgentHubGlobalSessionPanel
import AgentHubVoicePanel
import CoreText
import Ghostty
import SwiftUI
import UserNotifications

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events.
  /// Wires the Ghostty-aware terminal surface factory; `AgentHubCore` falls back
  /// to the regular SwiftTerm surface when no provider is supplied.
  let provider = AgentHubProvider(
    terminalSurfaceFactory: DefaultEmbeddedTerminalSurfaceFactory(
      ghosttyProvider: { AgentHubGhosttyTerminalSurface() }
    ),
    globalSessionControlPanelPresenterFactory: { provider, defaults in
      AppKitGlobalSessionControlPanelPresenter(provider: provider, defaults: defaults)
    },
    voiceHUDPresenterFactory: { provider, defaults in
      AppKitVoiceHUDPresenter(
        host: AgentHubVoiceHUDHost(provider: provider, defaults: defaults),
        engine: provider.realtimeVoiceEngine,
        configuration: .agentHub,
        defaults: defaults
      )
    }
  )

  /// Update controller for Sparkle auto-updates
  let updateController = UpdateController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NodeProcessGuardController.shared.start()
    // Double-clicks and window changes, logged with any freeze (layout-loop crash, CLAUDE.md).
    UIEventBreadcrumbs.install()
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().setNotificationCategories([
      GitHubCIFailureNotification.category()
    ])
    registerBundledFonts()
    // Sweep any approval hooks left installed by a previous crash/force-quit
    // before sessions start restoring. Re-installs happen naturally as each
    // session begins monitoring.
    provider.reconcileClaudeHooksOnLaunch()
    provider.cleanupOrphanedProcesses()
    provider.purgeStaleWindowAutosaveDefaults()
    provider.startWorktreeLaunchRequestMonitoring()
    provider.globalSessionControlPanelCoordinator.start()
    provider.voiceControlCoordinator.start()
  }

  /// Register all bundled fonts (Geist, GeistMono, JetBrains Mono)
  private func registerBundledFonts() {
    let otfFonts = [
      "Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold",
      "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold", "GeistMono-Bold",
      "SourceCodePro-Regular",
      "InterDisplay-Regular", "InterDisplay-Medium", "InterDisplay-SemiBold", "InterDisplay-Bold",
    ]
    let ttfFonts = [
      "JetBrainsMono-Regular", "JetBrainsMono-Medium",
      "JetBrainsMono-SemiBold", "JetBrainsMono-Bold",
      "FiraCode-Regular",
      "CascadiaMono-Regular",
    ]
    for name in otfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    for name in ttfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    provider.stopWorktreeLaunchRequestMonitoring()
    provider.globalSessionControlPanelCoordinator.stop()
    provider.voiceControlCoordinator.stop()
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
    // Stop all dev servers spawned for web preview
    DevServerManager.shared.stopAllServers()
    // Close pooled MCP clients, including stdio subprocesses and HTTP sessions.
    provider.shutdownMCPAppDiscoveryService()
    // Remove every approval hook we installed and clear claims so external
    // Claude Code sessions after quit run vanilla.
    provider.flushClaudeHooksOnTerminate()
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let ciFailurePayload = GitHubCIFailureNotificationPayload(
      userInfo: response.notification.request.content.userInfo
    )
    let isFixCIAction = response.actionIdentifier == GitHubCIFailureNotification.fixActionIdentifier
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
      if let ciFailurePayload, let providerKind = ciFailurePayload.providerKind {
        provider.globalSessionSelectionRouter.select(
          providerKind: providerKind,
          sessionId: ciFailurePayload.sessionId,
          projectPath: ciFailurePayload.projectPath
        )
        provider.gitHubCIFailureActionRouter.request(
          payload: ciFailurePayload,
          action: isFixCIAction ? .fixCI : .openGitHubPanel
        )
      }
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}

// MARK: - App

@main
struct AgentHubApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  /// Which window root this process uses. Read once: the root view, the menus
  /// and the window style stay fixed until relaunch. The launch argument
  /// `-com.agenthub.features.appleShell YES|NO` overrides it (argument domain).
  private let usesAppleShell: Bool

  init() {
    usesAppleShell = AppleShellLaunchFlag.isEnabled
    // Must run before any terminal/watcher/subprocess spawns: Finder-launched
    // apps inherit a 256 open-file soft limit, which a busy hub exhausts.
    FileDescriptorLimits.raiseSoftLimit()
    // Launched from inside a Claude Code session? Drop its identity markers, or
    // every Claude session started here skips its transcript and never resolves.
    InheritedAgentSessionEnvironment.scrubFromProcess()
    // Logs beach balls with recent activity (category "Performance").
    MainThreadStallMonitor.shared.start()
  }

  var body: some Scene {
    mainWindow

    MenuBarExtra(
      isInserted: Binding(
        get: { appDelegate.provider.displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      AgentHubMenuBarContent()
        .environment(\.agentHub, appDelegate.provider)
    } label: {
      AgentHubMenuBarLabel(provider: appDelegate.provider)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .agentHub(appDelegate.provider)
        .font(.geist(size: 13))
    }

    #if DEBUG
    Window("Component Gallery", id: "component-gallery") {
      ComponentGallery()
    }
    .defaultSize(width: 1100, height: 800)
    .commandsRemoved()
    #endif
  }

  /// One window group for both roots: scenes cannot branch at this deployment
  /// target, but views and commands can.
  private var mainWindow: some Scene {
    WindowGroup {
      if usesAppleShell {
        WorkbenchShellView()
          .agentHub(appDelegate.provider)
          // Default for any Text without an explicit style: Inter Display body.
          .font(WorkbenchTextStyle.body.font())
      } else {
        AgentHubOperationsView()
          .agentHub(appDelegate.provider)
          // Default for any Text without an explicit font, so nothing falls back to SF Pro.
          .font(.geist(size: 13))
      }
    }
    // Both roots draw their own top bar. The new shell's is a title band
    // (height from ShellTitleBarMetrics; AgentHubCore Shell/README.md).
    .windowStyle(.hiddenTitleBar)
    .commands {
      if usesAppleShell {
        ShellCommands()
      } else {
        LegacyWorkspaceCommands()
      }

      #if DEBUG
      ComponentGalleryCommands()
      #endif
    }
  }
}

/// The legacy root's menus, unchanged: View › Toggle Sidebar and Navigate.
private struct LegacyWorkspaceCommands: Commands {
  var body: some Commands {
    // Split views have no toolbar toggle; View › Toggle Sidebar (⌃⌘S) replaces it.
    SidebarCommands()

    CommandMenu("Navigate") {
      Button("Workflows") {
        AgentHubAppCommand.selectWorkspace(.workflows)
      }
      .keyboardShortcut("1", modifiers: .command)

      Button("Reviews") {
        AgentHubAppCommand.selectWorkspace(.reviews)
      }
      .keyboardShortcut("2", modifiers: .command)

      Button("Sessions") {
        AgentHubAppCommand.selectWorkspace(.sessions)
      }
      .keyboardShortcut("3", modifiers: .command)

      Button("Sprint") {
        AgentHubAppCommand.selectWorkspace(.sprint)
      }
      .keyboardShortcut("4", modifiers: .command)

      Button("Linear") {
        AgentHubAppCommand.selectWorkspace(.linear)
      }
      .keyboardShortcut("5", modifiers: .command)

      Divider()

      Button("Resume Session by ID…") {
        AgentHubAppCommand.resumeSessionByID()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])

      Button("Archive Current Session") {
        AgentHubAppCommand.archiveCurrentSession()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
    }
  }
}

#if DEBUG
/// Debug builds only: Window › Component Gallery (⌥⌘G) opens the P2 component gallery.
/// A `Window` scene with an id is not reachable without an explicit command.
private struct ComponentGalleryCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button("Component Gallery") { openWindow(id: "component-gallery") }
        .keyboardShortcut("g", modifiers: [.command, .option])
    }
  }
}
#endif
