import Foundation

// MARK: - Protocols

public protocol LinearIssueReading: Sendable {
  func viewer() async throws -> LinearUser
  func teams() async throws -> [LinearTeam]
  func activeCycle(teamID: String) async throws -> LinearCycle?
  func workflowStates(teamID: String) async throws -> [LinearWorkflowState]
  func cycleIssues(cycleID: String) async throws -> [LinearIssue]
  func assignedIssues(userID: String) async throws -> [LinearIssue]
  /// The team's projects that are not completed or canceled, by name.
  func projects(teamID: String) async throws -> [LinearProject]
  /// Open issues (not completed or canceled) of a project, limited to one team.
  func projectIssues(projectID: String, teamID: String) async throws -> [LinearIssue]
  func issue(id: String) async throws -> LinearIssue
}

public protocol LinearIssueTransitioning: Sendable {
  func transitionIssue(id: String, stateID: String) async throws
}

public typealias LinearService = LinearIssueReading & LinearIssueTransitioning

// MARK: - GraphQL Queries

enum LinearGraphQL {
  static let viewer = """
    query { viewer { id name email avatarUrl } }
    """

  static let teams = """
    query { teams { nodes { id name key } } }
    """

  static func activeCycle(teamID: String) -> String {
    """
    query { team(id: "\(teamID)") { activeCycle { id number name startsAt endsAt } } }
    """
  }

  static func workflowStates(teamID: String) -> String {
    """
    query { workflowStates(filter: { team: { id: { eq: "\(teamID)" } } }) { nodes { id name type position color } } }
    """
  }

  static func cycleIssues(cycleID: String) -> String {
    """
    query {
      cycle(id: "\(cycleID)") {
        issues(first: 250) {
          nodes {
            id identifier title description priority priorityLabel url createdAt
            state { id name type position color }
            assignee { id name email avatarUrl }
            labels { nodes { id name color } }
            project { id name color }
          }
        }
      }
    }
    """
  }

  static func assignedIssues(userID: String) -> String {
    """
    query {
      issues(
        filter: {
          assignee: { id: { eq: "\(userID)" } }
          state: { type: { nin: ["completed", "canceled"] } }
        }
        first: 100
        orderBy: updatedAt
      ) {
        nodes {
          id identifier title description priority priorityLabel url createdAt
          state { id name type position color }
          assignee { id name email avatarUrl }
          labels { nodes { id name color } }
          project { id name color }
        }
      }
    }
    """
  }

  static func issue(id: String) -> String {
    """
    query {
      issue(id: "\(id)") {
        id identifier title description priority priorityLabel url createdAt
        state { id name type position color }
        assignee { id name email avatarUrl }
        labels { nodes { id name color } }
        project { id name color }
      }
    }
    """
  }

  // The project queries pass ids and the page cursor as GraphQL variables, so
  // a stored or opaque value can never change the query text.

