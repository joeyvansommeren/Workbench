import AgentWorkflowCore
import Foundation
import Testing

@testable import AgentWorkflowLinear

let account = LinearQueueAccount(workspaceID: "workspace", userID: "viewer")
let accountResponse = ["data": ["organization": ["id": "workspace"], "viewer": ["id": "viewer"]]]
let targetStateResponse: [String: Any] = [
  "data": ["workflowStates": page([["id": "active", "team": ["id": "alpha"], "type": "started"]])]
]

func policyFor(
  _ project: LinearQueueProject, states: [String: Set<String>] = ["alpha": ["alpha-entry"], "beta": ["beta-entry"]]
) throws -> LinearQueueEligibility {
  let repository = try OrchestratorRepositoryBinding(repositoryPath: "/tmp/synthetic", baseBranch: "main")
  let mappings = try project.issues.map { (try account.identity(for: $0.id), repository) }
  return LinearQueueEligibility(stateIDsByTeam: states, repositories: Dictionary(uniqueKeysWithValues: mappings))
}

func makeTransition(_ row: [String: Any]) throws -> LinearQueueTransitionPlan {
  let issue = try JSONDecoder().decode(LinearQueueIssue.self, from: JSONSerialization.data(withJSONObject: row))
  return try LinearQueueTransitionPlan(
    operationID: UUID(), account: account, projectID: "project", issue: issue, targetStateID: "active")
}

func client(now: @escaping @Sendable () -> Date = { Date() }) -> LinearAPIClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [QueueHTTPStub.self]
  return LinearAPIClient(session: URLSession(configuration: configuration), queueNow: now,
    apiKey: { "test-linear-key" })
}

func team(_ id: String) -> [String: String] {
  ["id": id, "name": id, "key": id.uppercased()]
}

func state(_ id: String, name: String = "Renamed state", type: String = "unstarted") -> [String: Any] {
  ["id": id, "name": name, "type": type, "position": 1, "color": "#000000"]
}

func issue(
  _ id: String, team: String, stateID: String = "entry", stateType: String = "unstarted",
  sortOrder: Double = 1, project: String = "project", owner: String = "viewer",
  revision: String = "initial", relations: [String: Any]? = page([])
) -> [String: Any] {
  var row: [String: Any] = [
    "id": id, "identifier": "TEST-1", "title": "Synthetic ticket", "updatedAt": revision,
    "priority": 2, "sortOrder": sortOrder, "team": ["id": team], "project": ["id": project],
    "assignee": ["id": owner], "state": state(stateID, type: stateType)
  ]
  row["inverseRelations"] = relations
  return row
}

func relation(_ id: String, source: String, target: String, state: String) -> [String: Any] {
  [
    "id": id, "type": "blocks", "relatedIssue": ["id": target],
    "issue": ["id": source, "state": ["type": state]]
  ]
}

func projectPage(_ field: String, _ rows: [[String: Any]], next: String? = nil) -> [String: Any] {
  ["data": ["project": ["id": "project", field: page(rows, next: next)]]]
}

func statePage(team: String, states: [[String: Any]], next: String? = nil) -> [String: Any] {
  ["data": ["team": ["id": team, "states": page(states, next: next)]]]
}

func dependencyPage(_ id: String, _ rows: [[String: Any]]) -> [String: Any] {
  ["data": ["issue": ["id": id, "inverseRelations": page(rows)]]]
}

func singleIssue(_ issue: [String: Any]) -> [String: Any] {
  ["data": ["issues": page([issue])]]
}

func page(_ rows: [[String: Any]], next: String? = nil) -> [String: Any] {
  ["nodes": rows, "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]]
}

final class QueueHTTPStub: URLProtocol, @unchecked Sendable {
  struct Request {
    let query: String
    let variables: [String: String]
    let authorization: String?
  }

  enum Reply {
    case data(Data)
    case http(Int)
    case offline

    static func ok(_ values: [String: Any]) -> Self {
      do {
        return .data(try JSONSerialization.data(withJSONObject: values))
      } catch {
        Issue.record("Invalid test fixture: \(error)")
        return .http(500)
      }
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var replies: [Reply] = []
  nonisolated(unsafe) private static var recorded: [Request] = []

  static func set(_ replacements: [Reply]) {
    lock.withLock {
      replies = replacements
      recorded = []
    }
  }

  static var requests: [Request] { lock.withLock { recorded } }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = Self.decodeBody(request)
    let response = Self.lock.withLock {
      Self.recorded.append(Request(
        query: body["query"] as? String ?? "", variables: (body["variables"] as? [String: Any] ?? [:])
          .compactMapValues { $0 as? String }, authorization: request.value(forHTTPHeaderField: "Authorization")))
      return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
    }
    guard let response else {
      Issue.record("Unexpected synthetic request")
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    switch response {
    case .data(let data): respond(status: 200, data: data)
    case .http(let status): respond(status: status, data: Data())
    case .offline: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
  }

  override func stopLoading() {}

  private func respond(status: Int, data: Data) {
    guard let url = request.url, let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func decodeBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
      }
    }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }
}
