import Foundation

extension GitHubProjectReviewService {
  public func reviewAccount() async throws -> GitHubReviewAccount {
    // gh chooses its configured/default host. The returned profile URL supplies
    // that host; do not infer it from a repository or the connector account.
    let json = try await runSourceCommand(["api", "user"])
    struct User: Decodable {
      let nodeID: String
      let login: String
      let htmlURL: String
      enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case login
        case htmlURL = "html_url"
      }
    }
    let user = try JSONDecoder().decode(User.self, from: Data(json.utf8))
    guard let host = URL(string: user.htmlURL)?.host, Self.validIdentifier(user.login) else {
      throw GitHubReviewSourceError.incompleteResponse
    }
    let account = GitHubReviewAccount(host: host, nodeID: user.nodeID, login: user.login)
    return account
  }

  public func reviewSourceContext() async throws -> GitHubReviewSourceContext {
    let account = try await reviewAccount()
    let host = account.host
    var owners = [
      GitHubReviewOwner(
        account: account, nodeID: account.nodeID,
        login: account.login, isPersonal: true)
    ]
    var cursor: String?
    for _ in 0..<4 {
      try Task.checkCancellation()
      let query = """
        query($cursor: String) {
          viewer { id login organizations(first: 50, after: $cursor) {
            nodes { id login } pageInfo { hasNextPage endCursor }
          } }
        }
        """
      var args = ["api", "graphql", "--hostname", host, "-f", "query=\(query)"]
      if let cursor { args += ["-f", "cursor=\(cursor)"] }
      let data = try Self.sourceData(try await runSourceCommand(args))
      let viewer = try Self.verifiedViewer(data, account: account)
      guard let organizations = viewer["organizations"] as? [String: Any],
        let nodes = organizations["nodes"] as? [[String: Any]]
      else {
        throw GitHubReviewSourceError.incompleteResponse
      }
      for node in nodes {
        guard let id = node["id"] as? String, let login = node["login"] as? String,
          Self.validIdentifier(login)
        else { throw GitHubReviewSourceError.incompleteResponse }
        let owner = GitHubReviewOwner(account: account, nodeID: id, login: login, isPersonal: false)
        if !owners.contains(owner) { owners.append(owner) }
      }
      cursor = try Self.nextCursor(organizations)
      if cursor == nil { break }
    }
    return GitHubReviewSourceContext(account: account, owners: owners, isTruncated: cursor != nil)
  }

  public func listPullRequests(query: GitHubReviewQuery, limit: Int) async throws
    -> GitHubReviewQueue
  {
    guard !query.sources.isEmpty, query.sources.count <= 20,
      query.sources.allSatisfy({
        $0.owner.account == query.account
          && Self.validIdentifier($0.owner.login)
      })
    else { throw GitHubReviewSourceError.invalidSource }
    let limit = min(max(1, limit), 1_000)
    var requests: [GitHubProjectPullRequest] = []
    var seen = Set<String>()
    var pages = 0
    var truncated = false
    if query.hasUnsupportedProjectFilter {
      throw GitHubReviewSourceError.unsupportedProjectFilter
    }
    let plan = Self.searchPlan(for: query.view?.filter ?? "")

    // One global page/result budget, rather than one unbounded loop per repo.
    for (sourceIndex, source) in query.sources.enumerated() {
      try Task.checkCancellation()
      try await validate(source, account: query.account)
      var cursor: String?
      repeat {
        try Task.checkCancellation()
        guard pages < 10, requests.count < limit else {
          truncated = true
          break
        }
        var terms = ["is:pr", source.searchQualifier, "sort:updated-desc"]
        if let project = query.project {
          guard Self.validIdentifier(project.ownerLogin), project.number > 0,
            URL(string: project.url)?.host?.lowercased() == query.account.host
          else {
            throw GitHubReviewSourceError.invalidSource
          }
          terms.append("project:\(project.ownerLogin)/\(project.number)")
          if !plan.query.isEmpty { terms.append(plan.query) }
          if let state = plan.state { terms.append("is:\(state)") }
          if let merged = plan.merged { terms.append(merged ? "is:merged" : "-is:merged") }
        } else {
          terms.append("is:open")
        }
        let graph = """
          query($search: String!, $cursor: String, $count: Int!) {
            viewer { id login }
            search(query: $search, type: ISSUE, first: $count, after: $cursor) {
              nodes { __typename ... on PullRequest {
                id number title url repository { name nameWithOwner }
                author { login } updatedAt isDraft state
              } }
              pageInfo { hasNextPage endCursor }
            }
          }
          """
        var args = [
          "api", "graphql", "--hostname", query.account.host,
          "-f", "query=\(graph)", "-f", "search=\(terms.joined(separator: " "))",
          "-F", "count=\(min(100, limit - requests.count))",
        ]
        if let cursor { args += ["-f", "cursor=\(cursor)"] }
        let data = try Self.sourceData(try await runSourceCommand(args))
        _ = try Self.verifiedViewer(data, account: query.account)
        guard let search = data["search"] as? [String: Any],
          let nodes = search["nodes"] as? [[String: Any]]
        else {
          throw GitHubReviewSourceError.incompleteResponse
        }
        let pullRequestNodes = try nodes.compactMap { node -> [String: Any]? in
          guard let type = node["__typename"] as? String else {
            throw GitHubReviewSourceError.incompleteResponse
          }
          return type == "PullRequest" ? node : nil
        }
        let encoded = try JSONSerialization.data(withJSONObject: pullRequestNodes)
        let page = try Self.decodeSearchPullRequests(String(decoding: encoded, as: UTF8.self))
        // Project-view text cannot broaden the owner/repository boundary.
        for request in page where source.contains(request) {
          if seen.insert(request.reviewIdentity).inserted { requests.append(request) }
        }
        pages += 1
        let next = try Self.nextCursor(search)
        guard next == nil || next != cursor else {
          throw GitHubReviewSourceError.incompleteResponse
        }
        cursor = next
      } while cursor != nil
      if pages >= 10 || requests.count >= limit {
        truncated = truncated || cursor != nil || sourceIndex < query.sources.count - 1
        break
      }
    }
    if let project = query.project, !requests.isEmpty {
      let fields = try await projectFieldValues(
        pullRequestIDs: requests.map(\.id),
        projectID: project.id, account: query.account)
      requests = requests.compactMap { request in
        guard let values = fields[request.id],
          Self.matches(status: values.status, predicates: plan.statusPredicates)
        else {
          return nil
        }
        return GitHubProjectPullRequest(
          id: request.id, number: request.number,
          title: request.title, url: request.url, repositoryName: request.repositoryName,
          repositoryNameWithOwner: request.repositoryNameWithOwner,
          authorLogin: request.authorLogin,
          updatedAt: request.updatedAt, isDraft: request.isDraft, state: request.state,
          projectStatus: values.status, projectPriority: values.priority)
      }
    }
    return GitHubReviewQueue(
      pullRequests: requests.sorted {
        ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
      }, isTruncated: truncated)
  }

  private func validate(_ source: GitHubReviewSource, account: GitHubReviewAccount) async throws {
    var args = ["api", "graphql", "--hostname", account.host]
    let selection: String
    switch source {
    case .owner(let owner):
      selection = "repositoryOwner(login: $owner) { id }"
      args += ["-f", "owner=\(owner.login)"]
    case .repository(let repo):
      guard Self.validIdentifier(repo.name) else { throw GitHubReviewSourceError.invalidSource }
      selection = "repository(owner: $owner, name: $name) { owner { id } }"
      args += ["-f", "owner=\(repo.owner.login)", "-f", "name=\(repo.name)"]
    }
    let nameVariable = {
      if case .repository = source { return ", $name: String!" }
      return ""
    }()
    args += [
      "-f", "query=query($owner: String!\(nameVariable)) { viewer { id login } \(selection) }",
    ]
    let data = try Self.sourceData(try await runSourceCommand(args))
    _ = try Self.verifiedViewer(data, account: account)
    let owner =
      (data["repositoryOwner"] as? [String: Any])
      ?? ((data["repository"] as? [String: Any])?["owner"] as? [String: Any])
    guard owner?["id"] as? String == source.owner.nodeID else {
      throw GitHubReviewSourceError.unavailableSource
    }
  }

  static func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
  }

  static func sourceData(_ json: String, allowPartialErrors: Bool = false) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      allowPartialErrors || (root["errors"] as? [Any])?.isEmpty != false,
      let data = root["data"] as? [String: Any]
    else {
      throw GitHubReviewSourceError.incompleteResponse
    }
    return data
  }

  static func verifiedViewer(_ data: [String: Any], account: GitHubReviewAccount) throws -> [String:
    Any]
  {
    guard let viewer = data["viewer"] as? [String: Any],
      viewer["id"] as? String == account.nodeID,
      (viewer["login"] as? String)?.caseInsensitiveCompare(account.login) == .orderedSame
    else {
      throw GitHubReviewSourceError.accountChanged
    }
    return viewer
  }

  static func nextCursor(_ connection: [String: Any]) throws -> String? {
    guard let info = connection["pageInfo"] as? [String: Any],
      let hasNext = info["hasNextPage"] as? Bool
    else {
      throw GitHubReviewSourceError.incompleteResponse
    }
    if !hasNext { return nil }
    guard let cursor = info["endCursor"] as? String, !cursor.isEmpty else {
      throw GitHubReviewSourceError.incompleteResponse
    }
    return cursor
  }
}
