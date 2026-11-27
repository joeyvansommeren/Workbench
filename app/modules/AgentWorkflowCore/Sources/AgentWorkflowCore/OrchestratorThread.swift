import Foundation

public enum OrchestratorThreadRole: String, Codable, Sendable {
  case orchestrator, ticketCoordinator, implementer, reviewer
}

public enum OrchestratorThreadCloseReason: String, Codable, Sendable {
  case finished, cancelled, failed
}

public enum OrchestratorThreadActivity: String, Sendable {
  case verifiedWorking, idle, unknown
}

public enum OrchestratorThreadVisibility: Equatable, Sendable {
  case open, active, closed(OrchestratorThreadCloseReason)
}

/// A thread belongs to a run independently of the terminal accessory graph.
public struct OrchestratorThread: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let runID: UUID
  public let itemID: UUID?
  public let role: OrchestratorThreadRole
  public let provider: AgentProviderID
  public let pendingLaunchID: UUID
  public private(set) var session: OrchestratorSessionIdentity?
  public private(set) var closeReason: OrchestratorThreadCloseReason?

  public init(
    id: UUID, runID: UUID, itemID: UUID? = nil, role: OrchestratorThreadRole,
    provider: AgentProviderID, pendingLaunchID: UUID
  ) throws {
    try requireOrchestratorIdentifier(provider.rawValue, field: "provider")
    guard (itemID == nil) == (role == .orchestrator) else {
      throw OrchestratorThreadError.invalidOwner
    }
    self.id = id
    self.runID = runID
    self.itemID = itemID
    self.role = role
    self.provider = provider
    self.pendingLaunchID = pendingLaunchID
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: values.decode(UUID.self, forKey: .id),
      runID: values.decode(UUID.self, forKey: .runID),
      itemID: values.decodeIfPresent(UUID.self, forKey: .itemID),
      role: values.decode(OrchestratorThreadRole.self, forKey: .role),
      provider: values.decode(AgentProviderID.self, forKey: .provider),
      pendingLaunchID: values.decode(UUID.self, forKey: .pendingLaunchID))
    if let session = try values.decodeIfPresent(OrchestratorSessionIdentity.self, forKey: .session) {
      try bind(pendingLaunchID: pendingLaunchID, session: session)
    }
    closeReason = try values.decodeIfPresent(OrchestratorThreadCloseReason.self, forKey: .closeReason)
  }

  /// A caller confirms that the provider found this session for the pending launch.
  public mutating func bind(
    pendingLaunchID: UUID, session: OrchestratorSessionIdentity
  ) throws {
    guard self.pendingLaunchID == pendingLaunchID,
      session.provider.rawValue.utf8.elementsEqual(provider.rawValue.utf8)
    else { throw OrchestratorThreadError.bindingMismatch }
    if let existing = self.session {
      guard existing == session else { throw OrchestratorThreadError.bindingMismatch }
      return
    }
    self.session = session
  }

  public mutating func close(_ reason: OrchestratorThreadCloseReason) throws {
    guard closeReason == nil || closeReason == reason else { throw OrchestratorThreadError.closed }
    closeReason = reason
  }

  /// Supply fresh activity evidence from the identified session. Unknown stays open.
  public func visibility(currentActivity: OrchestratorThreadActivity) -> OrchestratorThreadVisibility {
    if let closeReason { return .closed(closeReason) }
    return session != nil && currentActivity == .verifiedWorking ? .active : .open
  }
}

public enum OrchestratorThreadError: Error, Equatable, Sendable {
  case invalidOwner
  case bindingMismatch
  case closed
  case missing(UUID)
  case conflict(UUID)
  case mainThreadAlreadyOpen(UUID)
}
