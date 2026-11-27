import Foundation

public protocol LinearQueueReading: Sendable {
  func queueAccount() async throws -> LinearQueueAccount
  func queueProject(
    id: String, account: LinearQueueAccount, expectedTeamIDs: Set<String>
  ) async throws -> LinearQueueProject
  /// Nil is a deleted or invisible issue. Transport and API errors throw instead.
  func queueIssue(id: String, account: LinearQueueAccount) async throws -> LinearQueueIssue?
}

extension LinearQueueReading {
  public func queueProject(id: String, account: LinearQueueAccount) async throws -> LinearQueueProject {
    try await queueProject(id: id, account: account, expectedTeamIDs: [])
  }
}

extension LinearAPIClient: LinearQueueReading {
  public func queueAccount() async throws -> LinearQueueAccount {
    try await queueAccount(authorization: currentAuthorization())
  }

  public func queueProject(
    id: String, account: LinearQueueAccount, expectedTeamIDs: Set<String>
  ) async throws -> LinearQueueProject {
    let authorization = try await queueAuthorization(for: account)
    let teams = try await queuePages { after in
      let data: QueueProjectTeams = try await self.queueRequest(
        LinearQueueGraphQL.teams, ["projectID": id, "after": after], authorization: authorization)
      guard data.project.id == id else { throw LinearAPIError.decoding("Project identity changed") }
      return data.project.teams
    }
    let workflow = try await queueWorkflow(for: teams.nodes, authorization: authorization)
    let issuePages = try await queueIssuePages(projectID: id, authorization: authorization)
    var omissions = workflow.omissions
    if let failure = teams.failure {
      omissions.append(.init(scope: .projectTeams, failure: failure))
    } else if teams.nodes.isEmpty {
      omissions.append(.init(scope: .projectTeams, failure: .decoding("No visible project teams")))
    }
    if let failure = issuePages.failure {
      omissions.append(.init(scope: .projectIssues, failure: failure))
    }

    let knownTeamIDs = Set(teams.nodes.map(\.id))
    for teamID in expectedTeamIDs.subtracting(knownTeamIDs).sorted() {
      omissions.append(.init(
        scope: .missingTeam(teamID: teamID), failure: .decoding("Previously visible team missing")))
    }
    if !expectedTeamIDs.isEmpty {
      for teamID in knownTeamIDs.subtracting(expectedTeamIDs).sorted() {
        omissions.append(.init(
          scope: .addedTeam(teamID: teamID), failure: .decoding("Project team not in the approved scope")))
      }
    }
    let coverage: LinearQueueCoverage =
      !expectedTeamIDs.isEmpty && expectedTeamIDs == knownTeamIDs && teams.failure == nil
      ? .expectedTeamsVerified : .accountVisible
    let otherTeamIDs = Set(issuePages.nodes.map { $0.issue.teamID }).subtracting(knownTeamIDs)
    for teamID in otherTeamIDs.sorted() {
      omissions.append(.init(
        scope: .unexpectedTeam(teamID: teamID), failure: .decoding("Issue team missing from project")))
    }

    let issues = try await queueResolveDependencies(issuePages.nodes, authorization: authorization)
    guard try authorization == currentAuthorization() else { throw LinearQueueError.accountChanged }
    return LinearQueueProject(
      id: id, account: account, teams: teams.nodes, coverage: coverage, workflowStates: workflow.states,
      issues: issues, omissions: omissions)
  }

  public func queueIssue(id: String, account: LinearQueueAccount) async throws -> LinearQueueIssue? {
    let authorization = try await queueAuthorization(for: account)
    var issue = try await queueReadIssue(id: id, authorization: authorization)
    if issue?.isClosed == false {
      do {
        issue?.dependencies = try await queueDependencies(issueID: id, initial: nil, authorization: authorization)
      } catch let failure as LinearAPIError {
        if failure.interruptsQueueRefresh { throw failure }
        issue?.dependencies = .unknown
      }
    }
    guard try authorization == currentAuthorization() else { throw LinearQueueError.accountChanged }
    return issue
  }

  func queueAuthorization(for account: LinearQueueAccount) async throws -> String {
    let authorization = try currentAuthorization()
    guard try await queueAccount(authorization: authorization) == account,
      try authorization == currentAuthorization()
    else { throw LinearQueueError.accountChanged }
    return authorization
  }

