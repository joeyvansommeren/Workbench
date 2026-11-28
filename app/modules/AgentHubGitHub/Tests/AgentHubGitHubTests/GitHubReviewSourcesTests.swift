import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("Review sources")
struct GitHubReviewSourcesTests {
  let account = GitHubReviewAccount(host: "code.example.test", nodeID: "U1", login: "alex")
  var personal: GitHubReviewOwner {
    GitHubReviewOwner(account: account, nodeID: "U1", login: "alex", isPersonal: true)
  }
  var company: GitHubReviewOwner {
    GitHubReviewOwner(account: account, nodeID: "O1", login: "acme", isPersonal: false)
  }

  @Test("A review query above the source limit makes no GitHub requests")
  func rejectsOversizedQuery() async {
    let runner = SourceRunner([])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let sources = (0...GitHubReviewQuery.maximumSourceCount).map { index in
      GitHubReviewSource.owner(
        GitHubReviewOwner(
          account: account, nodeID: "org-\(index)", login: "org-\(index)", isPersonal: false))
    }
    await #expect(throws: GitHubReviewSourceError.invalidSource) {
      try await service.listPullRequests(
        query: GitHubReviewQuery(account: account, sources: sources), limit: 300)
    }
    #expect(await runner.commands.isEmpty)
  }

  @Test("Personal drafts outside Projects survive; duplicate pages deduplicate")
  func draftsAndPages() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"U1"}}}"#,
      page([pr(owner: "alex", number: 1, draft: true)], next: "next"),
      page([pr(owner: "alex", number: 1, draft: true), pr(owner: "alex", number: 2)], next: nil),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let result = try await service.listPullRequests(
      query: GitHubReviewQuery(
        account: account,
        sources: [.owner(personal)]), limit: 300)
    #expect(result.pullRequests.count == 2)
    #expect(result.pullRequests.contains(where: { $0.isDraft }))
    #expect(result.pullRequests.allSatisfy { $0.projectStatus == nil })
    #expect(!result.isTruncated)
    let commands = await runner.commands
    #expect(commands.allSatisfy { $0.contains(account.host) })
    #expect(commands[1].contains("search=is:pr user:alex sort:updated-desc is:open"))
    #expect(!commands.joined().joined().contains("project:"))
    #expect(commands[2].contains("cursor=next"))
  }

  @Test("Same repo names from distinct owners remain distinct; out-of-scope results are removed")
  func ownerIdentity() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"U1"}}}"#,
      page([pr(owner: "alex", number: 1), pr(owner: "unselected", number: 3)], next: nil),
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"O1"}}}"#,
      page([pr(owner: "acme", number: 1)], next: nil),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let result = try await service.listPullRequests(
      query: GitHubReviewQuery(
        account: account,
        sources: [.owner(personal), .owner(company)]), limit: 300)
    #expect(Set(result.pullRequests.map(\.reviewIdentity)).count == 2)
    #expect(result.pullRequests.allSatisfy { $0.authorLogin == "alex" })
  }

  @Test("Repository sources validate ownership and keep only the selected repository")
  func repositorySourceBoundary() async throws {
    let repository = GitHubReviewRepository(owner: company, name: "shared")
    let query = GitHubReviewQuery(account: account, sources: [.repository(repository)])
    let otherRepository = pr(owner: "acme", number: 2)
      .replacingOccurrences(of: "/shared/", with: "/other/")
      .replacingOccurrences(
        of: #""name":"shared","nameWithOwner":"acme/shared""#,
        with: #""name":"other","nameWithOwner":"acme/other""#)
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repository":{"owner":{"id":"O1"}}}}"#,
      page(
        [pr(owner: "acme", number: 1), otherRepository, pr(owner: "alex", number: 3)], next: nil),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let queue = try await service.listPullRequests(query: query, limit: 300)
    #expect(queue.pullRequests.map(\.number) == [1])
    let commands = await runner.commands
    #expect(commands[1].contains("search=is:pr repo:acme/shared sort:updated-desc is:open"))

    for repositoryResponse in [
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repository":null}}"#,
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repository":{"owner":{"id":"wrong"}}}}"#,
    ] {
      let invalidRunner = SourceRunner([repositoryResponse])
      let invalidService = GitHubProjectReviewService(
        runSourceCommand: { try await invalidRunner.run($0) })
      await #expect(throws: GitHubReviewSourceError.unavailableSource) {
        try await invalidService.listPullRequests(query: query, limit: 300)
      }
      #expect(await invalidRunner.commands.count == 1)
    }
  }

  @Test("A non-PR search node is skipped without losing matching pull requests")
  func mixedSearchNodeTypes() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"O1"}}}"#,
      page([pr(owner: "acme", number: 1), #"{"__typename":"Issue"}"#], next: nil),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let queue = try await service.listPullRequests(
      query: GitHubReviewQuery(account: account, sources: [.owner(company)]), limit: 300)
    #expect(queue.pullRequests.map(\.number) == [1])
    #expect(await runner.commands[1].joined().contains("__typename"))
  }

  @Test("A malformed pull request search node fails the queue")
  func malformedPullRequestSearchNode() async {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"O1"}}}"#,
      page([#"{"__typename":"PullRequest","id":"incomplete"}"#], next: nil),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    await #expect(throws: GitHubCLIError.self) {
      try await service.listPullRequests(
        query: GitHubReviewQuery(account: account, sources: [.owner(company)]), limit: 300)
    }
  }

  @Test("Unknown owner and account changes never broaden search")
  func failsClosed() async throws {
    for response in [
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":null}}"#,
      #"{"data":{"viewer":{"id":"U2","login":"sam"},"repositoryOwner":{"id":"U1"}}}"#,
    ] {
      let runner = SourceRunner([response])
      let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
      await #expect(throws: GitHubReviewSourceError.self) {
        try await service.listPullRequests(
          query: GitHubReviewQuery(
            account: account,
            sources: [.owner(personal)]), limit: 300)
      }
      #expect(await runner.commands.count == 1)
    }
  }

  @Test("Result budgets report incomplete queues")
  func resultBudget() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"U1"}}}"#,
      page([pr(owner: "alex", number: 1)], next: "next"),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let result = try await service.listPullRequests(
      query: GitHubReviewQuery(
        account: account,
        sources: [.owner(personal)]), limit: 1)
    #expect(result.isTruncated)
    #expect(await runner.commands.count == 2)
  }

  @Test("An account change between pages discards the complete result")
  func midRequestAccountChange() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"U1"}}}"#,
      page([pr(owner: "alex", number: 1)], next: "next"),
      page([pr(owner: "alex", number: 2)], next: nil).replacingOccurrences(of: "U1", with: "U2"),
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    await #expect(throws: GitHubReviewSourceError.accountChanged) {
      try await service.listPullRequests(
        query: GitHubReviewQuery(
          account: account,
          sources: [.owner(personal)]), limit: 300)
    }
  }

  @Test("Source context uses the authenticated host and owner IDs")
  func context() async throws {
    let runner = SourceRunner([
      #"{"node_id":"U1","login":"alex","html_url":"https://code.example.test/alex"}"#,
      #"{"data":{"viewer":{"id":"U1","login":"alex","organizations":{"nodes":[{"id":"O1","login":"acme"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#,
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let context = try await service.reviewSourceContext()
    #expect(context.account == account)
    #expect(context.owners == [personal, company])
  }

  @Test("Cache identity includes account and host")
  func cacheIdentity() {
    let first = GitHubReviewQuery(account: account, sources: [.owner(personal)])
    let other = GitHubReviewQuery(
      account: GitHubReviewAccount(
        host: "other.example.test",
        nodeID: "U1", login: "alex"), sources: [.owner(personal)])
    #expect(first.cacheKey != other.cacheKey)
  }

  @Test("Project views narrow an owner source and retain drafts")
  func optionalProject() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"O1"}}}"#,
      page([pr(owner: "acme", number: 1, draft: true)], next: nil),
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"nodes":[{"id":"PR_acme_1","projectItems":{"nodes":[{"project":{"id":"P1"},"status":{"name":"Review"},"priority":null}]}}]}}"#,
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let view = GitHubProjectView(
      id: "V1", number: 1, name: "Review", filter: "is:pr status:Review -is:draft",
      layout: "TABLE_LAYOUT")
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    let result = try await service.listPullRequests(
      query: GitHubReviewQuery(
        account: account,
        sources: [.owner(company)], project: project, view: view), limit: 300)
    #expect(result.pullRequests.first?.projectStatus == "Review")
    #expect(result.pullRequests.first?.isDraft == true)
    let commands = await runner.commands
    #expect(commands[1].joined().contains("project:acme/1"))
    #expect(!commands[1].joined().contains("draft:"))
  }

  @Test("Permission and rate-limit failures stop without a broader retry")
  func noBroadeningOnFailure() async {
    for message in ["HTTP 403: inaccessible organisation", "HTTP 429: API rate limit exceeded"] {
      let service = GitHubProjectReviewService(runSourceCommand: { _ in
        throw GitHubCLIError.commandFailed(message)
      })
      await #expect(throws: GitHubCLIError.self) {
        try await service.listPullRequests(
          query: GitHubReviewQuery(
            account: account,
            sources: [.owner(company)]), limit: 300)
      }
    }
  }

  @Test("Local checkout identity requires the requested host and exact owner")
  func remoteIdentity() {
    let remote = "git@code.example.test:acme/shared.git"
    #expect(GitHubRepositoryIdentity(remoteURL: remote) == nil)
    #expect(
      GitHubRepositoryIdentity(remoteURL: remote, expectedHost: account.host)
        == GitHubRepositoryIdentity(owner: "acme", repository: "shared", host: account.host))
    #expect(
      GitHubRepositoryIdentity(remoteURL: remote, expectedHost: "another.example.test") == nil)
  }

  @Test("Pull request references accept only the explicit source host")
  func pullRequestHostIdentity() {
    let url = "https://code.example.test/acme/shared/pull/12/files"
    #expect(GitHubPullRequestURLReference(urlString: url) == nil)
    let reference = GitHubPullRequestURLReference(urlString: url, expectedHost: account.host)
    #expect(reference?.number == 12)
    #expect(
      reference?.belongs(
        to: GitHubRepositoryIdentity(
          owner: "acme", repository: "shared", host: account.host)) == true)
    #expect(
      reference?.belongs(
        to: GitHubRepositoryIdentity(
          owner: "acme", repository: "shared", host: "other.example.test")) == false)
    #expect(
      GitHubPullRequestURLReference(urlString: url, expectedHost: "other.example.test") == nil)
  }

  @Test("Optional Project membership remains required without a Status filter")
  func projectMembershipWithoutStatus() async throws {
    let runner = SourceRunner([
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"repositoryOwner":{"id":"O1"}}}"#,
      page([pr(owner: "acme", number: 1), pr(owner: "acme", number: 2)], next: nil),
      #"{"data":{"viewer":{"id":"U1","login":"alex"},"nodes":[{"id":"PR_acme_1","projectItems":{"nodes":[{"project":{"id":"P1"},"status":null,"priority":null}]}},{"id":"PR_acme_2","projectItems":{"nodes":[]}}]}}"#,
    ])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let view = GitHubProjectView(
      id: "V1", number: 1, name: "All work", filter: "is:pr", layout: "TABLE_LAYOUT")
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    let queue = try await service.listPullRequests(
      query: GitHubReviewQuery(
        account: account, sources: [.owner(company)], project: project, view: view),
      limit: 300)
    #expect(queue.pullRequests.map(\.number) == [1])
  }

  @Test("A Boolean OR Project view is rejected before search")
  func unsupportedProjectBooleanFilter() async {
    let runner = SourceRunner([])
    let service = GitHubProjectReviewService(runSourceCommand: { try await runner.run($0) })
    let view = GitHubProjectView(
      id: "V1", number: 1, name: "Alternative", filter: "is:pr OR author:alex",
      layout: "TABLE_LAYOUT")
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    do {
      _ = try await service.listPullRequests(
        query: GitHubReviewQuery(
          account: account, sources: [.owner(company)], project: project, view: view),
        limit: 300)
      Issue.record("Unsupported Boolean filter was accepted")
    } catch {
      #expect(error.localizedDescription.contains("cannot apply"))
    }
    #expect(await runner.commands.isEmpty)
  }

  @Test("Boolean detection handles parentheses and ignores quoted text")
  func projectBooleanDetection() {
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [])
    for (filter, expected) in [
      ("(is:pr)OR(author:alex)", true),
      ("is:pr OR (author:alex)", true),
      ("is:pr AND author:alex", true),
      (#"label:"OR" is:pr"#, false),
      (#"label:"team OR personal" is:pr"#, false),
    ] {
      let view = GitHubProjectView(
        id: "V1", number: 1, name: "View", filter: filter, layout: "TABLE_LAYOUT")
      let query = GitHubReviewQuery(
        account: account, sources: [.owner(company)], project: project, view: view)
      #expect(query.hasUnsupportedProjectFilter == expected)
    }
  }

  private func pr(owner: String, number: Int, draft: Bool = false) -> String {
    """
    {"__typename":"PullRequest","id":"PR_\(owner)_\(number)","number":\(number),"title":"Review \(number)",
    "url":"https://code.example.test/\(owner)/shared/pull/\(number)",
    "repository":{"name":"shared","nameWithOwner":"\(owner)/shared"},
    "author":{"login":"alex"},"updatedAt":"2026-11-16T09:00:00Z","isDraft":\(draft),"state":"OPEN"}
    """
  }
  private func page(_ nodes: [String], next: String?) -> String {
    let cursor = next.map { "\"\($0)\"" } ?? "null"
    return """
      {"data":{"viewer":{"id":"U1","login":"alex"},"search":{"nodes":[\(nodes.joined(separator: ","))],
      "pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)}}}}
      """
  }
}

private actor SourceRunner {
  var responses: [String]
  var commands: [[String]] = []
  init(_ responses: [String]) { self.responses = responses }
  func run(_ args: [String]) throws -> String {
    commands.append(args)
    guard !responses.isEmpty else { throw GitHubReviewSourceError.incompleteResponse }
    return responses.removeFirst()
  }
}
