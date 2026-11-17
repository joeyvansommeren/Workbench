import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

private actor MultipleRemoteResolver: GitHubRepositoryIdentityResolverProtocol {
  let identities: [String: Set<GitHubRepositoryIdentity>]
  init(_ identities: [String: Set<GitHubRepositoryIdentity>]) { self.identities = identities }
  func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity? { nil }
  func resolveIdentities(at projectPath: String, expectedHost: String) async -> Set<
    GitHubRepositoryIdentity
  > {
    identities[projectPath] ?? []
  }
}

@MainActor
@Suite("Review repository identities")
struct ReviewRepositoryIdentityTests {
  let request = GitHubProjectPullRequest(
    id: "1", number: 1, title: "DEMO-12 Review", url: "https://github.com/acme/shared/pull/1",
    repositoryName: "shared", repositoryNameWithOwner: "acme/shared", authorLogin: nil,
    updatedAt: nil, isDraft: false, state: "OPEN", projectStatus: nil)
  let fork = GitHubRepositoryIdentity(owner: "fork", repository: "shared")
  let upstream = GitHubRepositoryIdentity(owner: "acme", repository: "shared")
  let otherHost = GitHubRepositoryIdentity(
    owner: "acme", repository: "shared", host: "other.example")

  @Test("Launch selects upstream by full identity and rejects ambiguous checkouts")
  func launchSelection() async {
    let resolver = MultipleRemoteResolver([
      "/fork": [fork, upstream], "/other": [otherHost], "/second": [upstream],
    ])
    let first = await WorkspaceLaunchActions.reviewRepositoryPath(
      pullRequest: request,
      repositories: [SelectedRepository(path: "/other"), SelectedRepository(path: "/fork")],
      resolver: resolver)
    #expect(first == "/fork")
    let ambiguous = await WorkspaceLaunchActions.reviewRepositoryPath(
      pullRequest: request,
      repositories: [SelectedRepository(path: "/fork"), SelectedRepository(path: "/second")],
      resolver: resolver)
    #expect(ambiguous == nil)
  }

  @Test("Ticket links include upstream and exclude same names on another host")
  func links() {
    let session = CLISession(
      id: "s", projectPath: "/fork", branchName: "DEMO-12", lastActivityAt: Date())
    for identities in [Set([fork, upstream]), Set([fork, otherHost])] {
      let inventory = GitHubReviewSessionInventory(
        provider: .codex, sessions: [session], pendingSessions: [], resolvedPendingSessionIDs: [:],
        customNames: [:], statuses: [:], ticketKeysBySessionID: ["s": ["DEMO-12"]],
        repositoryIdentities: ["/fork": identities])
      let links = GitHubReviewSessionLinker.links(
        for: request, launches: [], inventories: [inventory], sourceAccountKey: "account")
      #expect(links.count == (identities.contains(upstream) ? 1 : 0))
    }
  }
}