  func queueReadIssue(id: String, authorization: String) async throws -> LinearQueueIssue? {
    let response: QueueSingleIssue = try await queueRequest(
      LinearQueueGraphQL.issue, ["issueID": id], authorization: authorization)
    let connection = response.issues
    guard !connection.pageInfo.hasNextPage, connection.nodes.count <= 1,
      connection.nodes.allSatisfy({ $0.id == id })
    else { throw LinearAPIError.decoding("Could not verify the issue UUID") }
    return connection.nodes.first
  }

  func queueRequest<T: Decodable & Sendable>(
    _ query: String, _ variables: [String: String?] = [:], authorization: String
  ) async throws -> T {
    try Task.checkCancellation()
    let response: LinearGraphQLResponse<T> = try await execute(
      query: query, variables: variables, authorization: authorization)
    try Task.checkCancellation()
    if let errors = response.errors, !errors.isEmpty {
      throw LinearAPIError.graphQL(errors.map(\.message))
    }
    guard let data = response.data else { throw LinearAPIError.decoding("Missing queue data") }
    return data
  }

  private func queueAccount(authorization: String) async throws -> LinearQueueAccount {
    let response: QueueAccountResponse = try await queueRequest(
      LinearQueueGraphQL.account, authorization: authorization)
    guard !response.organization.id.isEmpty, !response.viewer.id.isEmpty else {
      throw LinearAPIError.decoding("Could not identify the Linear account")
    }
    return LinearQueueAccount(workspaceID: response.organization.id, userID: response.viewer.id)
  }

  private func queueWorkflow(for teams: [LinearTeam], authorization: String) async throws
    -> (states: [String: [LinearWorkflowState]], omissions: [LinearQueueOmission]) {
    var states: [String: [LinearWorkflowState]] = [:]
    var omissions: [LinearQueueOmission] = []
    for team in teams {
      let pages = try await queuePages { after in
        let data: QueueTeamStates = try await self.queueRequest(
          LinearQueueGraphQL.states, ["teamID": team.id, "after": after], authorization: authorization)
        guard data.team.id == team.id else { throw LinearAPIError.decoding("Team identity changed") }
        return data.team.states
      }
      if let failure = pages.failure {
        omissions.append(.init(scope: .workflowStates(teamID: team.id), failure: failure))
      } else {
        states[team.id] = pages.nodes
      }
    }
    return (states, omissions)
  }

  private func queueIssuePages(projectID: String, authorization: String) async throws
    -> QueuePages<QueueProjectIssue> {
    try await queuePages { after in
      let variables = ["projectID": projectID, "after": after]
      let data: QueueProjectIssues
      do {
        data = try await self.queueRequest(
          LinearQueueGraphQL.issues(includeDependencies: true), variables, authorization: authorization)
      } catch LinearAPIError.graphQL {
        // A hidden blocker can null the entire nested result. Keep the visible
        // issue page and ask for each issue's links in isolation.
        data = try await self.queueRequest(
          LinearQueueGraphQL.issues(includeDependencies: false), variables, authorization: authorization)
      }
      guard data.project.id == projectID,
        data.project.issues.nodes.allSatisfy({ $0.issue.projectID == projectID })
      else { throw LinearAPIError.decoding("Issue outside the requested project") }
      return data.project.issues
    }
  }

  private func queueResolveDependencies(
    _ nodes: [QueueProjectIssue], authorization: String
  ) async throws -> [LinearQueueIssue] {
    var issues: [LinearQueueIssue] = []
    for node in nodes {
      var issue = node.issue
      if !issue.isClosed {
        do {
          issue.dependencies = try await queueDependencies(
            issueID: issue.id, initial: node.initialDependencies, authorization: authorization)
        } catch let failure as LinearAPIError {
          if failure.interruptsQueueRefresh { throw failure }
          issue.dependencies = .unknown
        }
      }
      issues.append(issue)
    }
    return issues
  }

  private func queueDependencies(
    issueID: String, initial: QueueConnection<QueueRelation>?, authorization: String
  ) async throws -> LinearQueueDependencies {
    let pages = try await queuePages(initial: initial) { after in
      let data: QueueRelationsResponse = try await self.queueRequest(
        LinearQueueGraphQL.dependencies, ["issueID": issueID, "after": after],
        authorization: authorization)
      guard data.issue.id == issueID else { throw LinearAPIError.decoding("Dependency owner changed") }
      return data.issue.inverseRelations
    }
    if let failure = pages.failure { throw failure }
    let blockers = pages.nodes.filter { $0.type == "blocks" }
    guard blockers.allSatisfy({ $0.relatedIssue?.id == issueID && $0.issue != nil }) else {
      return .unknown
    }
    var seen = Set<String>()
    let dependencies = blockers.compactMap { relation -> LinearQueueDependency? in
      guard let source = relation.issue, seen.insert(source.id).inserted else { return nil }
      return LinearQueueDependency(issueID: source.id, status: source.status)
    }
    return .known(dependencies.sorted { $0.issueID < $1.issueID })
  }
}

