//
//  EmbeddedTerminalSurface.swift
//  AgentHub
//

import AppKit
import SwiftUI

public struct AccessorySessionPaneContext: Equatable, Sendable {
  public let provider: SessionProviderKind
  public let projectPath: String
  public let startedAt: Date

  public init(provider: SessionProviderKind, projectPath: String, startedAt: Date) {
    self.provider = provider
    self.projectPath = projectPath
    self.startedAt = startedAt
  }
}

@MainActor
public protocol EmbeddedTerminalSurface: AnyObject {
  var view: NSView { get }
  var currentProcessPID: Int32? { get }
  var onUserInteraction: (() -> Void)? { get set }
  var onRequestShowEditor: (() -> Void)? { get set }
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)? { get set }
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)? { get set }
  var workspaceCLIConfigurationProvider: ((SessionProviderKind) -> CLICommandConfiguration)? { get set }
  /// Called when the CLI process failed to launch (e.g. executable not found).
  /// The ViewModel uses this to mark the pending session as failed.
  var onCLILaunchFailed: (() -> Void)? { get set }

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?)
  func configure(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    initialInputText: String?,
    launchContext: String?,
    isDark: Bool,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?
  )
  func configureShell(projectPath: String, isDark: Bool, shellPath: String?)
  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration)
  func terminateProcess()
  func resetPromptDeliveryFlag()
  func sendPromptIfNeeded(_ prompt: String)
  func submitPromptImmediately(_ prompt: String) -> Bool
  func typeText(_ text: String)
  /// Types into the agent's own tab only, never an accessory or child tab.
  /// Chat actions (approve) use this; false when the agent tab is gone.
  func typeTextToAgentSession(_ text: String) -> Bool
  /// Presses Escape in the agent's own tab only. Approval deny uses this.
  func sendEscapeToAgentSession() -> Bool
  /// Set while an approval banner shows for this session: ⌘↩ in the terminal
  /// calls it instead of the newline/submit shortcut (`ApprovalShortcutRouting`).
  var approvalShortcutHandler: (() -> Void)? { get set }
  /// The last `maxRows` visible rows of the agent's own tab, for state the CLI
  /// only draws on screen (compacting). Nil when the backend cannot read text.
  func agentScreenTail(maxRows: Int) -> [String]?
  func typeInitialTextIfNeeded(_ text: String)
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?)
  func focus()
  func activeWorkingDirectory() -> String?
  func openAccessorySessionPane(
    provider: SessionProviderKind,
    cliConfiguration: CLICommandConfiguration,
    projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> AccessorySessionPaneContext?
  func markAccessorySession(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool
  func workspaceSessionDetectionContexts() -> [WorkspaceSessionDetectionContext]
  func markWorkspaceSession(
    contextID: String,
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool
  func openWorkspaceSurface(
    kind: WorkspaceTerminalLaunchKind,
    placement: WorkspaceSurfacePlacement,
    cliConfiguration: CLICommandConfiguration?,
    projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> WorkspaceSurfaceLaunchContext?
  @discardableResult
  func focusWorkspaceSession(
    provider: SessionProviderKind,
    sessionId: String
  ) -> Bool
  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot?
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot)
}

public extension EmbeddedTerminalSurface {
  /// Fail closed: a surface that does not know which tab is the agent's must
  /// not guess. Typing into "whatever is active" is how a child session gets
  /// the parent's approval. Backends with a protected agent tab override this.
  func typeTextToAgentSession(_ text: String) -> Bool {
    false
  }

  /// Fail closed, like `typeTextToAgentSession`.
  func sendEscapeToAgentSession() -> Bool {
    false
  }

  /// Backends without the hook keep ⌘↩ unchanged.
  var approvalShortcutHandler: (() -> Void)? {
    get { nil }
    set {}
  }

  /// Backends without screen access (Ghostty's public API only sends text).
  func agentScreenTail(maxRows: Int) -> [String]? {
    nil
  }

  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)? {
    get { nil }
    set {}
  }

  var workspaceCLIConfigurationProvider: ((SessionProviderKind) -> CLICommandConfiguration)? {
    get { nil }
    set {}
  }

  var onCLILaunchFailed: (() -> Void)? {
    get { nil }
    set {}
  }

  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    nil
  }

  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {}

  func activeWorkingDirectory() -> String? {
    nil
  }

  func openAccessorySessionPane(
    provider: SessionProviderKind,
    cliConfiguration: CLICommandConfiguration,
    projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> AccessorySessionPaneContext? {
    nil
  }

  func markAccessorySession(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool {
    false
  }

  func workspaceSessionDetectionContexts() -> [WorkspaceSessionDetectionContext] {
    []
  }

  func markWorkspaceSession(
    contextID: String,
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    origin: SessionRelationshipOrigin
  ) -> Bool {
    markAccessorySession(
      provider: provider,
      sessionId: sessionId,
      projectPath: projectPath,
      origin: origin
    )
  }

  func openWorkspaceSurface(
    kind: WorkspaceTerminalLaunchKind,
    placement: WorkspaceSurfacePlacement,
    cliConfiguration: CLICommandConfiguration?,
    projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> WorkspaceSurfaceLaunchContext? {
    nil
  }

  @discardableResult
  func focusWorkspaceSession(
    provider: SessionProviderKind,
    sessionId: String
  ) -> Bool {
    false
  }
}

public protocol EmbeddedTerminalSurfaceFactory {
  @MainActor
  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface
}

public struct DefaultEmbeddedTerminalSurfaceFactory: EmbeddedTerminalSurfaceFactory {
  private let ghosttyProvider: (@MainActor () -> any EmbeddedTerminalSurface)?

  /// - Parameter ghosttyProvider: Closure that builds a Ghostty-backed surface.
  ///   Wired by the app target after importing the `Ghostty` module. When
  ///   omitted (e.g. unit tests, or builds where the Ghostty module is absent),
  ///   selecting `.ghostty` silently falls back to the regular SwiftTerm
  ///   surface so core code keeps functioning standalone.
  public init(ghosttyProvider: (@MainActor () -> any EmbeddedTerminalSurface)? = nil) {
    self.ghosttyProvider = ghosttyProvider
  }

  public func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    switch backend {
    case .ghostty:
      if let ghosttyProvider {
        return ghosttyProvider()
      }
      return TerminalContainerView()
    case .regular:
      return TerminalContainerView()
    }
  }
}

extension TerminalContainerView: EmbeddedTerminalSurface {
  public var view: NSView { self }

  public func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {
    guard self.terminalSessionKey != terminalSessionKey || self.sessionViewModel !== sessionViewModel else { return }
    self.terminalSessionKey = terminalSessionKey
    self.sessionViewModel = sessionViewModel
  }

  public func focus() {
    focusActiveTerminal()
  }
}
