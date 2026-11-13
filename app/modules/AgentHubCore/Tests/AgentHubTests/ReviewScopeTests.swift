import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

private final class ReviewScopeServiceStub: GitHubProjectReviewServiceProtocol, @unchecked Sendable {
  var pullRequests: [GitHubProjectPullRequest] = []
  var login: String?
  /// Answers for successive `viewerLogin()` calls; `login` once these run out.
  var loginSequence: [String?] = []
  var loginCalls = 0
  var detail: GitHubReviewDetail?

  func pullRequestDetail(_ request: GitHubProjectPullRequest) async throws -> GitHubReviewDetail {
    if let detail { return detail }
    throw GitHubCLIError.commandFailed("Detail unavailable")
  }
  func listProjects() async throws -> [GitHubReviewProject] {
    [
      GitHubReviewProject(
        id: "project", ownerLogin: "org", ownerType: "Organization", number: 1, title: "Reviews",
        url: "https://github.com/orgs/org/projects/1",
        views: [
          GitHubProjectView(id: "view", number: 1, name: "Code review", filter: "is:pr", layout: "TABLE_LAYOUT")
        ])
    ]
  }
  func listPullRequests(
    project: GitHubReviewProject, view: GitHubProjectView, limit: Int
  ) async throws -> [GitHubProjectPullRequest] { pullRequests }
  func rateLimitResetDate() async -> Date? { nil }
  func viewerLogin() async -> String? {
    loginCalls += 1
    return loginSequence.isEmpty ? login : loginSequence.removeFirst()
  }
}

@MainActor
@Suite("Review scope")
struct ReviewScopeTests {
  @Test("Requested excludes your own pull requests, Mine has only them, All has every one")
  func scopesSplitByAuthor() async {
    let model = await loadedModel(login: "Joey", authors: ["joey", "amaes", "jdewit", nil])

    #expect(model.pullRequests(in: .requested).map(\.id) == ["1", "2", "3"])
    #expect(model.pullRequests(in: .mine).map(\.id) == ["0"])
    #expect(model.pullRequests(in: .all).count == 4)
  }

  @Test("Counts follow the scopes")
  func counts() async {
    let model = await loadedModel(login: "joey", authors: ["joey", "joey", "amaes"])

    #expect(model.count(for: .requested) == 1)
    #expect(model.count(for: .mine) == 2)
    #expect(model.count(for: .all) == 3)
  }

  @Test("Mine uses isOwnPullRequest: with an unknown login it shows nothing and Requested shows all")
  func unknownLogin() async {
    let model = await loadedModel(login: nil, authors: ["joey", "amaes"])

    #expect(model.isOwnPullRequest(model.pullRequests[0]) == nil)
    #expect(model.pullRequests(in: .mine).isEmpty)
    #expect(model.count(for: .requested) == 2)
  }

  @Test("The scope is saved and restored")
  func scopePersists() {
    let defaults = isolatedDefaults()
    let model = GitHubReviewsViewModel(service: ReviewScopeServiceStub(), userDefaults: defaults)
    #expect(model.reviewScope == .requested)

    model.setReviewScope(.mine)

    #expect(defaults.string(forKey: AgentHubDefaults.reviewsScope) == "mine")
    let restored = GitHubReviewsViewModel(service: ReviewScopeServiceStub(), userDefaults: defaults)
    #expect(restored.reviewScope == .mine)
  }

  @Test("Visible rows apply scope and search, newest first")
  func visibleRows() async {
    let model = await loadedModel(login: "joey", authors: ["amaes", "joey", "jdewit"])
    model.setReviewScope(.all)
    #expect(model.visiblePullRequests.map(\.id) == ["2", "1", "0"])

    model.searchText = "jdewit"
    #expect(model.visiblePullRequests.map(\.id) == ["2"])

    model.setReviewScope(.mine)
    #expect(model.visiblePullRequests.isEmpty)
  }

  @Test("Jumping to a pull request outside the scope widens to All without saving it")
  func focusWidensScope() async {
    let defaults = isolatedDefaults()
    defaults.set("requested", forKey: AgentHubDefaults.reviewsScope)
    let model = await loadedModel(login: "joey", authors: ["joey", "amaes"], defaults: defaults)
    #expect(model.reviewScope == .requested)

    model.focusPullRequest(owner: "org", repository: "repo", number: 100)

    #expect(model.selectedPullRequestID == "0")
    #expect(model.reviewScope == .all)
    #expect(model.visiblePullRequests.map(\.id).contains("0"))
    #expect(defaults.string(forKey: AgentHubDefaults.reviewsScope) == "requested")
  }

