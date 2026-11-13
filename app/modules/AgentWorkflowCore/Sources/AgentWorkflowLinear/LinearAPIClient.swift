import Foundation

// MARK: - Protocols

public protocol LinearIssueReading: Sendable {
  func viewer() async throws -> LinearUser
  func teams() async throws -> [LinearTeam]
  func activeCycle(teamID: String) async throws -> LinearCycle?
  func workflowStates(teamID: String) async throws -> [LinearWorkflowState]
  func cycleIssues(cycleID: String) async throws -> [LinearIssue]
  func assignedIssues(userID: String) async throws -> [LinearIssue]
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
      }
    }
    """
  }

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

  private func execute<T: Decodable & Sendable>(query: String) async throws -> LinearGraphQLResponse<T> {
    guard let key = apiKey(), !key.isEmpty else {
      throw LinearAPIError.missingKey
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // Linear personal API keys use the key directly, no "Bearer" prefix.
    request.setValue(key, forHTTPHeaderField: "Authorization")

    let body = ["query": query]
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
