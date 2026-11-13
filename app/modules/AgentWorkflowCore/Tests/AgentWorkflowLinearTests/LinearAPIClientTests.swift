import Foundation
import Testing

@testable import AgentWorkflowLinear

// MARK: - Fixture JSON

private enum Fixtures {
  static let viewer = """
    {
      "data": {
        "viewer": {
          "id": "user-1",
          "name": "Joey van Sommeren",
          "email": "joey@example.com",
          "avatarUrl": "https://example.com/avatar.png"
        }
      }
    }
    """.data(using: .utf8)!

  static let teams = """
    {
      "data": {
        "teams": {
          "nodes": [
            { "id": "team-1", "name": "Workbench", "key": "WB" },
            { "id": "team-2", "name": "Design", "key": "DES" }
          ]
        }
      }
    }
    """.data(using: .utf8)!

  static let workflowStates = """
    {
      "data": {
        "workflowStates": {
          "nodes": [
            { "id": "s1", "name": "Backlog", "type": "backlog", "position": 0.0, "color": "#bec2c8" },
            { "id": "s2", "name": "Todo", "type": "unstarted", "position": 1.0, "color": "#e2e2e2" },
            { "id": "s3", "name": "In Progress", "type": "started", "position": 2.0, "color": "#f2c94c" },
            { "id": "s4", "name": "Done", "type": "completed", "position": 3.0, "color": "#5e6ad2" },
            { "id": "s5", "name": "Canceled", "type": "canceled", "position": 4.0, "color": "#95a2b3" }
          ]
        }
      }
    }
    """.data(using: .utf8)!

  static let cycleIssues = """
    {
      "data": {
        "cycle": {
          "issues": {
            "nodes": [
              {
                "id": "issue-1",
                "identifier": "WB-12",
                "title": "Add Linear integration",
                "description": "Build a Linear board view.",
                "priority": 2,
                "priorityLabel": "High",
                "url": "https://linear.app/workbench/issue/WB-12",
                "createdAt": "2026-11-01T10:00:00.000Z",
                "state": { "id": "s3", "name": "In Progress", "type": "started", "position": 2.0, "color": "#f2c94c" },
                "assignee": { "id": "user-1", "name": "Joey", "email": "joey@example.com", "avatarUrl": null },
                "labels": { "nodes": [{ "id": "l1", "name": "feature", "color": "#bb87fc" }] }
              },
              {
                "id": "issue-2",
                "identifier": "WB-13",
                "title": "Fix build warning",
                "description": null,
                "priority": 3,
                "priorityLabel": "Medium",
                "url": "https://linear.app/workbench/issue/WB-13",
                "createdAt": "2026-11-02T08:00:00.000Z",
                "state": { "id": "s2", "name": "Todo", "type": "unstarted", "position": 1.0, "color": "#e2e2e2" },
                "assignee": null,
                "labels": { "nodes": [] }
              }
            ]
          }
        }
      }
    }
    """.data(using: .utf8)!
}

// MARK: - GraphQL request building

@Suite("Linear GraphQL queries")
struct LinearGraphQLTests {
  @Test("Viewer query has correct shape")
  func viewerQuery() {
    let query = LinearGraphQL.viewer
    #expect(query.contains("viewer"))
    #expect(query.contains("id"))
    #expect(query.contains("name"))
    #expect(query.contains("email"))
  }

  @Test("Teams query has correct shape")
  func teamsQuery() {
    let query = LinearGraphQL.teams
    #expect(query.contains("teams"))
    #expect(query.contains("nodes"))
    #expect(query.contains("key"))
  }

  @Test("Cycle issues query embeds the cycle ID")
  func cycleIssuesQuery() {
    let query = LinearGraphQL.cycleIssues(cycleID: "cycle-abc")
    #expect(query.contains("cycle-abc"))
    #expect(query.contains("issues"))
    #expect(query.contains("state"))
    #expect(query.contains("assignee"))
    #expect(query.contains("labels"))
  }

  @Test("Workflow states query embeds the team ID")
  func workflowStatesQuery() {
    let query = LinearGraphQL.workflowStates(teamID: "team-xyz")
    #expect(query.contains("team-xyz"))
    #expect(query.contains("workflowStates"))
  }

  @Test("Transition mutation embeds issue ID and state ID")
  func transitionMutation() {
    let query = LinearGraphQL.transitionIssue(id: "issue-1", stateID: "state-2")
    #expect(query.contains("issue-1"))
    #expect(query.contains("state-2"))
    #expect(query.contains("mutation"))
    #expect(query.contains("issueUpdate"))
  }
}

// MARK: - Response decoding

