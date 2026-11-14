import Foundation

// MARK: - Core Models

public struct LinearTeam: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let key: String

  public init(id: String, name: String, key: String) {
    self.id = id
    self.name = name
    self.key = key
  }
}

public struct LinearWorkflowState: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  /// One of: `backlog`, `unstarted`, `started`, `completed`, `canceled`.
  public let type: String
  public let position: Double
  public let color: String

  public init(id: String, name: String, type: String, position: Double, color: String) {
    self.id = id
    self.name = name
    self.type = type
    self.position = position
    self.color = color
  }

  /// Display order: backlog < unstarted < started < completed. Canceled is hidden.
  public static func displayOrder(_ lhs: LinearWorkflowState, _ rhs: LinearWorkflowState) -> Bool {
    let typeOrder = ["backlog": 0, "unstarted": 1, "started": 2, "completed": 3]
    let lhsOrder = typeOrder[lhs.type] ?? 4
    let rhsOrder = typeOrder[rhs.type] ?? 4
    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
    return lhs.position < rhs.position
  }
}

public struct LinearCycle: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let number: Int
  public let name: String?
  public let startsAt: Date
  public let endsAt: Date

  public init(id: String, number: Int, name: String?, startsAt: Date, endsAt: Date) {
    self.id = id
    self.number = number
    self.name = name
    self.startsAt = startsAt
    self.endsAt = endsAt
  }

  public var displayName: String {
    name ?? "Cycle \(number)"
  }
}

public struct LinearUser: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let email: String?
  public let avatarUrl: String?

  public init(id: String, name: String, email: String? = nil, avatarUrl: String? = nil) {
    self.id = id
    self.name = name
    self.email = email
    self.avatarUrl = avatarUrl
  }
}

public struct LinearLabel: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let color: String

  public init(id: String, name: String, color: String) {
    self.id = id
    self.name = name
    self.color = color
  }
}

/// A Linear project: the board's project filter, and an issue's project.
public struct LinearProject: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  /// Hex colour, for example `#5e6ad2`. Nil when the query did not ask for it.
  public let color: String?

  public init(id: String, name: String, color: String? = nil) {
    self.id = id
    self.name = name
    self.color = color
  }

  /// Case- and diacritic-insensitive name order, the menu's order.
  public static func sortedByName(_ projects: [LinearProject]) -> [LinearProject] {
    projects.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
}

public struct LinearIssue: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let identifier: String
  public let title: String
  public let description: String?
  public let priority: Int
  public let priorityLabel: String
  public let state: LinearWorkflowState
  public let assignee: LinearUser?
  public let labels: [LinearLabel]
  public let url: String
  public let createdAt: Date
  /// Nil when the issue has no project.
  public let project: LinearProject?

  public init(
    id: String,
    identifier: String,
    title: String,
    description: String? = nil,
    priority: Int = 0,
    priorityLabel: String = "No priority",
    state: LinearWorkflowState,
    assignee: LinearUser? = nil,
    labels: [LinearLabel] = [],
    url: String = "",
    createdAt: Date = Date(),
    project: LinearProject? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.title = title
    self.description = description
    self.priority = priority
    self.priorityLabel = priorityLabel
    self.state = state
    self.assignee = assignee
    self.labels = labels
    self.url = url
    self.createdAt = createdAt
    self.project = project
  }

  private enum CodingKeys: String, CodingKey {
    case id, identifier, title, description, priority, priorityLabel, state, assignee, labels, url, createdAt, project
  }

  /// Labels come from GraphQL as `{ nodes: [...] }` but we store them flat.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    identifier = try container.decode(String.self, forKey: .identifier)
    title = try container.decode(String.self, forKey: .title)
    description = try container.decodeIfPresent(String.self, forKey: .description)
    priority = try container.decode(Int.self, forKey: .priority)
    priorityLabel = try container.decode(String.self, forKey: .priorityLabel)
    state = try container.decode(LinearWorkflowState.self, forKey: .state)
    assignee = try container.decodeIfPresent(LinearUser.self, forKey: .assignee)
    url = try container.decode(String.self, forKey: .url)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    project = try container.decodeIfPresent(LinearProject.self, forKey: .project)
    // Labels: try connection wrapper first, then plain array.
    if let connection = try? container.decode(LabelsConnection.self, forKey: .labels) {
      labels = connection.nodes
    } else {
      labels = (try? container.decode([LinearLabel].self, forKey: .labels)) ?? []
    }
  }

  private struct LabelsConnection: Decodable {
    let nodes: [LinearLabel]
  }

  /// The team key prefix (e.g. `WB` from `WB-12`).
  public var teamKey: String {
    String(identifier.split(separator: "-").first ?? "")
  }
}

// MARK: - GraphQL Response Wrappers

/// Generic wrapper for Linear GraphQL responses.
public struct LinearGraphQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
  public let data: T?
  public let errors: [LinearGraphQLError]?
}

public struct LinearGraphQLError: Decodable, Sendable {
  public let message: String
}

// MARK: - Query-specific response types

public struct ViewerResponse: Decodable, Sendable {
  public let viewer: LinearUser
}

public struct TeamsResponse: Decodable, Sendable {
  public let teams: TeamsConnection
}

public struct TeamsConnection: Decodable, Sendable {
  public let nodes: [LinearTeam]
}

public struct TeamCyclesResponse: Decodable, Sendable {
  public let team: TeamCyclesData
}

public struct TeamCyclesData: Decodable, Sendable {
  public let activeCycle: LinearCycle?
}

public struct WorkflowStatesResponse: Decodable, Sendable {
  public let workflowStates: WorkflowStatesConnection
}

public struct WorkflowStatesConnection: Decodable, Sendable {
  public let nodes: [LinearWorkflowState]
}

public struct CycleIssuesResponse: Decodable, Sendable {
  public let cycle: CycleIssuesData?
}

public struct CycleIssuesData: Decodable, Sendable {
  public let issues: IssuesConnection
}

public struct IssuesConnection: Decodable, Sendable {
  public let nodes: [LinearIssue]
}

public struct AssignedIssuesResponse: Decodable, Sendable {
  public let issues: IssuesConnection
}

/// A connection page's cursor info.
public struct LinearPageInfo: Decodable, Sendable {
  public let hasNextPage: Bool
  public let endCursor: String?

  /// The cursor of the next page, or nil on the last page.
  public var nextCursor: String? { hasNextPage ? endCursor : nil }
}

public struct TeamProjectsResponse: Decodable, Sendable {
  public let team: TeamProjectsData?
}

public struct TeamProjectsData: Decodable, Sendable {
  public let projects: ProjectsConnection
}

public struct ProjectsConnection: Decodable, Sendable {
  public let nodes: [LinearProject]
  public let pageInfo: LinearPageInfo
}

public struct ProjectIssuesResponse: Decodable, Sendable {
  public let issues: PagedIssuesConnection
}

public struct PagedIssuesConnection: Decodable, Sendable {
  public let nodes: [LinearIssue]
  public let pageInfo: LinearPageInfo
}

public struct IssueDetailResponse: Decodable, Sendable {
  public let issue: LinearIssue
}

public struct WorkflowStateTransitionResponse: Decodable, Sendable {
  public let issueUpdate: IssueUpdatePayload
}

public struct IssueUpdatePayload: Decodable, Sendable {
  public let success: Bool
}
