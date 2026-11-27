import Foundation

/// The publication flow names the repository on every request so changing the
/// worktree's GitHub defaults cannot redirect an approved operation.
public protocol GitHubReviewedPublishing: Sendable {
  func publicationBase(in repository: GitHubRepositoryIdentity) async throws -> String
  func publicationRefs(
    in repository: GitHubRepositoryIdentity, base: String, branch: String
  ) async throws -> GitHubPublicationRefs
  func publicationPullRequests(
    in repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> [GitHubPublishedPullRequest]
}

public struct GitHubPublicationRefs: Equatable, Sendable {
  public let base: String
  public let head: String?

  public init(base: String, head: String?) {
    self.base = base
    self.head = head
  }
}

public struct GitHubPublishedPullRequest: Equatable, Sendable {
  public let number: Int
  public let url: URL
  public let head: String
  public let branch: String
  public let base: String
  public let baseOID: String
  public let isOpen: Bool

  public init(
    number: Int, url: URL, head: String, branch: String, base: String, baseOID: String, isOpen: Bool = true
  ) {
    self.number = number
    self.url = url
    self.head = head
    self.branch = branch
    self.base = base
    self.baseOID = baseOID
    self.isOpen = isOpen
  }
}

extension GitHubCLIService: GitHubReviewedPublishing {
  public func publicationBase(in repository: GitHubRepositoryIdentity) async throws -> String {
    let response = try await publicationAPI(repository, endpoint: "")
    return try JSONDecoder().decode(PublicationRepository.self, from: response).defaultBranch
  }

  public func publicationRefs(
    in repository: GitHubRepositoryIdentity, base: String, branch: String
  ) async throws -> GitHubPublicationRefs {
    let output = try await runAuthenticatedCommand([
      "api", "--hostname", repository.host, "graphql", "--raw-field", "owner=\(repository.owner)",
      "--raw-field", "repo=\(repository.repository)", "--raw-field", "base=refs/heads/\(base)",
      "--raw-field", "head=refs/heads/\(branch)", "--raw-field", "query=" + Self.publicationRefsQuery,
    ])
    return try Self.decodePublicationRefs(Data(output.utf8), repository: repository, base: base, branch: branch)
  }

  public func publicationPullRequests(
    in repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> [GitHubPublishedPullRequest] {
    let response = try await publicationAPI(
      repository, endpoint: "/pulls",
      arguments: ["--method", "GET", "--paginate", "--slurp", "--raw-field", "state=all",
                  "--raw-field", "head=\(repository.owner):\(branch)"])
    return try Self.decodePublicationPullRequests(response, repository: repository, branch: branch)
  }

  static func decodePublicationRefs(
    _ response: Data, repository: GitHubRepositoryIdentity, base: String, branch: String
  ) throws -> GitHubPublicationRefs {
    let result = try JSONDecoder().decode(PublicationRefsResponse.self, from: response)
    let name = "\(repository.owner)/\(repository.repository)"
    guard result.errors?.isEmpty != false, let record = result.data?.repository,
      record.nameWithOwner.caseInsensitiveCompare(name) == .orderedSame,
      let baseRef = record.base, baseRef.name.utf8.elementsEqual(base.utf8),
      baseRef.target.isCommitID,
      record.head.map({ $0.name.utf8.elementsEqual(branch.utf8) && $0.target.isCommitID }) != false
    else { throw GitHubCLIError.parseError("GitHub did not confirm the expected repository and branch refs.") }
    return .init(base: baseRef.target.oid, head: record.head?.target.oid)
  }

  static func decodePublicationPullRequests(
    _ response: Data, repository: GitHubRepositoryIdentity, branch: String
  ) throws -> [GitHubPublishedPullRequest] {
    let pages = try JSONDecoder().decode([[PublicationPullRequest]].self, from: response)
    return try pages.flatMap { $0 }.compactMap {
      // Historical requests from forks or removed source repositories do not
      // belong to a same-repository handoff.
      if $0.state == "closed", !$0.matchesScope(repository: repository, branch: branch) { return nil }
      return try $0.verified(repository: repository, branch: branch)
    }.sorted { lhs, rhs in
      lhs.isOpen == rhs.isOpen ? lhs.number > rhs.number : lhs.isOpen
    }
  }

  private static let publicationRefsQuery = """
    query($owner: String!, $repo: String!, $base: String!, $head: String!) {
      repository(owner: $owner, name: $repo) {
        nameWithOwner
        base: ref(qualifiedName: $base) { name target { oid } }
        head: ref(qualifiedName: $head) { name target { oid } }
      }
    }
    """

  private func publicationAPI(
    _ repository: GitHubRepositoryIdentity, endpoint: String, arguments: [String] = []
  ) async throws -> Data {
    let output = try await runAuthenticatedCommand([
      "api", "--hostname", repository.host,
      "repos/\(repository.owner)/\(repository.repository)\(endpoint)",
    ] + arguments)
    return Data(output.utf8)
  }
}

private struct PublicationRefsResponse: Decodable {
  struct Failure: Decodable {
    let message: String
  }
  struct Payload: Decodable {
    let repository: Repository?
  }
  struct Repository: Decodable {
    let nameWithOwner: String
    let base: Reference?
    let head: Reference?
  }
  struct Reference: Decodable {
    let name: String
    let target: ObjectID
  }
  struct ObjectID: Decodable {
    let oid: String

    var isCommitID: Bool {
      oid.utf8.count == 40 && oid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
  }
  let data: Payload?
  let errors: [Failure]?
}

private struct PublicationRepository: Decodable {
  let defaultBranch: String

  enum CodingKeys: String, CodingKey {
    case defaultBranch = "default_branch"
  }
}

private struct PublicationPullRequest: Decodable {
  struct Branch: Decodable {
    struct Repository: Decodable {
      let fullName: String

      enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
      }
    }

    let ref: String
    let sha: String
    let repo: Repository?
  }

  let number: Int
  let state: String
  let url: URL
  let head: Branch
  let base: Branch

  enum CodingKeys: String, CodingKey {
    case number, state, head, base
    case url = "html_url"
  }

  func matchesScope(repository: GitHubRepositoryIdentity, branch: String) -> Bool {
    let name = "\(repository.owner)/\(repository.repository)"
    return head.ref.utf8.elementsEqual(branch.utf8)
      && head.repo?.fullName.caseInsensitiveCompare(name) == .orderedSame
      && base.repo?.fullName.caseInsensitiveCompare(name) == .orderedSame
  }

  func verified(
    repository: GitHubRepositoryIdentity, branch: String
  ) throws -> GitHubPublishedPullRequest {
    guard matchesScope(repository: repository, branch: branch), url.scheme == "https",
      state == "open" || state == "closed",
      let reference = GitHubPullRequestURLReference(urlString: url.absoluteString, expectedHost: repository.host),
      reference.number == number, reference.belongs(to: repository)
    else { throw GitHubCLIError.parseError("GitHub returned a pull request for a different repository or branch.") }
    return .init(
      number: number, url: url, head: head.sha, branch: head.ref, base: base.ref,
      baseOID: base.sha, isOpen: state == "open")
  }
}
