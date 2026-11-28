import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Review source selection")
struct GitHubReviewSourceViewModelTests {
  @Test("Personal repositories need no Project; Mine remains an author filter")
  func independentAxes() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    #expect(model.projects.isEmpty)
    #expect(model.sourceLabel == "Personal")
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
    model.selectOwner(id: service.company.id)
    await model.sourceRefreshTask?.value
    model.setReviewScope(.mine)
    #expect(model.visiblePullRequests.map(\.id) == ["company-draft"])
    #expect(model.sourceLabel == "acme")
  }

  @Test("Source changes clear rows and invalidate selection before the next response")
  func scopeInvalidation() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    model.selectedPullRequestID = "personal-draft"
    let revision = model.sourceRevision
    model.selectOwner(id: service.company.id)
    #expect(model.pullRequests.isEmpty)
    #expect(model.selectedPullRequestID == nil)
    #expect(model.sourceRevision > revision)
    await model.sourceRefreshTask?.value
    #expect(model.pullRequests.map(\.id) == ["company-draft"])
  }

  @Test("Account switches discard the previous account's rows and author identity")
  func accountSwitch() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    service.account = GitHubReviewAccount(host: "second.example.test", nodeID: "U2", login: "sam")
    await model.reloadProjects()
    #expect(model.sourceAccount == service.account)
    #expect(model.viewerLogin == "sam")
    #expect(model.pullRequests.allSatisfy { $0.url.contains("second.example.test/sam/") })
  }

  @Test("Legacy review links remain quarantined across account switches")
  func quarantinesLegacyLinks() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let request = service.request(owner: service.company)
    let accountA = service.account.persistenceKey
    let accountB = "code.example.test/U2"
    for (id, accountKey) in [("legacy", String?.none), ("account-a", accountA), ("account-b", accountB)] {
      try await store.saveGitHubReviewSessionAssociation(
        GitHubReviewSessionAssociation(
          pullRequestID: id, pullRequestURL: request.url, provider: .codex,
          pendingID: nil, sessionID: id, projectPath: "/fixture/shared",
          sourceAccountKey: accountKey))
    }
    let model = GitHubReviewsViewModel(service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.hasUnverifiedReviewSessions)
    #expect(model.reviewSessionLaunches(for: request).map(\.sessionID) == ["account-a"])
    #expect(model.quarantinedReviewSessionIDs(provider: .codex) == ["legacy", "account-b"])
    service.account = GitHubReviewAccount(host: "code.example.test", nodeID: "U2", login: "sam")
    await model.reloadProjects()
    #expect(model.reviewSessionLaunches(for: request).map(\.sessionID) == ["account-b"])
    #expect(model.quarantinedReviewSessionIDs(provider: .codex) == ["legacy", "account-a"])
    let stored = try await store.githubReviewSessionAssociations()
    #expect(stored.count == 3)
    #expect(stored.first { $0.sessionID == "legacy" }?.sourceAccountKey == nil)
    let sessions = stored.map { CLISession(id: $0.sessionID!, projectPath: $0.projectPath) }
    let inventory = GitHubReviewSessionInventory(
      provider: .codex, sessions: sessions, pendingSessions: [],
      resolvedPendingSessionIDs: [:], customNames: [:], statuses: [:])
    let launches = stored.compactMap(GitHubReviewSessionLaunch.init)
    for (accountKey, expected) in [(accountA, "account-a"), (accountB, "account-b")] {
      let links = GitHubReviewSessionLinker.links(
        for: request, launches: launches, inventories: [inventory], sourceAccountKey: accountKey)
      #expect(links.map { $0.session.id } == [expected])
    }
    var ticketInventory = inventory
    ticketInventory.ticketKeysBySessionID = ["legacy": ["DEMO-12"]]
    ticketInventory.repositoryIdentities = ["/fixture/shared": [
      GitHubRepositoryIdentity(owner: "acme", repository: "shared", host: service.account.host)
    ]]
    ticketInventory.quarantinedSessionIDs = model.quarantinedReviewSessionIDs(provider: .codex)
    // Use a fresh lookup because the inventory's matching inputs changed.
    let freshInventory = GitHubReviewSessionInventory(
      provider: .codex, sessions: sessions, pendingSessions: [],
      resolvedPendingSessionIDs: [:], customNames: [:], statuses: [:],
      ticketKeysBySessionID: ticketInventory.ticketKeysBySessionID,
      repositoryIdentities: ticketInventory.repositoryIdentities,
      quarantinedSessionIDs: ticketInventory.quarantinedSessionIDs)
    let inferred = GitHubReviewSessionLinker.links(
      for: service.request(owner: service.company, title: "DEMO-12 Review"),
      launches: [], inventories: [freshInventory], sourceAccountKey: accountB)
    #expect(inferred.isEmpty)
  }

  @Test("A late response from the old source cannot replace the new source")
  func staleResponse() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    service.delayPersonal = true
    let oldRefresh = Task { await model.refreshPullRequests() }
    while !service.delayedRequestStarted { await Task.yield() }
    model.selectOwner(id: service.company.id)
    await model.sourceRefreshTask?.value
    await oldRefresh.value
    #expect(model.pullRequests.map(\.id) == ["company-draft"])
  }

  @Test("Relaunch restores only the verified account's saved source and queue")
  func restoresVerifiedAccount() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let workspace = GitHubReviewWorkspace(
      account: service.account, selectedOwnerID: service.company.id,
      enabledOwnerIDs: [service.personal.id, service.company.id], repositoryName: "",
      ownerLabels: [service.company.id: "Company"], projectID: nil, viewID: nil, queues: [:])
    try await store.saveReviewWorkspace(workspace)
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    #expect(model.pullRequests.isEmpty)
    await model.load()
    #expect(model.sourceLabel == "Company")
    #expect(model.pullRequests.map(\.id) == ["company-draft"])
    service.account = GitHubReviewAccount(host: "code.example.test", nodeID: "U2", login: "sam")
    await model.reloadProjects()
    #expect(model.sourceLabel == "Personal")
    #expect(model.ownerLabels.isEmpty)
  }

  @Test("A renamed account restores choices and the previously cached queue")
  func renamedAccountRestoresWorkspace() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let originalAccount = service.account
    let originalOwner = service.personal
    let query = GitHubReviewQuery(account: originalAccount, sources: [.owner(originalOwner)])
    let cached = GitHubReviewWorkspace.CachedQueue(
      pullRequests: [service.request(owner: originalOwner)],
      updatedAt: Date(timeIntervalSince1970: 1), isTruncated: false)
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: originalAccount, selectedOwnerID: originalOwner.id,
        enabledOwnerIDs: [originalOwner.id, service.company.id], repositoryName: "",
        ownerLabels: [originalOwner.id: "My work"], projectID: nil, viewID: nil,
        queues: [query.cacheKey: cached]))
    service.account = GitHubReviewAccount(
      host: originalAccount.host, nodeID: originalAccount.nodeID, login: "new-alex")
    service.error = GitHubCLIError.commandFailed("HTTP 403: resource is inaccessible")
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.ownerLabels[originalOwner.id] == "My work")
    #expect(model.enabledOwnerIDs == [originalOwner.id, service.company.id])
    #expect(model.sourceOwners.first(where: \.isPersonal)?.login == "new-alex")
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
    #expect(model.isShowingCachedPullRequests)
  }

  @Test("A changed Project view cannot reuse a cache from its earlier filter")
  func changedProjectFilterDoesNotRestoreOldCache() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let oldView = GitHubProjectView(
      id: "V1", number: 1, name: "Review", filter: "status:Review", layout: "TABLE_LAYOUT")
    let newView = GitHubProjectView(
      id: "V1", number: 1, name: "Review", filter: "status:Done", layout: "TABLE_LAYOUT")
    func project(_ view: GitHubProjectView) -> GitHubReviewProject {
      GitHubReviewProject(
        id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
        title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    }
    let oldProject = project(oldView)
    let newProject = project(newView)
    let oldQuery = GitHubReviewQuery(
      account: service.account, sources: [.owner(service.personal)],
      project: oldProject, view: oldView)
    let newQuery = GitHubReviewQuery(
      account: service.account, sources: [.owner(service.personal)],
      project: newProject, view: newView)
    let oldQueue = GitHubReviewWorkspace.CachedQueue(
      pullRequests: [service.request(owner: service.personal)],
      updatedAt: .now, isTruncated: false)
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: service.account, selectedOwnerID: service.personal.id,
        enabledOwnerIDs: [service.personal.id], repositoryName: "", ownerLabels: [:],
        projectID: oldProject.id, viewID: oldView.id, queues: [oldQuery.cacheKey: oldQueue]))
    service.availableProjects = [newProject]
    service.error = GitHubCLIError.commandFailed("HTTP 403: resource is inaccessible")
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.selectedProjectID == newProject.id)
    #expect(model.selectedViewID == newView.id)
    #expect(model.pullRequests.isEmpty)
    #expect(!model.isShowingCachedPullRequests)
    model.setOwnerLabel("Work", for: service.personal.id)
    let saved = await store.waitForSave(after: 1)
    #expect(saved.queues[oldQuery.cacheKey] == oldQueue)
    #expect(saved.queues[newQuery.cacheKey] == nil)
  }

  @Test("Account rename keeps a Project queue when its filter is unchanged")
  func renamedAccountKeepsUnchangedProjectCache() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let oldAccount = service.account
    let oldOwner = service.personal
    let view = GitHubProjectView(
      id: "V1", number: 1, name: "Review", filter: "status:Review", layout: "TABLE_LAYOUT")
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    let query = GitHubReviewQuery(
      account: oldAccount, sources: [.owner(oldOwner)], project: project, view: view)
    let cached = GitHubReviewWorkspace.CachedQueue(
      pullRequests: [service.request(owner: oldOwner)], updatedAt: .now, isTruncated: false)
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: oldAccount, selectedOwnerID: oldOwner.id,
        enabledOwnerIDs: [oldOwner.id], repositoryName: "", ownerLabels: [:],
        projectID: project.id, viewID: view.id, queues: [query.cacheKey: cached]))
    service.account = GitHubReviewAccount(
      host: oldAccount.host, nodeID: oldAccount.nodeID, login: "new-alex")
    service.availableProjects = [project]
    service.error = GitHubCLIError.commandFailed("HTTP 403: resource is inaccessible")
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.sourceAccount == service.account)
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
    #expect(model.isShowingCachedPullRequests)
  }

  @Test("An unsupported Project view never restores an old cached queue")
  func unsupportedProjectDoesNotRestoreCache() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let view = GitHubProjectView(
      id: "V1", number: 1, name: "Alternative", filter: "is:pr OR author:alex",
      layout: "TABLE_LAYOUT")
    let project = GitHubReviewProject(
      id: "P1", ownerLogin: "acme", ownerType: "Organization", number: 1,
      title: "Delivery", url: "https://code.example.test/orgs/acme/projects/1", views: [view])
    service.availableProjects = [project]
    let query = GitHubReviewQuery(
      account: service.account, sources: [.owner(service.personal)], project: project, view: view)
    let cached = GitHubReviewWorkspace.CachedQueue(
      pullRequests: [service.request(owner: service.personal)],
      updatedAt: .now, isTruncated: false)
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: service.account, selectedOwnerID: service.personal.id,
        enabledOwnerIDs: [service.personal.id], repositoryName: "", ownerLabels: [:],
        projectID: project.id, viewID: view.id, queues: [query.cacheKey: cached]))
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.selectedProjectID == project.id)
    #expect(model.selectedViewID == view.id)
    #expect(model.pullRequests.isEmpty)
    #expect(!model.isShowingCachedPullRequests)
    #expect(model.recoveryIssue?.message.contains("cannot apply") == true)
  }

  @Test("Permission errors preserve a visibly stale queue; authentication errors clear it")
  func errorRecovery() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    service.error = GitHubCLIError.commandFailed("HTTP 403: resource is inaccessible")
    await model.refreshPullRequests()
    #expect(model.isShowingCachedPullRequests)
    #expect(!model.pullRequests.isEmpty)
    service.error = GitHubCLIError.notAuthenticated
    await model.refreshPullRequests()
    #expect(model.pullRequests.isEmpty)
    #expect(model.sourceAccount == nil)
  }

  @Test("An unavailable saved owner does not fall back to Personal")
  func inaccessibleOwner() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: service.account,
        selectedOwnerID: "code.example.test/missing", enabledOwnerIDs: [], repositoryName: "",
        ownerLabels: [:], projectID: nil, viewID: nil, queues: [:]))
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(service.queueCalls == 0)
    #expect(model.pullRequests.isEmpty)
    #expect(model.recoveryIssue != nil)
    #expect(model.sourceAccount == service.account)
    #expect(model.sourceOwners == [service.personal, service.company])
    model.selectOwner(id: service.personal.id)
    await model.sourceRefreshTask?.value
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
  }

  @Test("All selected sources requires explicit repair when a saved owner is unavailable")
  func repairsUnavailableMembership() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: service.account, selectedOwnerID: nil,
        enabledOwnerIDs: [service.personal.id, "code.example.test/missing"],
        repositoryName: "", ownerLabels: [:], projectID: nil, viewID: nil, queues: [:]))
    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(service.queueCalls == 0)
    #expect(model.hasUnavailableSources)
    model.removeUnavailableSources()
    await model.sourceRefreshTask?.value
    #expect(!model.hasUnavailableSources)
    #expect(model.sourceLabel == "All selected sources")
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
  }

  @Test("An oversized saved selection can be reduced, and adding stops at the source limit")
  func repairsOversizedMembership() async throws {
    let service = ReviewSourceStub()
    let store = SourceWorkspaceStore()
    let maximum = GitHubReviewQuery.maximumSourceCount
    let owners = (0..<(maximum + 3)).map { index in
      GitHubReviewOwner(
        account: service.account, nodeID: "org-\(index)", login: "org-\(index)", isPersonal: false)
    }
    service.additionalOwners = owners
    try await store.saveReviewWorkspace(
      GitHubReviewWorkspace(
        account: service.account, selectedOwnerID: nil,
        enabledOwnerIDs: Set(owners.prefix(maximum + 2).map(\.id)), repositoryName: "",
        ownerLabels: [:], projectID: nil, viewID: nil, queues: [:]))

    let model = GitHubReviewsViewModel(
      service: service, sessionStore: store, userDefaults: defaults())
    await model.load()
    #expect(model.isAllSourcesOverLimit)
    #expect(!model.canEnableAnotherOwner)
    #expect(service.queueCalls == 0)

    model.setOwnerEnabled(owners[maximum + 1].id, enabled: false)
    await model.sourceRefreshTask?.value
    #expect(model.isAllSourcesOverLimit)
    #expect(service.queueCalls == 0)
    let saved = await store.waitForSave(after: 1)
    #expect(saved.enabledOwnerIDs.count == maximum + 1)

    model.setOwnerEnabled(owners[maximum].id, enabled: false)
    await model.sourceRefreshTask?.value
    #expect(!model.isAllSourcesOverLimit)
    #expect(model.selectedSources.count == maximum)
    #expect(service.queueCalls == 1)

    let revisionAtLimit = model.sourceRevision
    model.setOwnerEnabled(owners[maximum + 2].id, enabled: true)
    #expect(!model.enabledOwnerIDs.contains(owners[maximum + 2].id))
    #expect(model.sourceRevision == revisionAtLimit)

    model.setOwnerEnabled(owners[0].id, enabled: false)
    #expect(model.canEnableAnotherOwner)
    model.setOwnerEnabled(owners[maximum + 2].id, enabled: true)
    await model.sourceRefreshTask?.value
    #expect(model.enabledOwnerIDs.contains(owners[maximum + 2].id))
    #expect(model.selectedSources.count == maximum)
  }

  @Test("Optional Project permissions cannot block owner repositories")
  func optionalProjectPermission() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    service.projectError = GitHubCLIError.commandFailed("HTTP 403: read:project unavailable")
    await model.loadOptionalProjects()
    #expect(model.projectErrorMessage != nil)
    #expect(model.recoveryIssue == nil)
    #expect(model.sourceAccount == service.account)
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
    await model.refreshPullRequests()
    #expect(model.pullRequests.map(\.id) == ["personal-draft"])
  }

  @Test("Optional Project account failures clear the queue and cancel old refreshes")
  func optionalProjectAccountFailure() async {
    for failure: Error in [
      GitHubReviewSourceError.accountChanged, GitHubCLIError.notAuthenticated,
    ] {
      let service = ReviewSourceStub()
      let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
      await model.load()
      service.delayPersonal = true
      let oldRefresh = Task { await model.refreshPullRequests() }
      while !service.delayedRequestStarted { await Task.yield() }
      service.projectError = failure
      await model.loadOptionalProjects()
      await oldRefresh.value
      #expect(model.sourceAccount == nil)
      #expect(model.pullRequests.isEmpty)
      #expect(model.selectedDetail == nil)
      #expect(model.recoveryIssue != nil)
    }
  }

  @Test("A nil workspace read cannot restore an account after Project authentication fails")
  func staleNilWorkspaceCannotRestoreAccount() async {
    for failure: Error in [
      GitHubReviewSourceError.accountChanged, GitHubCLIError.notAuthenticated,
    ] {
      let service = ReviewSourceStub()
      let store = SuspendedNilWorkspaceStore()
      let model = GitHubReviewsViewModel(
        service: service, sessionStore: store, userDefaults: defaults())
      let loading = Task { await model.load() }
      await store.waitUntilReading()
      model.selectedPullRequestID = "old-selection"
      service.projectError = failure
      await model.loadOptionalProjects()
      #expect(model.sourceAccount == nil)
      #expect(model.recoveryIssue != nil)
      await store.finishRead()
      await loading.value
      #expect(model.sourceAccount == nil)
      #expect(model.pullRequests.isEmpty)
      #expect(model.selectedPullRequestID == nil)
      #expect(model.selectedDetail == nil)
      #expect(model.recoveryIssue != nil)
      #expect(service.queueCalls == 0)
    }
  }

  @Test("Launching rechecks the actual authenticated account")
  func launchAccountValidation() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    let request = service.request(owner: service.personal)
    #expect(await model.validateReviewLaunch(request) == service.account)
    service.account = GitHubReviewAccount(host: "code.example.test", nodeID: "U2", login: "sam")
    #expect(await model.validateReviewLaunch(request) == nil)
    #expect(model.sourceAccount == nil)
    #expect(model.pullRequests.isEmpty)
  }

  @Test("A source change while launch validation waits cancels that launch")
  func launchScopeChange() async {
    let service = ReviewSourceStub()
    let model = GitHubReviewsViewModel(service: service, userDefaults: defaults())
    await model.load()
    service.pauseAccountValidation = true
    let launch = Task { await model.validateReviewLaunch(service.request(owner: service.personal)) }
    while service.accountContinuation == nil { await Task.yield() }
    model.selectOwner(id: service.company.id)
    service.accountContinuation?.resume(returning: service.account)
    service.accountContinuation = nil
    #expect(await launch.value == nil)
    await model.sourceRefreshTask?.value
    #expect(model.sourceLabel == "acme")
  }

  @Test("Prompts remain complete without a Project")
  func sourceNeutralPrompt() {
    let service = ReviewSourceStub()
    let prompt = GitHubProjectReviewPromptBuilder.prompt(
      pullRequest: service.request(owner: service.personal))
    #expect(prompt.contains("https://code.example.test/alex/shared/pull/1"))
    #expect(!prompt.contains("{{"))
    #expect(prompt.contains("Do not edit files, commit, push"))
  }

  @Test("Ticket links require the exact host and owner despite identical repository names")
  func scopedAutomaticLinks() {
    let service = ReviewSourceStub()
    let request = service.request(owner: service.company, title: "DEMO-12 Review")
    let session = CLISession(
      id: "ticket-session", projectPath: "/fixture/shared", branchName: "DEMO-12",
      lastActivityAt: Date(timeIntervalSince1970: 10))
    for identity in [
      GitHubRepositoryIdentity(owner: "alex", repository: "shared", host: service.account.host),
      GitHubRepositoryIdentity(owner: "acme", repository: "shared", host: "other.example.test"),
      GitHubRepositoryIdentity(owner: "acme", repository: "shared", host: service.account.host),
    ] {
      let inventory = GitHubReviewSessionInventory(
        provider: .codex, sessions: [session], pendingSessions: [],
        resolvedPendingSessionIDs: [:], customNames: [:], statuses: [:],
        ticketKeysBySessionID: [session.id: ["DEMO-12"]],
        repositoryIdentities: [session.projectPath: [identity]])
      let links = GitHubReviewSessionLinker.links(
        for: request, launches: [], inventories: [inventory],
        sourceAccountKey: service.account.persistenceKey)
      #expect(
        links.count == (identity.owner == "acme" && identity.host == service.account.host ? 1 : 0))
    }
  }

  @Test("A known origin from another account cannot link through the same PR URL")
  func scopedOriginLink() {
    let service = ReviewSourceStub()
    let request = service.request(owner: service.company)
    let session = CLISession(
      id: "review-session", projectPath: "/fixture/shared", branchName: "main",
      lastActivityAt: Date(timeIntervalSince1970: 10),
      firstMessage: "Review this pull request independently: \(request.url)")
    for accountKey in [service.account.persistenceKey, "code.example.test/U2", String?.none] {
      let inventory = GitHubReviewSessionInventory(
        provider: .codex, sessions: [session], pendingSessions: [],
        resolvedPendingSessionIDs: [:], customNames: [:], statuses: [:],
        sourceOrigins: accountKey.map { [
          session.id: SessionLaunchOrigin(
            source: .pullRequest, accountID: $0, sourceID: request.reviewIdentity,
            key: "#1", title: request.title)
        ] } ?? [:])
      let links = GitHubReviewSessionLinker.links(
        for: request, launches: [], inventories: [inventory],
        sourceAccountKey: service.account.persistenceKey)
      #expect(links.count == (accountKey == service.account.persistenceKey ? 1 : 0))
    }
  }

  private func defaults() -> UserDefaults {
    UserDefaults(suiteName: "tes322.\(UUID().uuidString)")!
  }
}