  @Test("Jumping while the login is unknown widens to All, so your own PR stays listed")
  func focusWithUnknownLogin() async {
    let model = await loadedModel(login: nil, authors: ["joey", "amaes"])

    model.focusPullRequest(owner: "org", repository: "repo", number: 100)

    #expect(model.reviewScope == .all)
  }

  @Test("When the login arrives late, a selection that left the scope widens to All")
  func lateLoginKeepsSelectionVisible() async {
    let service = ReviewScopeServiceStub()
    service.loginSequence = [nil, "joey"]
    service.pullRequests = [pullRequest(index: 0, author: "joey"), pullRequest(index: 1, author: "amaes")]
    let defaults = isolatedDefaults()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults)
    await model.load()
    model.selectedPullRequestID = "0"
    #expect(model.reviewScope == .requested)

    await model.reloadProjects()

    #expect(model.viewerLogin == "joey")
    #expect(model.reviewScope == .all)
    #expect(defaults.string(forKey: AgentHubDefaults.reviewsScope) == nil)
  }

  @Test("Reload fetches the login again after a failed first fetch")
  func reloadRefetchesLogin() async {
    let service = ReviewScopeServiceStub()
    service.loginSequence = [nil, "joey"]
    service.pullRequests = [pullRequest(index: 0, author: "joey"), pullRequest(index: 1, author: "amaes")]
    let model = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())
    await model.load()
    #expect(model.viewerLogin == nil)
    #expect(model.pullRequests(in: .mine).isEmpty)

    await model.reloadProjects()

    #expect(model.viewerLogin == "joey")
    #expect(model.pullRequests(in: .mine).map(\.id) == ["0"])
    #expect(model.pullRequests(in: .requested).map(\.id) == ["1"])

    await model.reloadProjects()
    #expect(service.loginCalls == 2)
  }

  @Test("A loaded detail records the pull request's checks")
  func checksFromDetail() async throws {
    let service = ReviewScopeServiceStub()
    service.pullRequests = [pullRequest(index: 0, author: "amaes")]
    let json = #"{"number":1,"title":"T","state":"OPEN","url":"u","headRefName":"h","baseRefName":"main","isDraft":false,"additions":1,"deletions":0,"changedFiles":1,"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]}"#
    let pr = try JSONDecoder().decode(GitHubPullRequest.self, from: Data(json.utf8))
    service.detail = GitHubReviewDetail(pullRequest: pr, reviews: [], inlineComments: [])
    let model = GitHubReviewsViewModel(service: service, userDefaults: isolatedDefaults())
    await model.load()

    model.selectedPullRequestID = "0"
    await model.loadSelectedDetail()

    #expect(model.checksByPullRequestID["0"] == .failure)
  }

  // MARK: - Helpers

  private func loadedModel(
    login: String?, authors: [String?], defaults: UserDefaults? = nil
  ) async -> GitHubReviewsViewModel {
    let service = ReviewScopeServiceStub()
    service.login = login
    service.pullRequests = authors.enumerated().map { pullRequest(index: $0.offset, author: $0.element) }
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults ?? isolatedDefaults())
    await model.load()
    return model
  }

  private func pullRequest(index: Int, author: String?) -> GitHubProjectPullRequest {
    GitHubProjectPullRequest(
      id: "\(index)", number: 100 + index, title: "Pull request \(index)",
      url: "https://github.com/org/repo/pull/\(100 + index)", repositoryName: "repo",
      repositoryNameWithOwner: "org/repo", authorLogin: author,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 * (index + 1))),
      isDraft: false, state: "open", projectStatus: nil)
  }

  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "ReviewScopeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

@MainActor
@Suite("Reviews layout")
struct ReviewsLayoutTests {
  @Test("Reviews fits the shell's minimum window width")
  func fitsWindowMinimum() {
    let needed =
      DesignTokens.Width.sidebar + ReviewsLayout.minimumContentWidth + DesignTokens.Inset.panel
    #expect(needed <= ShellLayout.windowMinWidth)
  }
}