@Suite("Linear response decoding")
struct LinearDecodingTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  @Test("Decodes viewer response")
  func decodeViewer() throws {
    let response = try decoder.decode(
      LinearGraphQLResponse<ViewerResponse>.self, from: Fixtures.viewer)
    let viewer = try #require(response.data?.viewer)
    #expect(viewer.id == "user-1")
    #expect(viewer.name == "Joey van Sommeren")
    #expect(viewer.email == "joey@example.com")
  }

  @Test("Decodes teams response")
  func decodeTeams() throws {
    let response = try decoder.decode(
      LinearGraphQLResponse<TeamsResponse>.self, from: Fixtures.teams)
    let teams = try #require(response.data?.teams.nodes)
    #expect(teams.count == 2)
    #expect(teams[0].key == "WB")
    #expect(teams[1].name == "Design")
  }

  @Test("Decodes workflow states and sorts by display order")
  func decodeAndSortWorkflowStates() throws {
    let response = try decoder.decode(
      LinearGraphQLResponse<WorkflowStatesResponse>.self, from: Fixtures.workflowStates)
    let states = try #require(response.data?.workflowStates.nodes)
    #expect(states.count == 5)
    let sorted = states.sorted(by: LinearWorkflowState.displayOrder)
    #expect(sorted[0].type == "backlog")
    #expect(sorted[1].type == "unstarted")
    #expect(sorted[2].type == "started")
    #expect(sorted[3].type == "completed")
    #expect(sorted[4].type == "canceled")
  }

  @Test("Decodes cycle issues with nested models")
  func decodeCycleIssues() throws {
    let response = try decoder.decode(
      LinearGraphQLResponse<CycleIssuesResponse>.self, from: Fixtures.cycleIssues)
    let issues = try #require(response.data?.cycle?.issues.nodes)
    #expect(issues.count == 2)
    let first = issues[0]
    #expect(first.identifier == "WB-12")
    #expect(first.title == "Add Linear integration")
    #expect(first.priority == 2)
    #expect(first.state.type == "started")
    #expect(first.assignee?.name == "Joey")
    #expect(first.labels.count == 1)
    #expect(first.labels[0].name == "feature")
    // Second issue has no assignee or labels.
    #expect(issues[1].assignee == nil)
    #expect(issues[1].labels.isEmpty)
  }

  @Test("teamKey extracts the prefix from identifier")
  func teamKey() {
    let issue = LinearIssue(
      id: "i", identifier: "WB-12", title: "Test",
      state: LinearWorkflowState(id: "s", name: "Todo", type: "unstarted", position: 0, color: "#fff"))
    #expect(issue.teamKey == "WB")
  }
}

// MARK: - Error mapping

@Suite("Linear error mapping")
struct LinearErrorMappingTests {
  @Test("401 maps to unauthorized")
  func unauthorized() {
    let error = LinearAPIError.unauthorized
    #expect(error == .unauthorized)
  }

  @Test("429 maps to rateLimited")
  func rateLimited() {
    let error = LinearAPIError.rateLimited
    #expect(error == .rateLimited)
  }

  @Test("Missing key is a distinct error")
  func missingKey() {
    let error = LinearAPIError.missingKey
    #expect(error == .missingKey)
    #expect(error != .unauthorized)
  }

  @Test("GraphQL errors carry messages")
  func graphQLErrors() {
    let error = LinearAPIError.graphQL(["bad request", "missing field"])
    if case .graphQL(let messages) = error {
      #expect(messages.count == 2)
      #expect(messages[0] == "bad request")
    } else {
      Issue.record("Expected graphQL error")
    }
  }

  @Test("Decoding error carries description")
  func decodingError() {
    let error = LinearAPIError.decoding("key not found")
    if case .decoding(let message) = error {
      #expect(message.contains("key not found"))
    } else {
      Issue.record("Expected decoding error")
    }
  }
}

// MARK: - State ordering

@Suite("Workflow state ordering")
struct WorkflowStateOrderingTests {
  private func state(_ type: String, position: Double = 0) -> LinearWorkflowState {
    LinearWorkflowState(id: type, name: type, type: type, position: position, color: "#000")
  }

  @Test("State types sort in display order: backlog < unstarted < started < completed")
  func typeOrder() {
    let states = [state("completed"), state("started"), state("backlog"), state("unstarted")]
    let sorted = states.sorted(by: LinearWorkflowState.displayOrder)
    #expect(sorted.map(\.type) == ["backlog", "unstarted", "started", "completed"])
  }

  @Test("Same type sorts by position")
  func positionOrder() {
    let a = state("started", position: 1.0)
    let b = state("started", position: 0.5)
    let sorted = [a, b].sorted(by: LinearWorkflowState.displayOrder)
    #expect(sorted[0].position == 0.5)
  }
}