private final class ReviewSourceStub: GitHubProjectReviewServiceProtocol, @unchecked Sendable {
  var account = GitHubReviewAccount(host: "code.example.test", nodeID: "U1", login: "alex")
  var error: Error?
  var projectError: Error?
  var availableProjects: [GitHubReviewProject] = []
  var additionalOwners: [GitHubReviewOwner] = []
  var pauseAccountValidation = false
  var accountContinuation: CheckedContinuation<GitHubReviewAccount, Never>?
  var delayPersonal = false
  var delayedRequestStarted = false
  var queueCalls = 0
  var personal: GitHubReviewOwner {
    GitHubReviewOwner(
      account: account, nodeID: account.nodeID, login: account.login, isPersonal: true)
  }
  var company: GitHubReviewOwner {
    GitHubReviewOwner(account: account, nodeID: "O1", login: "acme", isPersonal: false)
  }
  func reviewSourceContext() async throws -> GitHubReviewSourceContext {
    GitHubReviewSourceContext(account: account, owners: [personal, company] + additionalOwners)
  }
  func reviewAccount() async throws -> GitHubReviewAccount {
    if pauseAccountValidation {
      return await withCheckedContinuation { accountContinuation = $0 }
    }
    return account
  }
  func listProjects() async throws -> [GitHubReviewProject] {
    if let projectError { throw projectError }
    return availableProjects
  }
  func listPullRequests(project: GitHubReviewProject, view: GitHubProjectView, limit: Int)
    async throws
    -> [GitHubProjectPullRequest]
  { [] }
  func listPullRequests(query: GitHubReviewQuery, limit: Int) async throws -> GitHubReviewQueue {
    queueCalls += 1
    if query.hasUnsupportedProjectFilter { throw GitHubReviewSourceError.unsupportedProjectFilter }
    if let error { throw error }
    let result = query.sources.map { request(owner: $0.owner) }
    if delayPersonal, query.sources.first?.owner.isPersonal == true {
      delayedRequestStarted = true
      try? await Task.sleep(for: .milliseconds(50))
    }
    return GitHubReviewQueue(pullRequests: result)
  }
  func request(owner: GitHubReviewOwner, title: String = "Retain explicit source identity")
    -> GitHubProjectPullRequest
  {
    GitHubProjectPullRequest(
      id: owner.isPersonal ? "personal-draft" : "company-draft", number: 1,
      title: title,
      url: "https://\(owner.account.host)/\(owner.login)/shared/pull/1",
      repositoryName: "shared", repositoryNameWithOwner: "\(owner.login)/shared",
      authorLogin: account.login, updatedAt: .now, isDraft: true, state: "OPEN", projectStatus: nil)
  }
}

