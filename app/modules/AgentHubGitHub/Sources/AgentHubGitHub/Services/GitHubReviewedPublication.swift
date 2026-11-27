import Foundation

/// The publication flow names the repository on every request so changing the
/// worktree's GitHub defaults cannot redirect an approved operation.
public protocol GitHubReviewedPublishing: Sendable {
  func publicationBase(in repository: GitHubRepositoryIdentity) async throws -> String
  func publicationPullRequest(
    in repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> GitHubPublishedPullRequest?
}

public struct GitHubPublishedPullRequest: Equatable, Sendable {
  public let number: Int
  public let url: URL
  public let head: String
  public let branch: String
  public let base: String
  public let baseOID: String

  public init(number: Int, url: URL, head: String, branch: String, base: String, baseOID: String) {
    self.number = number
    self.url = url
    self.head = head
    self.branch = branch
    self.base = base
    self.baseOID = baseOID
  }
}

extension GitHubCLIService: GitHubReviewedPublishing {
  public func publicationBase(in repository: GitHubRepositoryIdentity) async throws -> String {
    let response = try await publicationAPI(repository, endpoint: "")
    return try JSONDecoder().decode(PublicationRepository.self, from: response).defaultBranch
  }

  public func publicationPullRequest(
    in repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> GitHubPublishedPullRequest? {
    let response = try await publicationAPI(
      repository, endpoint: "/pulls",
      arguments: ["--method", "GET", "--raw-field", "state=all", "--raw-field",
                  "head=\(repository.owner):\(branch)"])
    return try Self.decodePublicationPullRequest(response, repository: repository, branch: branch)
  }

  static func decodePublicationPullRequest(
    _ response: Data, repository: GitHubRepositoryIdentity, branch: String
  ) throws -> GitHubPublishedPullRequest? {
    try JSONDecoder().decode([PublicationPullRequest].self, from: response).sorted { lhs, rhs in
      let lhsOpen = lhs.state == "open"
      let rhsOpen = rhs.state == "open"
      return lhsOpen == rhsOpen ? lhs.number > rhs.number : lhsOpen
    }.first.map {
      try $0.verified(repository: repository, branch: branch)
    }
  }

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

  func verified(
    repository: GitHubRepositoryIdentity, branch: String
  ) throws -> GitHubPublishedPullRequest {
    let name = "\(repository.owner)/\(repository.repository)"
    guard head.ref.utf8.elementsEqual(branch.utf8), url.scheme == "https",
      let reference = GitHubPullRequestURLReference(urlString: url.absoluteString, expectedHost: repository.host),
      reference.number == number, reference.belongs(to: repository),
      head.repo?.fullName.caseInsensitiveCompare(name) == .orderedSame,
      base.repo?.fullName.caseInsensitiveCompare(name) == .orderedSame
    else { throw GitHubCLIError.parseError("GitHub returned a pull request for a different repository or branch.") }
    return .init(number: number, url: url, head: head.sha, branch: head.ref, base: base.ref, baseOID: base.sha)
  }
}