  /// One page of a team's open projects. Variables: `teamID`, `after`.
  /// Linear's project status types are backlog, planned, started, paused,
  /// completed and canceled; the last two are closed.
  static let projects = """
    query TeamProjects($teamID: String!, $after: String) {
      team(id: $teamID) {
        projects(
          first: 250
          after: $after
          filter: { status: { type: { nin: ["completed", "canceled"] } } }
        ) {
          nodes { id name color }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

  /// One page of a project's open issues in one team (the board's columns
  /// are that team's workflow states). Variables: `projectID`, `teamID`,
  /// `after`.
  static let projectIssues = """
    query ProjectIssues($projectID: ID!, $teamID: ID!, $after: String) {
      issues(
        first: 250
        after: $after
        filter: {
          project: { id: { eq: $projectID } }
          team: { id: { eq: $teamID } }
          state: { type: { nin: ["completed", "canceled"] } }
        }
      ) {
        nodes {
          id identifier title description priority priorityLabel url createdAt
          state { id name type position color }
          assignee { id name email avatarUrl }
          labels { nodes { id name color } }
          project { id name color }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

  /// Pages fetched at most for one list (4 × 250). A board never needs more,
  /// and a broken cursor can never loop.
  static let maxPages = 4

  static func transitionIssue(id: String, stateID: String) -> String {
    """
    mutation { issueUpdate(id: "\(id)", input: { stateId: "\(stateID)" }) { success } }
    """
  }
}

// MARK: - URLSession Client

public actor LinearAPIClient: LinearService {
  private let endpoint = URL(string: "https://api.linear.app/graphql")!
  private let session: URLSession
  private let apiKey: @Sendable () -> String?
  private let decoder: JSONDecoder

  public init(
    session: URLSession = .shared,
    apiKey: @escaping @Sendable () -> String? = { LinearKeychainStore.apiKey() }
  ) {
    self.session = session
    self.apiKey = apiKey
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  // MARK: - LinearIssueReading

  public func viewer() async throws -> LinearUser {
    let response: LinearGraphQLResponse<ViewerResponse> = try await execute(query: LinearGraphQL.viewer)
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.viewer
  }

  public func teams() async throws -> [LinearTeam] {
    let response: LinearGraphQLResponse<TeamsResponse> = try await execute(query: LinearGraphQL.teams)
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.teams.nodes
  }

  public func activeCycle(teamID: String) async throws -> LinearCycle? {
    let response: LinearGraphQLResponse<TeamCyclesResponse> = try await execute(
      query: LinearGraphQL.activeCycle(teamID: teamID))
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.team.activeCycle
  }

  public func workflowStates(teamID: String) async throws -> [LinearWorkflowState] {
    let response: LinearGraphQLResponse<WorkflowStatesResponse> = try await execute(
      query: LinearGraphQL.workflowStates(teamID: teamID))
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.workflowStates.nodes
  }

  public func cycleIssues(cycleID: String) async throws -> [LinearIssue] {
    let response: LinearGraphQLResponse<CycleIssuesResponse> = try await execute(
      query: LinearGraphQL.cycleIssues(cycleID: cycleID))
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.cycle?.issues.nodes ?? []
  }

  public func assignedIssues(userID: String) async throws -> [LinearIssue] {
    let response: LinearGraphQLResponse<AssignedIssuesResponse> = try await execute(
      query: LinearGraphQL.assignedIssues(userID: userID))
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.issues.nodes
  }

  public func projects(teamID: String) async throws -> [LinearProject] {
    let projects: [LinearProject] = try await Self.fetchPages { after in
      let response: LinearGraphQLResponse<TeamProjectsResponse> = try await self.execute(
        query: LinearGraphQL.projects, variables: ["teamID": teamID, "after": after])
      guard let data = response.data else { throw self.errorFromResponse(response) }
      // A team that no longer exists (or is not visible) has no projects.
      guard let connection = data.team?.projects else { return ([], nil) }
      return (connection.nodes, connection.pageInfo.nextCursor)
    }
    return LinearProject.sortedByName(projects)
  }

  public func projectIssues(projectID: String, teamID: String) async throws -> [LinearIssue] {
    try await Self.fetchPages { after in
      let response: LinearGraphQLResponse<ProjectIssuesResponse> = try await self.execute(
        query: LinearGraphQL.projectIssues,
        variables: ["projectID": projectID, "teamID": teamID, "after": after])
      guard let data = response.data else { throw self.errorFromResponse(response) }
      return (data.issues.nodes, data.issues.pageInfo.nextCursor)
    }
  }

  public func issue(id: String) async throws -> LinearIssue {
    let response: LinearGraphQLResponse<IssueDetailResponse> = try await execute(
      query: LinearGraphQL.issue(id: id))
    guard let data = response.data else { throw errorFromResponse(response) }
    return data.issue
  }

  // MARK: - LinearIssueTransitioning

  public func transitionIssue(id: String, stateID: String) async throws {
    let response: LinearGraphQLResponse<WorkflowStateTransitionResponse> = try await execute(
      query: LinearGraphQL.transitionIssue(id: id, stateID: stateID))
    if let errors = response.errors, !errors.isEmpty {
      throw LinearAPIError.graphQL(errors.map(\.message))
    }
    guard response.data?.issueUpdate.success == true else {
      throw LinearAPIError.graphQL(["Issue update returned success=false"])
    }
  }

  // MARK: - Private

  /// Follows `endCursor` until the last page, at most `LinearGraphQL.maxPages`.
  static func fetchPages<Node>(
    _ page: (_ after: String?) async throws -> (nodes: [Node], nextCursor: String?)
  ) async throws -> [Node] {
    var all: [Node] = []
    var cursor: String?
    for _ in 0..<LinearGraphQL.maxPages {
      let result = try await page(cursor)
      all += result.nodes
      guard let next = result.nextCursor, next != cursor else { break }
      cursor = next
    }
    return all
  }

  private func execute<T: Decodable & Sendable>(
    query: String, variables: [String: String?] = [:]
  ) async throws -> LinearGraphQLResponse<T> {
    guard let key = apiKey(), !key.isEmpty else {
      throw LinearAPIError.missingKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Linear personal API keys use the key directly, no "Bearer" prefix.
    request.setValue(key, forHTTPHeaderField: "Authorization")

    var body: [String: Any] = ["query": query]
    if !variables.isEmpty {
      body["variables"] = variables.mapValues { $0 ?? NSNull() as Any }
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data
    let httpResponse: HTTPURLResponse
    do {
      let (responseData, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw LinearAPIError.network("Non-HTTP response")
      }
      data = responseData
      httpResponse = http
    } catch let error as LinearAPIError {
      throw error
    } catch {
      throw LinearAPIError.network(error.localizedDescription)
    }

    switch httpResponse.statusCode {
    case 200:
      break
    case 401:
      throw LinearAPIError.unauthorized
    case 429:
      throw LinearAPIError.rateLimited
    default:
      throw LinearAPIError.network("HTTP \(httpResponse.statusCode)")
    }

    do {
      return try decoder.decode(LinearGraphQLResponse<T>.self, from: data)
    } catch {
      throw LinearAPIError.decoding(error.localizedDescription)
    }
  }

  private func errorFromResponse<T>(_ response: LinearGraphQLResponse<T>) -> LinearAPIError {
    if let errors = response.errors, !errors.isEmpty {
      return .graphQL(errors.map(\.message))
    }
    return .decoding("Response data was nil with no errors")
  }
}