private actor SourceWorkspaceStore: GitHubReviewSessionStoreProtocol {
  var associations: [GitHubReviewSessionAssociation] = []
  var workspaces: [String: GitHubReviewWorkspace] = [:]
  var saveCount = 0
  var saveWaiter: CheckedContinuation<GitHubReviewWorkspace, Never>?
  func saveGitHubReviewSessionAssociation(_ association: GitHubReviewSessionAssociation)
    async throws
  { associations.append(association) }
  func githubReviewSessionAssociations() async throws -> [GitHubReviewSessionAssociation] { associations }
  func reviewWorkspace(account: GitHubReviewAccount) async throws -> GitHubReviewWorkspace? {
    workspaces[account.persistenceKey]
  }
  func saveReviewWorkspace(_ workspace: GitHubReviewWorkspace) async throws {
    workspaces[workspace.account.persistenceKey] = workspace
    saveCount += 1
    saveWaiter?.resume(returning: workspace)
    saveWaiter = nil
  }
  func waitForSave(after count: Int) async -> GitHubReviewWorkspace {
    if saveCount > count, let workspace = workspaces.values.first { return workspace }
    return await withCheckedContinuation { saveWaiter = $0 }
  }
}

private actor SuspendedNilWorkspaceStore: GitHubReviewSessionStoreProtocol {
  private var readContinuation: CheckedContinuation<GitHubReviewWorkspace?, Never>?
  private var readingWaiter: CheckedContinuation<Void, Never>?
  func saveGitHubReviewSessionAssociation(_ association: GitHubReviewSessionAssociation)
    async throws
  {}
  func githubReviewSessionAssociations() async throws -> [GitHubReviewSessionAssociation] { [] }
  func reviewWorkspace(account: GitHubReviewAccount) async throws -> GitHubReviewWorkspace? {
    await withCheckedContinuation {
      readContinuation = $0
      readingWaiter?.resume()
      readingWaiter = nil
    }
  }
  func saveReviewWorkspace(_ workspace: GitHubReviewWorkspace) async throws {}
  func waitUntilReading() async {
    if readContinuation != nil { return }
    await withCheckedContinuation { readingWaiter = $0 }
  }
  func finishRead() {
    readContinuation?.resume(returning: nil)
    readContinuation = nil
  }
}

