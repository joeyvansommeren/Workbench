import Foundation
import Testing

@testable import AgentWorkflowLinear

// MARK: - Queries and decoding

@Suite("Linear project queries")
struct LinearProjectQueryTests {
  @Test("The projects query asks for the team's open projects, one page at a time")
  func projectsQuery() {
    let query = LinearGraphQL.projects
    #expect(query.contains("team(id: $teamID)"))
    #expect(query.contains("$teamID: String!"))
    #expect(query.contains("after: $after"))
    #expect(query.contains(#"status: { type: { nin: ["completed", "canceled"] } }"#))
    #expect(query.contains("nodes { id name color }"))
    #expect(query.contains("pageInfo { hasNextPage endCursor }"))
  }

  @Test("The project issues query filters by project, team and open states")
  func projectIssuesQuery() {
    let query = LinearGraphQL.projectIssues
    #expect(query.contains("$projectID: ID!"))
    #expect(query.contains("$teamID: ID!"))
    #expect(query.contains("project: { id: { eq: $projectID } }"))
    #expect(query.contains("team: { id: { eq: $teamID } }"))
    #expect(query.contains(#"state: { type: { nin: ["completed", "canceled"] } }"#))
    #expect(query.contains("first: 250"))
    #expect(query.contains("pageInfo { hasNextPage endCursor }"))
    #expect(query.contains("project { id name color }"))
  }

  @Test("Every issue query asks for the issue's project")
  func issueQueriesIncludeProject() {
    for query in [
      LinearGraphQL.cycleIssues(cycleID: "c"), LinearGraphQL.assignedIssues(userID: "u"),
      LinearGraphQL.issue(id: "i"),
    ] {
      #expect(query.contains("project { id name color }"))
    }
  }

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  @Test("Decodes a projects page and its cursor")
  func decodeProjects() throws {
    let json = """
      {
        "data": {
          "team": {
            "projects": {
              "nodes": [
                { "id": "p1", "name": "Onboarding", "color": "#5e6ad2" },
                { "id": "p2", "name": "billing", "color": "#f2c94c" }
              ],
              "pageInfo": { "hasNextPage": true, "endCursor": "cursor-1" }
            }
          }
        }
      }
      """.data(using: .utf8)!
    let response = try decoder.decode(LinearGraphQLResponse<TeamProjectsResponse>.self, from: json)
    let connection = try #require(response.data?.team?.projects)
    #expect(connection.nodes.map(\.name) == ["Onboarding", "billing"])
    #expect(connection.nodes[0].color == "#5e6ad2")
    #expect(connection.pageInfo.nextCursor == "cursor-1")
    #expect(LinearProject.sortedByName(connection.nodes).map(\.id) == ["p2", "p1"])
  }

  @Test("Decodes project issues with their project; an issue without one has nil")
  func decodeProjectIssues() throws {
    let json = """
      {
        "data": {
          "issues": {
            "nodes": [
              {
                "id": "issue-1", "identifier": "WB-12", "title": "One", "description": null,
                "priority": 2, "priorityLabel": "High", "url": "https://linear.app/wb/issue/WB-12",
                "createdAt": "2026-11-01T10:00:00.000Z",
                "state": { "id": "s2", "name": "Todo", "type": "unstarted", "position": 1.0, "color": "#e2e2e2" },
                "assignee": null,
                "labels": { "nodes": [] },
                "project": { "id": "p1", "name": "Onboarding", "color": "#5e6ad2" }
              },
              {
                "id": "issue-2", "identifier": "WB-13", "title": "Two", "description": null,
                "priority": 0, "priorityLabel": "No priority", "url": "https://linear.app/wb/issue/WB-13",
                "createdAt": "2026-11-01T10:00:00.000Z",
                "state": { "id": "s2", "name": "Todo", "type": "unstarted", "position": 1.0, "color": "#e2e2e2" },
                "assignee": null,
                "labels": { "nodes": [] },
                "project": null
              }
            ],
            "pageInfo": { "hasNextPage": false, "endCursor": "cursor-9" }
          }
        }
      }
      """.data(using: .utf8)!
    let response = try decoder.decode(LinearGraphQLResponse<ProjectIssuesResponse>.self, from: json)
    let issues = try #require(response.data?.issues)
    #expect(issues.nodes[0].project == LinearProject(id: "p1", name: "Onboarding", color: "#5e6ad2"))
    #expect(issues.nodes[1].project == nil)
    // The last page has no next cursor, even when Linear sends one.
    #expect(issues.pageInfo.nextCursor == nil)
  }