private extension LinearAPIClient {
  /// Preserve earlier pages for the preview and disclose every incomplete scope.
  func queuePages<Node: Decodable & Sendable & Identifiable>(
    initial: QueueConnection<Node>? = nil,
    _ fetch: (_ after: String?) async throws -> QueueConnection<Node>
  ) async throws -> QueuePages<Node> where Node.ID == String {
    var result: [Node] = []
    var cursor: String?
    var seen = Set<String>()
    var nodeIDs = Set<String>()
    for index in 0..<LinearQueueGraphQL.maximumPages {
      let page: QueueConnection<Node>
      do {
        if index == 0, let initial { page = initial } else { page = try await fetch(cursor) }
      } catch let failure as LinearAPIError {
        if failure.interruptsQueueRefresh { throw failure }
        return QueuePages(nodes: result, failure: failure)
      }
      for node in page.nodes {
        guard !node.id.isEmpty, nodeIDs.insert(node.id).inserted else {
          return QueuePages(nodes: result, failure: .decoding("Repeated or empty queue node ID"))
        }
        result.append(node)
      }
      guard page.pageInfo.hasNextPage else { return QueuePages(nodes: result, failure: nil) }
      guard let next = page.pageInfo.endCursor, !next.isEmpty, seen.insert(next).inserted else {
        return QueuePages(nodes: result, failure: .decoding("Missing or repeated queue cursor"))
      }
      cursor = next
    }
    return QueuePages(nodes: result, failure: .decoding("Queue page limit reached"))
  }
}

private extension LinearAPIError {
  var interruptsQueueRefresh: Bool {
    switch self {
    case .missingKey, .unauthorized, .rateLimited, .network: true
    case .graphQL, .decoding: false
    }
  }
}

private struct QueuePages<Node> {
  let nodes: [Node]
  let failure: LinearAPIError?
}

private struct QueueConnection<Node: Decodable & Sendable>: Decodable, Sendable {
  let nodes: [Node]
  let pageInfo: LinearPageInfo
}

private struct QueueAccountResponse: Decodable, Sendable {
  let organization: LinearQueueReference
  let viewer: LinearQueueReference
}

private struct QueueProjectTeams: Decodable, Sendable {
  let project: Project
  struct Project: Decodable, Sendable {
    let id: String
    let teams: QueueConnection<LinearTeam>
  }
}

private struct QueueTeamStates: Decodable, Sendable {
  let team: Team
  struct Team: Decodable, Sendable {
    let id: String
    let states: QueueConnection<LinearWorkflowState>
  }
}

private struct QueueProjectIssues: Decodable, Sendable {
  let project: Project
  struct Project: Decodable, Sendable {
    let id: String
    let issues: QueueConnection<QueueProjectIssue>
  }
}

private struct QueueProjectIssue: Decodable, Identifiable, Sendable {
  let issue: LinearQueueIssue
  let initialDependencies: QueueConnection<QueueRelation>?
  var id: String { issue.id }

  enum CodingKeys: String, CodingKey { case inverseRelations }

  init(from decoder: Decoder) throws {
    issue = try LinearQueueIssue(from: decoder)
    let values = try decoder.container(keyedBy: CodingKeys.self)
    initialDependencies = try values.decodeIfPresent(
      QueueConnection<QueueRelation>.self, forKey: .inverseRelations)
  }
}

private struct QueueSingleIssue: Decodable, Sendable {
  let issues: QueueConnection<LinearQueueIssue>
}

private struct QueueRelationsResponse: Decodable, Sendable {
  let issue: Issue
  struct Issue: Decodable, Sendable {
    let id: String
    let inverseRelations: QueueConnection<QueueRelation>
  }
}

private struct QueueRelation: Decodable, Identifiable, Sendable {
  let id: String
  let type: String
  let issue: Source?
  let relatedIssue: LinearQueueReference?

  struct Source: Decodable, Sendable {
    let id: String
    let state: State?
    let archivedAt: String?

    var status: LinearQueueDependency.Status {
      if state?.type == "completed" { return .completed }
      if state?.type == "canceled" { return .canceled }
      guard archivedAt == nil, let type = state?.type else { return .unknown }
      return ["backlog", "unstarted", "started", "triage"].contains(type) ? .active : .unknown
    }
  }

  struct State: Decodable, Sendable { let type: String }
}