@MainActor
@Suite("Review launch repository identity")
struct ReviewLaunchRepositoryTests {
  @Test("Same-name checkouts route by host and owner, never by directory name")
  func exactRepository() async {
    let service = ReviewSourceStub()
    let request = service.request(owner: service.company)
    let resolver = ReviewRepositoryResolver(identities: [
      "/fixture/personal/shared": GitHubRepositoryIdentity(
        owner: "alex", repository: "shared", host: service.account.host),
      "/fixture/company/renamed": GitHubRepositoryIdentity(
        owner: "acme", repository: "shared", host: service.account.host),
      "/fixture/other-host/shared": GitHubRepositoryIdentity(
        owner: "acme", repository: "shared", host: "another.example.test"),
    ])
    let path = await WorkspaceLaunchActions.reviewRepositoryPath(
      pullRequest: request,
      repositories: [
        SelectedRepository(path: "/fixture/personal/shared"),
        SelectedRepository(path: "/fixture/other-host/shared"),
        SelectedRepository(path: "/fixture/company/renamed"),
      ],
      resolver: resolver)
    #expect(path == "/fixture/company/renamed")
    #expect(
      await WorkspaceLaunchActions.reviewRepositoryPath(
        pullRequest: request,
        repositories: [SelectedRepository(path: "/fixture/personal/shared")], resolver: resolver)
        == nil)
  }
}

private actor ReviewRepositoryResolver: GitHubRepositoryIdentityResolverProtocol {
  let identities: [String: GitHubRepositoryIdentity]
  init(identities: [String: GitHubRepositoryIdentity]) { self.identities = identities }
  func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity? {
    identities[projectPath]
  }
}