  @Test("Pages are followed until the last one")
  func fetchPagesFollowsCursor() async throws {
    var cursors: [String?] = []
    let all: [Int] = try await LinearAPIClient.fetchPages { after in
      cursors.append(after)
      switch after {
      case nil: return ([1, 2], "a")
      case "a": return ([3], "b")
      default: return ([4], nil)
      }
    }
    #expect(all == [1, 2, 3, 4])
    #expect(cursors == [nil, "a", "b"])
  }

  @Test("Paging stops at the page cap and on a repeated cursor")
  func fetchPagesStops() async throws {
    var calls = 0
    let capped: [Int] = try await LinearAPIClient.fetchPages { _ in
      calls += 1
      return ([calls], "next-\(calls)")
    }
    #expect(calls == LinearGraphQL.maxPages)
    #expect(capped.count == LinearGraphQL.maxPages)

    calls = 0
    let repeated: [Int] = try await LinearAPIClient.fetchPages { _ in
      calls += 1
      return ([calls], "same")
    }
    #expect(repeated == [1, 2])
  }
}

// MARK: - Requests

/// Answers Linear requests from a queue of canned bodies and records the
/// request bodies. Only `LinearProjectRequestTests` (serialized) uses it.
private final class LinearStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var responses: [Data] = []
  nonisolated(unsafe) static var requestBodies: [[String: Any]] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if let data = Self.bodyData(of: request),
      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      Self.requestBodies.append(body)
    }
    let body = Self.responses.isEmpty ? Data() : Self.responses.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  /// URLSession moves `httpBody` into a stream before a protocol sees it.
  private static func bodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

@Suite("Linear project requests", .serialized)
struct LinearProjectRequestTests {
  private func client() -> LinearAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LinearStubProtocol.self]
    return LinearAPIClient(session: URLSession(configuration: configuration), apiKey: { "key" })
  }

  private func page(_ nodes: String, next: String?) -> Data {
    let cursor = next.map { "\"\($0)\"" } ?? "null"
    return """
      { "data": { "team": { "projects": {
        "nodes": [\(nodes)],
        "pageInfo": { "hasNextPage": \(next != nil), "endCursor": \(cursor) }
      } } } }
      """.data(using: .utf8)!
  }

  @Test("Projects pass the team and cursor as variables, follow pages and sort by name")
  func projectsRequest() async throws {
    LinearStubProtocol.requestBodies = []
    LinearStubProtocol.responses = [
      page(##"{ "id": "p2", "name": "Zeta", "color": "#000000" }"##, next: "cursor-1"),
      page(##"{ "id": "p1", "name": "Alpha", "color": "#ffffff" }"##, next: nil),
    ]

    let projects = try await client().projects(teamID: "team-1")

    #expect(projects.map(\.id) == ["p1", "p2"])
    let bodies = LinearStubProtocol.requestBodies
    #expect(bodies.count == 2)
    let first = try #require(bodies.first?["variables"] as? [String: Any])
    #expect(first["teamID"] as? String == "team-1")
    #expect(first["after"] is NSNull)
    let second = try #require(bodies.last?["variables"] as? [String: Any])
    #expect(second["after"] as? String == "cursor-1")
    // The id never ends up in the query text.
    #expect((bodies.first?["query"] as? String)?.contains("team-1") == false)
  }

  @Test("A GraphQL error from the projects query is thrown")
  func projectsError() async {
    LinearStubProtocol.requestBodies = []
    LinearStubProtocol.responses = [
      #"{ "data": null, "errors": [{ "message": "Entity not found" }] }"#.data(using: .utf8)!
    ]
    await #expect(throws: LinearAPIError.graphQL(["Entity not found"])) {
      _ = try await client().projects(teamID: "gone")
    }
  }
}
