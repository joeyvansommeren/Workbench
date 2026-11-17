//
//  PendingHubSession.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

import Foundation

/// A session being started in the Hub's embedded terminal (no session ID yet)
/// Used when user clicks "Start in Hub" to track the pending session until Claude creates the session file
public struct PendingHubSession: Identifiable {
  public let origin: SessionLaunchOrigin?
  public let expectedSessionID: String?
  /// Recovery cannot safely attach a provider file to this launch.
  public var needsIdentification: Bool
  public var displayName: String { origin?.displayName ?? "Starting session" }
  public let id: UUID
  public let worktree: WorktreeBranch
  public let launchPath: String?
  public let startedAt: Date
  public let initialPrompt: String?
  /// In-memory retry input only; never stored in launch-origin metadata.
  public let retryPrompt: String?
  public let initialInputText: String?
  /// Curated context delivered out-of-band (system-prompt channel), never
  /// merged into the first user message.
  public let launchContext: String?
  public let dangerouslySkipPermissions: Bool
  public let permissionModePlan: Bool
  /// Provider-specific identifiers that already existed before this process was launched.
  /// Claude stores session IDs; Codex stores rollout file paths.
  public let existingSessionIdentifiers: Set<String>
  /// nil = no worktree flag; "" = --worktree (auto-name); non-empty = --worktree <name>
  public let worktreeName: String?
  /// Set when the launch fails or stops after an unsuccessful removal.
  /// The UI offers recovery instead of a spinner.
  public var isFailed: Bool
  /// A stopped launch whose saved record could not be removed. Kept in memory for retry.
  public var removalError: String?

  public init(
    worktree: WorktreeBranch,
    id: UUID = UUID(),
    startedAt: Date = Date(),
    origin: SessionLaunchOrigin? = nil,
    expectedSessionID: String? = nil,
    needsIdentification: Bool = false,
    launchPath: String? = nil,
    initialPrompt: String? = nil,
    retryPrompt: String? = nil,
    initialInputText: String? = nil,
    launchContext: String? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    existingSessionIdentifiers: Set<String> = [],
    worktreeName: String? = nil
  ) {
    self.id = id
    self.origin = origin
    self.expectedSessionID = expectedSessionID
    self.needsIdentification = needsIdentification
    self.worktree = worktree
    self.launchPath = launchPath
    self.startedAt = startedAt
    self.initialPrompt = initialPrompt
    self.retryPrompt = retryPrompt ?? initialPrompt
    self.initialInputText = initialInputText
    self.launchContext = launchContext
    self.dangerouslySkipPermissions = dangerouslySkipPermissions
    self.permissionModePlan = permissionModePlan
    self.existingSessionIdentifiers = existingSessionIdentifiers
    self.worktreeName = worktreeName
    self.isFailed = false
    self.removalError = nil
  }

  public var projectPath: String {
    let trimmed = launchPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return trimmed
    }
    return worktree.path
  }

  /// Creates a placeholder CLISession for use with MonitoringCardView
  public var placeholderSession: CLISession {
    CLISession(
      id: "pending-\(id.uuidString)",
      projectPath: projectPath,
      branchName: worktree.name,
      isWorktree: worktree.isWorktree,
      lastActivityAt: startedAt,
      messageCount: 0,
      isActive: true,
      slug: displayName
    )
  }
}
