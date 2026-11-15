import Foundation

enum SessionResultKind: String, Codable, CaseIterable, Sendable {
  case prototype, smallTweak, interaction, native, nonvisual
  var label: String {
    switch self {
    case .prototype: "Prototype"
    case .smallTweak: "Small change"
    case .interaction: "Interaction"
    case .native: "Native app"
    case .nonvisual: "Nonvisual change"
    }
  }
}

enum SessionProductDecision: String, Codable, Sendable {
  case none, changesRequested, accepted
}

enum SessionResultFreshness: String, Codable, Sendable {
  case unknown, current, stale
}

struct SessionResultDecisionSnapshot: Equatable, Sendable {
  let provider: SessionProviderKind
  let sessionID: String
  let resultRevision: UUID
  let contentIdentity: String?
  let decision: SessionProductDecision
  let decidedAt: Date?
  let freshness: SessionResultFreshness
}

struct SessionResultAlternative: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  var name: String
  var destination: String
}

struct SessionResult: Codable, Equatable, Identifiable, Sendable {
  var provider: SessionProviderKind
  var sessionID: String
  var projectPath: String
  var revision = UUID()
  var summary = ""
  var kind: SessionResultKind = .smallTweak
  var affectedTargets = ""
  var destination = ""
  var expectedState = ""
  var versionLabel = ""
  var alternatives: [SessionResultAlternative] = []
  var sourceIdentity: String?
  var decision: SessionProductDecision = .none
  var decidedAt: Date?
  var correction = ""
  var updatedAt = Date()

  var id: String { Self.key(provider: provider, sessionID: sessionID) }
  static func key(provider: SessionProviderKind, sessionID: String) -> String {
    SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID)
  }
  func matches(projectPath: String) -> Bool {
    URL(fileURLWithPath: self.projectPath).standardizedFileURL.path
      == URL(fileURLWithPath: projectPath).standardizedFileURL.path
  }
  func freshness(comparedTo identity: String?) -> SessionResultFreshness {
    guard let sourceIdentity, let identity else { return .unknown }
    return sourceIdentity == identity ? .current : .stale
  }
  func acceptance(comparedTo identity: String?) -> SessionResultDecisionSnapshot {
    SessionResultDecisionSnapshot(provider: provider, sessionID: sessionID,
      resultRevision: revision, contentIdentity: sourceIdentity, decision: decision,
      decidedAt: decidedAt, freshness: freshness(comparedTo: identity))
  }
  /// Editing the definition creates a different result. Previous acceptance must not carry across.
  mutating func revise(sourceIdentity: String?) {
    revision = UUID()
    self.sourceIdentity = sourceIdentity
    decision = .none
    decidedAt = nil
    updatedAt = Date()
  }
}
