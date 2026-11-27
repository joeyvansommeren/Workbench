import AgentHubGitHub
import Foundation

struct PullRequestCheckout: Equatable, Sendable {
  let root: String
  let remote: GitHubRepositoryIdentity
  let branch: String
  let head: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.root.utf8.elementsEqual(rhs.root.utf8) && lhs.remote == rhs.remote
      && lhs.branch.utf8.elementsEqual(rhs.branch.utf8) && lhs.head == rhs.head
  }
}

protocol PullRequestPublicationGit: Sendable {
  func origin(_ context: PullRequestContext) throws -> GitHubRepositoryIdentity
  func checkout(_ context: PullRequestContext) throws -> PullRequestCheckout
  func files(_ checkout: PullRequestCheckout, base: String) throws -> [String]
}

struct ReviewedPullRequestGit: PullRequestPublicationGit {
  private let runner: any CommitGitRunning

  init(runner: any CommitGitRunning = CommitGitRunner()) {
    self.runner = runner
  }

  func checkout(_ context: PullRequestContext) throws -> PullRequestCheckout {
    let path = context.projectPath
    let root = try line(path, ["rev-parse", "--show-toplevel"])
    guard let branch = try? line(root, ["symbolic-ref", "--quiet", "--short", "HEAD"]) else {
      throw PullRequestPublicationError.detached
    }
    guard let expected = context.branch, branch.utf8.elementsEqual(expected.utf8) else {
      throw PullRequestPublicationError.wrongBranch
    }
    let remote = try origin(at: root)
    guard try run(root, ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z",
                         "--untracked-files=all", "--ignore-submodules=none"]).isEmpty else {
      throw PullRequestPublicationError.dirty
    }
    let head = try line(root, ["rev-parse", "--verify", "HEAD^{commit}"])
    return PullRequestCheckout(root: root, remote: remote, branch: branch, head: head)
  }

  func origin(_ context: PullRequestContext) throws -> GitHubRepositoryIdentity {
    let root = try line(context.projectPath, ["rev-parse", "--show-toplevel"])
    return try origin(at: root)
  }

  private func origin(at root: String) throws -> GitHubRepositoryIdentity {
    let fetchURL = try line(root, ["remote", "get-url", "--all", "origin"])
    let pushURL = try line(root, ["remote", "get-url", "--push", "--all", "origin"])
    guard let remote = Self.safeRemote(fetchURL), Self.safeRemote(pushURL) == remote else {
      throw PullRequestPublicationError.wrongRepository
    }
    return remote
  }

  func files(_ checkout: PullRequestCheckout, base: String) throws -> [String] {
    guard let mergeBase = try? line(checkout.root, ["merge-base", base, checkout.head]) else {
      throw PullRequestPublicationError.baseUnavailable
    }
    let output = try run(
      checkout.root, ["diff", "--name-only", "--no-renames", "--no-ext-diff", "--no-textconv",
                      "--ignore-submodules=none", "-z", mergeBase, checkout.head, "--"])
    let entries = output.split(separator: 0)
    guard let files = try? entries.map({ entry -> String in
      guard let file = String(data: Data(entry), encoding: .utf8) else {
        throw PullRequestPublicationError.gitUnavailable
      }
      return file
    }) else { throw PullRequestPublicationError.gitUnavailable }
    return files
  }

  private func line(_ path: String, _ arguments: [String]) throws -> String {
    guard let output = String(data: try run(path, arguments), encoding: .utf8) else {
      throw PullRequestPublicationError.gitUnavailable
    }
    return output.trimmingCharacters(in: .newlines)
  }

  private func run(_ path: String, _ arguments: [String]) throws -> Data {
    // Local object inspection must stay offline even in a partial clone.
    let environment = [
      "GIT_ALLOW_PROTOCOL": "",
      "GIT_NO_LAZY_FETCH": "1",
      "GIT_NO_REPLACE_OBJECTS": "1",
      "GIT_OPTIONAL_LOCKS": "0",
    ]
    let result = try runner.run(at: path, arguments: arguments, environment: environment, input: nil)
    guard result.status == 0 else { throw PullRequestPublicationError.gitUnavailable }
    return result.stdout
  }

  static func safeRemote(_ url: String) -> GitHubRepositoryIdentity? {
    let prefix = "git@github.com:"
    let path: String
    if url.hasPrefix(prefix) {
      path = String(url.dropFirst(prefix.count))
    } else if let parsed = URLComponents(string: url), parsed.scheme == "https",
      parsed.host == "github.com", parsed.user == nil, parsed.password == nil,
      parsed.port == nil, parsed.query == nil, parsed.fragment == nil
    {
      path = String(parsed.path.dropFirst())
    } else {
      return nil
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
    guard components.count == 2, components.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy(allowed.contains)
    }) else { return nil }
    return GitHubRepositoryIdentity(remoteURL: url)
  }
}
