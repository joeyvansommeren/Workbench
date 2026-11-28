import Foundation

/// CLI account identity. A connector login is not evidence of the CLI's account.
public struct GitHubReviewAccount: Codable, Hashable, Sendable {
  public let host: String
  public let nodeID: String
  public let login: String

  public var persistenceKey: String { "\(host)/\(nodeID)" }

  public init(host: String, nodeID: String, login: String) {
    self.host = host.lowercased()
    self.nodeID = nodeID
    self.login = login
  }
}

public struct GitHubReviewOwner: Codable, Hashable, Identifiable, Sendable {
  public let account: GitHubReviewAccount
  public let nodeID: String
  public let login: String
  public let isPersonal: Bool
  public var id: String { "\(account.host)/\(nodeID)" }

  public init(account: GitHubReviewAccount, nodeID: String, login: String, isPersonal: Bool) {
    self.account = account
    self.nodeID = nodeID
    self.login = login
    self.isPersonal = isPersonal
  }
}

public struct GitHubReviewRepository: Codable, Hashable, Sendable {
  public let owner: GitHubReviewOwner
  public let name: String
  public init(owner: GitHubReviewOwner, name: String) {
    self.owner = owner
    self.name = name
  }
  public var nameWithOwner: String { "\(owner.login)/\(name)" }
}

public enum GitHubReviewSource: Codable, Hashable, Sendable {
  case owner(GitHubReviewOwner)
  case repository(GitHubReviewRepository)

  public var owner: GitHubReviewOwner {
    switch self {
    case .owner(let owner): return owner
    case .repository(let repository): return repository.owner
    }
  }
  public var searchQualifier: String {
    switch self {
    case .owner(let owner): return "user:\(owner.login)"
    case .repository(let repository): return "repo:\(repository.nameWithOwner)"
    }
  }
  public func contains(_ request: GitHubProjectPullRequest) -> Bool {
    guard URL(string: request.url)?.host?.lowercased() == owner.account.host else { return false }
    switch self {
    case .owner(let owner):
      return request.repositoryNameWithOwner.split(separator: "/").first?
        .caseInsensitiveCompare(owner.login) == .orderedSame
    case .repository(let repository):
      return request.repositoryNameWithOwner.caseInsensitiveCompare(repository.nameWithOwner)
        == .orderedSame
    }
  }
}

public struct GitHubReviewSourceContext: Sendable {
  public let account: GitHubReviewAccount
  public let owners: [GitHubReviewOwner]
  public let isTruncated: Bool
  public init(account: GitHubReviewAccount, owners: [GitHubReviewOwner], isTruncated: Bool = false)
  {
    self.account = account
    self.owners = owners
    self.isTruncated = isTruncated
  }
}

public struct GitHubReviewQuery: Codable, Equatable, Sendable {
  public static let maximumSourceCount = 20

  public let account: GitHubReviewAccount
  public var sources: [GitHubReviewSource]
  public var project: GitHubReviewProject?
  public var view: GitHubProjectView?

  public init(
    account: GitHubReviewAccount, sources: [GitHubReviewSource],
    project: GitHubReviewProject? = nil, view: GitHubProjectView? = nil
  ) {
    self.account = account
    self.sources = sources
    self.project = project
    self.view = view
  }

  public var cacheKey: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(self).base64EncodedString()) ?? ""
  }

  public var hasUnsupportedProjectFilter: Bool {
    guard project != nil else { return false }
    return Self.filterTokens(in: view?.filter ?? "").contains {
      var unquoted = ""
      var isInsideQuotes = false
      for character in $0 {
        if character == "\"" {
          isInsideQuotes.toggle()
        } else if !isInsideQuotes {
          unquoted.append(character)
        }
      }
      return unquoted == "OR" || unquoted == "AND"
        || unquoted.contains("(") || unquoted.contains(")")
    }
  }

  static func filterTokens(in query: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var isInsideQuotes = false
    for character in query {
      if character == "\"" {
        isInsideQuotes.toggle()
        current.append(character)
      } else if character.isWhitespace, !isInsideQuotes {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }
}

public struct GitHubReviewQueue: Sendable {
  public let pullRequests: [GitHubProjectPullRequest]
  public let isTruncated: Bool
  public init(pullRequests: [GitHubProjectPullRequest], isTruncated: Bool = false) {
    self.pullRequests = pullRequests
    self.isTruncated = isTruncated
  }
}

public enum GitHubReviewSourceError: Error, LocalizedError, Equatable {
  case accountChanged
  case invalidSource
  case unavailableSource
  case incompleteResponse
  case unsupportedProjectFilter
  public var errorDescription: String? {
    switch self {
    case .accountChanged: return "The GitHub CLI account changed. Refresh sources to continue."
    case .invalidSource: return "Select an owner or repository from the current GitHub CLI account."
    case .unavailableSource:
      return "This GitHub source is unavailable. Check its name and your access, then retry."
    case .incompleteResponse: return "GitHub returned incomplete data. Refresh to try again."
    case .unsupportedProjectFilter:
      return "Reviews cannot apply this Project view filter. "
        + "Choose another view or remove the Project filter."
    }
  }
}

extension GitHubProjectPullRequest {
  /// Node IDs alone are not globally unique across GitHub hosts.
  public var reviewIdentity: String {
    "\(URL(string: url)?.host?.lowercased() ?? "")/\(repositoryNameWithOwner.lowercased())#\(number)"
  }
}
