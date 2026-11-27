import AgentWorkflowCore
import Foundation

public struct LinearQueueAccount: Codable, Equatable, Sendable {
  public let workspaceID: String
  public let userID: String

  public init(workspaceID: String, userID: String) {
    self.workspaceID = workspaceID
    self.userID = userID
  }

  public func identity(for issueID: String) throws -> OrchestratorIssueIdentity {
    let source = try OrchestratorSourceIdentity(
      trackerID: "linear", accountID: userID, scopeID: workspaceID)
    return try OrchestratorIssueIdentity(source: source, issueID: issueID)
  }
}

public struct LinearQueueIssue: Decodable, Equatable, Identifiable, Sendable {
  public let id: String
  public let identifier: String
  public let title: String
  public let teamID: String
  public let projectID: String?
  public let assigneeID: String?
  public let state: LinearWorkflowState
  public let revision: String
  public let priority: Double
  public let sortOrder: Double?
  public let isArchived: Bool
  public internal(set) var dependencies: LinearQueueDependencies

  enum CodingKeys: String, CodingKey {
    case id, identifier, title, team, project, assignee, state, updatedAt, priority, sortOrder, archivedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    identifier = try values.decode(String.self, forKey: .identifier)
    title = try values.decode(String.self, forKey: .title)
    teamID = try values.decode(LinearQueueReference.self, forKey: .team).id
    projectID = try values.decodeIfPresent(LinearQueueReference.self, forKey: .project)?.id
    assigneeID = try values.decodeIfPresent(LinearQueueReference.self, forKey: .assignee)?.id
    state = try values.decode(LinearWorkflowState.self, forKey: .state)
    revision = try values.decode(String.self, forKey: .updatedAt)
    priority = try values.decode(Double.self, forKey: .priority)
    sortOrder = try values.decodeIfPresent(Double.self, forKey: .sortOrder)
    isArchived = try values.decodeIfPresent(String.self, forKey: .archivedAt) != nil
    dependencies = .unknown
  }
}

public struct LinearQueueDependency: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case active
    case completed
    case canceled
    case unknown
  }

  public let issueID: String
  public let status: Status
}

public enum LinearQueueDependencies: Equatable, Sendable {
  case known([LinearQueueDependency])
  case unknown
}

public struct LinearQueueOmission: Equatable, Sendable {
  public enum Scope: Equatable, Sendable {
    case projectTeams
    case projectIssues
    case workflowStates(teamID: String)
    case missingTeam(teamID: String)
    case addedTeam(teamID: String)
    case unexpectedTeam(teamID: String)
  }

  public let scope: Scope
  public let failure: LinearAPIError
}

public enum LinearQueueCoverage: Codable, Equatable, Sendable {
  /// Linear can hide private teams and their issues without reporting an error.
  case accountVisible
  /// Every explicitly supplied team ID matched the visible project team list.
  case expectedTeamsVerified
}

/// Any known omission prevents capture even when visible-only scope is approved.
public struct LinearQueueProject: Equatable, Sendable {
  public let id: String
  public let account: LinearQueueAccount
  public let teams: [LinearTeam]
  public let coverage: LinearQueueCoverage
  public let workflowStates: [String: [LinearWorkflowState]]
  public let issues: [LinearQueueIssue]
  public let omissions: [LinearQueueOmission]
}

struct LinearQueueReference: Codable, Sendable { let id: String }

public enum LinearQueueError: Error, Equatable, Sendable {
  case accountChanged
  case incompleteProject
  case visibleScopeApprovalRequired
  case invalidSelection
  case operationConflict
}
