//
//  CommitChangesAction.swift
//  AgentHub
//
//  Commit review is a local, named-file operation. It never sends a terminal prompt.
//

import Foundation
import Observation

/// A per-session "one at a time" guard with a short cooldown, so a double
/// click sends one prompt.
@MainActor
final class SessionActionCooldown {
  private var activeSessionIDs: Set<String> = []

  /// False while the session's action is still cooling down.
  func begin(_ sessionID: String) -> Bool {
    activeSessionIDs.insert(sessionID).inserted
  }

  func end(_ sessionID: String) {
    activeSessionIDs.remove(sessionID)
  }

  func isActive(_ sessionID: String) -> Bool {
    activeSessionIDs.contains(sessionID)
  }
}

@MainActor
enum CommitChangesAction {
  static func title(fileCount: Int) -> String {
    "Review commit…"
  }
}

@MainActor
@Observable
final class CommitChangesReviewModel: Identifiable {
  enum Phase: Equatable {
    case preparing, prepared, executing, committed, failed, unconfirmed
  }
  let id = UUID()
  let sessionID: String
  let providerID: String
  let projectPath: String
  var message = ""
  private(set) var phase: Phase = .preparing
  private(set) var snapshot: CommitChangeSnapshot?
  private(set) var receipt: CommitChangesReceipt?
  private(set) var error: String?
  private let service: any CommitChangesServiceProtocol
  private var preparationStarted = false
  private var invalidated = false

  init(
    sessionID: String, providerID: String, projectPath: String,
    service: any CommitChangesServiceProtocol
  ) {
    self.sessionID = sessionID
    self.providerID = providerID
    self.projectPath = projectPath
    self.service = service
  }

  var canCommit: Bool {
    phase == .prepared && !invalidated && !(snapshot?.entries.isEmpty ?? true)
      && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func prepare() async {
    guard !preparationStarted else { return }
    preparationStarted = true
    do {
      let prepared = try await service.prepare(
        sessionID: sessionID, providerID: providerID, projectPath: projectPath)
      guard !invalidated else { return }
      guard prepared.sessionID == sessionID, prepared.providerID == providerID,
        prepared.requestedPath == projectPath
      else {
        throw CommitChangesError.unavailable(
          "The commit review belongs to a different session or folder. Open a new commit review.")
      }
      snapshot = prepared
      phase = .prepared
    } catch {
      self.error = error.localizedDescription
      phase = .failed
    }
  }

  /// Switching sessions before approval invalidates this review. Execution is
  /// already bound to its captured target and must finish reporting its result.
  func invalidate() {
    guard phase != .executing, phase != .committed else { return }
    invalidated = true
    error = "The session changed. Open a new commit review for the current session."
    phase = .failed
  }

  func commit() async {
    guard canCommit, let snapshot else { return }
    phase = .executing
    do {
      receipt = try await service.commit(snapshot: snapshot, message: message)
      phase = .committed
    } catch {
      self.error = error.localizedDescription
      if case CommitChangesError.unconfirmed = error {
        phase = .unconfirmed
      } else {
        phase = .failed
      }
    }
  }
}
