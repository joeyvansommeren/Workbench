//
//  GitHubReviewsViewModel.swift
//  AgentHub
//

import AgentHubGitHub
import Foundation
import Observation

@MainActor
@Observable
public final class GitHubReviewsViewModel {
  private let service: any GitHubProjectReviewServiceProtocol
  private let sessionStore: (any GitHubReviewSessionStoreProtocol)?
  private let defaults: UserDefaults
  private var didLoad = false
  private var didLoadSessionAssociations = false
  private var didAttemptLegacySessionRecovery = false
  private var refreshGeneration = 0
  private var cachedQueues: [String: GitHubReviewWorkspace.CachedQueue] = [:]
  private(set) var reviewRepositoryIdentities: [String: Set<GitHubRepositoryIdentity>] = [:]
  public private(set) var sourceAccount: GitHubReviewAccount?
  public private(set) var sourceOwners: [GitHubReviewOwner] = []
  public private(set) var selectedOwnerID: String?
  public private(set) var enabledOwnerIDs = Set<String>()
  public private(set) var repositoryName = ""
  public private(set) var ownerLabels: [String: String] = [:]
  public private(set) var sourceRevision = 0
  public private(set) var isQueueTruncated = false
  public private(set) var areOwnersTruncated = false
  public private(set) var projectErrorMessage: String?
  @ObservationIgnored private(set) var sourceRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var queueTask: Task<GitHubReviewQueue, Error>?
  @ObservationIgnored private var persistTask: Task<Void, Never>?

  private var reviewSessionLaunchesByPullRequestID: [String: [GitHubReviewSessionLaunch]] = [:] {
    didSet { linkedReferencesCache = [:] }
  }
  /// Every session card reads this on each render; with hundreds of launches the
  /// sort + URL parsing showed up in profiles. Rebuilt only when launches change.
  @ObservationIgnored private var linkedReferencesCache:
    [SessionProviderKind: [String: [GitHubPullRequestURLReference]]] = [:]

  public private(set) var projects: [GitHubReviewProject] = []
  public private(set) var selectedProjectID: String?
  public private(set) var selectedViewID: String?
  public private(set) var pullRequests: [GitHubProjectPullRequest] = []
  public private(set) var isLoadingProjects = false
  public private(set) var isLoadingPullRequests = false
  public private(set) var isShowingCachedPullRequests = false
  public private(set) var cachedPullRequestsUpdatedAt: Date?
  public private(set) var errorMessage: String?
  private(set) var recoveryIssue: GitHubReviewRecoveryIssue?
  public private(set) var sessionLinkErrorMessage: String?
  /// Pull request IDs with a review session launch in flight (prevents double starts).
  public private(set) var startingReviewPRIDs = Set<String>()

  // Table state lives here, not in the view: the Reviews view is rebuilt every
  // time the user comes back from a session, and @State would reset the order.
  public var searchText = "" { didSet { if oldValue != searchText { sourceRevision += 1 } } }
  var tableSortOrder = GitHubReviewTableRow.suggestedSortOrder
  /// The new shell's table sort; nil is the suggested order.
  var tableSort: ReviewsTableSort?
  public var selectedPullRequestID: String? {
    didSet {
      guard oldValue != selectedPullRequestID else { return }
      detailGeneration += 1
      selectedDetail = nil
      detailError = nil
      detailUpdatedAt = nil
      isLoadingDetail = false
    }
  }
  public private(set) var selectedDetail: GitHubReviewDetail?
  public private(set) var detailError: String?
  public private(set) var detailUpdatedAt: Date?
  public private(set) var isLoadingDetail = false
  private var detailGeneration = 0

  public func loadSelectedDetail() async {
    guard let account = sourceAccount,
      let request = pullRequests.first(where: { $0.id == selectedPullRequestID })
    else { return }
    detailGeneration += 1
    let generation = detailGeneration
    isLoadingDetail = true
    detailError = nil
    defer { if generation == detailGeneration { isLoadingDetail = false } }
    do {
      let detail = try await service.pullRequestDetail(request, account: account)
      guard !Task.isCancelled, generation == detailGeneration, selectedPullRequestID == request.id
      else { return }
      selectedDetail = detail
      detailUpdatedAt = Date()
      // GitHub's rollup rule, as the queue's batched fetch reports it, so the
      // row's icon does not change meaning when the detail loads.
      checksByPullRequestID[request.id] = detail.pullRequest.rollupCIStatus
    } catch {
      guard !Task.isCancelled, generation == detailGeneration else { return }
      if error as? GitHubReviewSourceError == .accountChanged { clearAccount() }
      detailError = error.localizedDescription
    }
  }
  /// Your GitHub login, so bulk review can skip your own pull requests.
  public private(set) var viewerLogin: String?

  // MARK: - New shell: scope and checks

  /// The Requested / Mine / All switch of the new shell's Reviews list.
  public private(set) var reviewScope: ReviewScope = .requested
  /// CI state per pull request ID. The queue itself (`gh search prs`) carries no
  /// checks, so a batched rollup fetch fills this after each queue refresh;
  /// loaded details update their own entry too.
  public private(set) var checksByPullRequestID: [String: CIStatus] = [:]
  /// The rollup fetch for the latest queue. A new refresh cancels the previous one.
  @ObservationIgnored private(set) var checksTask: Task<Void, Never>?
  /// Only the new shell's Reviews shows a Checks column, so only it turns this
  /// on (`ReviewsDestinationView`). Off, a queue refresh makes no checks
  /// calls: the legacy Reviews keeps its earlier network footprint.
  @ObservationIgnored var wantsQueueChecks = false {
    didSet {
      guard wantsQueueChecks, !oldValue, didLoad, !isLoadingPullRequests, !pullRequests.isEmpty
      else { return }
      // The queue was already loaded (by the legacy Reviews before a switch to
      // the new shell): fetch its checks now. Before the first load, the
      // queue refresh fetches them.
      refreshChecks(for: pullRequests.map(\.id))
    }
  }

  /// Fetches the CI rollup for the queue in the background. Runs once per queue
  /// refresh (no polling); failures are logged by the service and leave icons empty.
  private func refreshChecks(for pullRequestIDs: [String]) {
    checksTask?.cancel()
    guard wantsQueueChecks, !pullRequestIDs.isEmpty, let account = sourceAccount else {
      checksTask = nil
      return
    }
    let generation = refreshGeneration
    checksTask = Task { [service] in
      let states = await service.checkRollups(forPullRequestIDs: pullRequestIDs, account: account)
      guard !Task.isCancelled, generation == self.refreshGeneration, !states.isEmpty else { return }
      self.checksByPullRequestID.merge(states) { _, new in new }
    }
  }

  /// The user picked a scope: show it and save it as their default.
  public func setReviewScope(_ scope: ReviewScope) {
    guard scope != reviewScope else { return }
    reviewScope = scope
    sourceRevision += 1
    defaults.set(scope.rawValue, forKey: AgentHubDefaults.reviewsScope)
    MainThreadStallMonitor.breadcrumb("reviews scope: \(scope.rawValue)")
  }

  /// Widens to All when the selected pull request is not, or may soon not be,
  /// in the current scope: the new shell shows a selection only while it is
  /// listed. With an unknown login the PR may leave Requested once the login
  /// arrives. In memory only, so the user's saved default stays.
  private func widenScopeToShowSelection() {
    guard reviewScope != .all,
      let pullRequest = pullRequests.first(where: { $0.id == selectedPullRequestID })
    else { return }
    let isOwn = isOwnPullRequest(pullRequest)
    guard isOwn == nil || !reviewScope.includes(isOwn: isOwn) else { return }
    reviewScope = .all
    MainThreadStallMonitor.breadcrumb("reviews scope: all (show selection)")
  }

  /// The queue's pull requests in `scope`. Mine and Requested use `isOwnPullRequest`.
  func pullRequests(in scope: ReviewScope) -> [GitHubProjectPullRequest] {
    pullRequests.filter { scope.includes(isOwn: isOwnPullRequest($0)) }
  }

  func count(for scope: ReviewScope) -> Int {
    pullRequests(in: scope).count
  }

  /// The rows the new shell lists: the current scope, narrowed by `searchText`,
  /// newest first.
  var visiblePullRequests: [GitHubProjectPullRequest] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return pullRequests(in: reviewScope)
      .filter { pullRequest in
        guard !query.isEmpty else { return true }
        return pullRequest.title.localizedCaseInsensitiveContains(query)
          || String(pullRequest.number).contains(query)
          || pullRequest.repositoryNameWithOwner.localizedCaseInsensitiveContains(query)
          || (pullRequest.authorLogin ?? "").localizedCaseInsensitiveContains(query)
      }
      .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
  }

  /// Selects the pull request a session is linked to, e.g. when jumping in from a session.
  public func focusPullRequest(owner: String, repository: String, number: Int) {
    let nameWithOwner = "\(owner)/\(repository)"
    guard
      let pullRequest = pullRequests.first(where: {
        $0.number == number
          && $0.repositoryNameWithOwner.caseInsensitiveCompare(nameWithOwner) == .orderedSame
      })
    else { return }
    selectedPullRequestID = pullRequest.id
    widenScopeToShowSelection()
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty, !pullRequest.title.localizedCaseInsensitiveContains(query) {
      searchText = ""
    }
  }

  public var isRefreshing: Bool {
    isLoadingProjects || isLoadingPullRequests
  }

  public convenience init(
    service: any GitHubProjectReviewServiceProtocol,
    userDefaults: UserDefaults = .standard
  ) {
    self.init(service: service, sessionStore: nil, userDefaults: userDefaults)
  }

  init(
    service: any GitHubProjectReviewServiceProtocol,
    sessionStore: (any GitHubReviewSessionStoreProtocol)?,
    userDefaults: UserDefaults = .standard
  ) {
    self.service = service
    self.sessionStore = sessionStore
    defaults = userDefaults
    reviewScope =
      userDefaults.string(forKey: AgentHubDefaults.reviewsScope)
      .flatMap(ReviewScope.init(rawValue:)) ?? .requested

  }

  public var selectedProject: GitHubReviewProject? {
    projects.first { $0.id == selectedProjectID }
  }

  public var availableViews: [GitHubProjectView] {
    selectedProject?.views ?? []
  }

  public var selectedView: GitHubProjectView? {
    availableViews.first { $0.id == selectedViewID }
  }

  public var activeFilter: String {
    selectedView?.filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  var linkedSessionReferences: [AgentWorkspaceSessionReference] {
    var references: Set<AgentWorkspaceSessionReference> = []
    for launch in reviewSessionLaunchesByPullRequestID.values.flatMap({ $0 }) {
      guard let sessionID = launch.sessionID else { continue }
      references.insert(
        AgentWorkspaceSessionReference(
          provider: launch.provider,
          sessionId: sessionID,
          projectPath: launch.projectPath
        ))
    }
    return references.sorted {
      if $0.provider.rawValue == $1.provider.rawValue {
        return $0.sessionId < $1.sessionId
      }
      return $0.provider.rawValue < $1.provider.rawValue
    }
  }

  var shouldRecoverLegacySessionLinks: Bool {
    !didAttemptLegacySessionRecovery
  }

  public func load() async {
    guard !didLoad else { return }
    didLoad = true
    await loadSessionAssociations()
    await loadSources()
    if viewerLogin != nil {
      widenScopeToShowSelection()
    }
  }

  /// Whether `pullRequest` is yours. Unknown login → nil, so callers can refuse to guess.
  func isOwnPullRequest(_ pullRequest: GitHubProjectPullRequest) -> Bool? {
    guard let viewerLogin else { return nil }
    return pullRequest.authorLogin?.caseInsensitiveCompare(viewerLogin) == .orderedSame
  }

  /// Rows whose existing session should get a follow-up: others' PRs for a re-review,
  /// your own PRs for resolving requested changes. Each pairs with its most recent
  /// ready session; rows without one are left out.
  func followUpTargets(
    _ rows: [GitHubReviewTableRow],
    kind: GitHubReviewBulkFollowUp.Kind
  ) -> [GitHubReviewBulkFollowUp.Target] {
    rows.compactMap { row in
      guard let isOwn = isOwnPullRequest(row.pullRequest) else { return nil }
      guard isOwn == (kind == .resolveComments) else { return nil }
      guard let link = row.sessionLinks.first(where: { !$0.isPending }) else { return nil }
      return GitHubReviewBulkFollowUp.Target(pullRequest: row.pullRequest, link: link)
    }
  }

  /// Pull requests a bulk review should start on: authored by someone else.
  /// Empty while your login is unknown, so your own PRs are never included by accident.
  func bulkReviewCandidates(_ pullRequests: [GitHubProjectPullRequest]) -> [GitHubProjectPullRequest] {
    guard let viewerLogin else { return [] }
    return pullRequests.filter {
      $0.authorLogin?.caseInsensitiveCompare(viewerLogin) != .orderedSame
    }
  }

  func resolveReviewRepositoryIdentities(
    paths: [String],
    resolver: any GitHubRepositoryIdentityResolverProtocol = GitHubRepositoryIdentityResolver()
  ) async {
    guard let account = sourceAccount else { return }
    var identities: [String: Set<GitHubRepositoryIdentity>] = [:]
    for path in Set(paths).sorted().prefix(100) {
      guard !Task.isCancelled, sourceAccount == account else { return }
      identities[path] = await resolver.resolveIdentities(at: path, expectedHost: account.host)
    }
    guard sourceAccount == account else { return }
    reviewRepositoryIdentities = identities
  }

  /// Restores durable Reviews-to-Sessions links without fetching the GitHub
  /// Project queue. Sessions calls this during app startup so PR context is
  /// available even when the user never opens the Reviews tab.
  public func loadSessionAssociations() async {
    guard !didLoadSessionAssociations else { return }
    didLoadSessionAssociations = true
    await restoreReviewSessionLaunches()
  }

  public func reloadProjects() async {
    await loadSources()
  }

  public func cancelRefresh() {
    sourceRefreshTask?.cancel()
    queueTask?.cancel()
    queueTask = nil
    checksTask?.cancel()
    checksTask = nil
    refreshGeneration += 1
    isLoadingProjects = false
    isLoadingPullRequests = false
  }

  public var selectedSources: [GitHubReviewSource] {
    let owners = sourceOwners.filter { owner in
      if let selectedOwnerID { return owner.id == selectedOwnerID }
      return enabledOwnerIDs.contains(owner.id)
    }
    return owners.map { owner in
      if selectedOwnerID != nil, !repositoryName.isEmpty {
        return .repository(GitHubReviewRepository(owner: owner, name: repositoryName))
      }
      return .owner(owner)
    }
  }

  public var sourceLabel: String {
    guard let selectedOwnerID else { return "All selected sources" }
    guard let owner = sourceOwners.first(where: { $0.id == selectedOwnerID }) else {
      return "Unavailable source"
    }
    let label = displayLabel(for: owner)
    return repositoryName.isEmpty ? label : "\(label) / \(repositoryName)"
  }

  public func displayLabel(for owner: GitHubReviewOwner) -> String {
    owner.isPersonal ? "Personal" : ownerLabels[owner.id] ?? owner.login
  }

  var hasUnavailableSources: Bool {
    !enabledOwnerIDs.isSubset(of: Set(sourceOwners.map(\.id)))
  }

  func removeUnavailableSources() {
    enabledOwnerIDs.formIntersection(Set(sourceOwners.map(\.id)))
    sourceDidChange()
  }

  private var currentQuery: GitHubReviewQuery? {
    guard let sourceAccount, !selectedSources.isEmpty,
      selectedOwnerID != nil || !hasUnavailableSources,
      selectedProjectID == nil || (selectedProject != nil && selectedView != nil)
    else { return nil }
    return GitHubReviewQuery(
      account: sourceAccount, sources: selectedSources,
      project: selectedProject, view: selectedView)
  }

  public func selectOwner(id: String?) {
    guard id != selectedOwnerID,
      id == nil || sourceOwners.contains(where: { $0.id == id })
    else { return }
    selectedOwnerID = id
    repositoryName = ""
    sourceDidChange()
  }

  public func setOwnerEnabled(_ id: String, enabled: Bool) {
    guard sourceOwners.contains(where: { $0.id == id }) else { return }
    if enabled { enabledOwnerIDs.insert(id) } else { enabledOwnerIDs.remove(id) }
    sourceDidChange()
  }

  public func setOwnerLabel(_ label: String, for id: String) {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    ownerLabels[id] = trimmed.isEmpty ? nil : trimmed
    persistWorkspace()
  }

  public func selectRepository(_ name: String) {
    guard selectedOwnerID != nil else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name != repositoryName else { return }
    repositoryName = name
    sourceDidChange()
  }

  public func selectProject(id: String?) {
    guard selectedProjectID != id,
      id == nil || projects.contains(where: { $0.id == id })
    else { return }
    selectedProjectID = id
    selectedViewID = preferredView(in: selectedProject)?.id
    sourceDidChange()
  }

  public func selectView(id: String) {
    guard selectedViewID != id, availableViews.contains(where: { $0.id == id }) else { return }
    selectedViewID = id
    sourceDidChange()
  }

  private func sourceDidChange() {
    cancelRefresh()
    sourceRevision += 1
    selectedPullRequestID = nil
    checksByPullRequestID = [:]
    restoreCachedPullRequests()
    persistWorkspace()
    sourceRefreshTask?.cancel()
    sourceRefreshTask = Task { await refreshPullRequests() }
  }

  public func refreshPullRequests() async {
    guard let query = currentQuery else {
      pullRequests = []
      cachedPullRequestsUpdatedAt = nil
      isShowingCachedPullRequests = false
      return
    }
    queueTask?.cancel()
    checksTask?.cancel()
    refreshGeneration += 1
    let generation = refreshGeneration
    isLoadingPullRequests = true
    errorMessage = nil
    recoveryIssue = nil
    let task = Task { [service] in try await service.listPullRequests(query: query, limit: 300) }
    queueTask = task
    do {
      let queue = try await task.value
      guard !Task.isCancelled, generation == refreshGeneration, currentQuery == query else {
        return
      }
      pullRequests = queue.pullRequests
      isQueueTruncated = queue.isTruncated
      let updatedAt = Date()
      cachedPullRequestsUpdatedAt = updatedAt
      isShowingCachedPullRequests = false
      cachedQueues[query.cacheKey] = GitHubReviewWorkspace.CachedQueue(
        pullRequests: pullRequests, updatedAt: updatedAt, isTruncated: queue.isTruncated)
      persistWorkspace()
      isLoadingPullRequests = false
      refreshChecks(for: pullRequests.map(\.id))
    } catch {
      guard !Task.isCancelled, generation == refreshGeneration else { return }
      isLoadingPullRequests = false
      if error is CancellationError { return }
      if error as? GitHubReviewSourceError == .accountChanged
        || GitHubReviewRecoveryIssue.classify(error).kind == .authenticationRequired
      {
        clearAccount()
      } else {
        isShowingCachedPullRequests = !pullRequests.isEmpty
      }
      presentRecoveryIssue(for: error)
    }
  }

  public func presentLaunchError(_ message: String) {
    recoveryIssue = nil
    errorMessage = message
  }

  func validateReviewLaunch(_ request: GitHubProjectPullRequest) async -> GitHubReviewAccount? {
    guard let account = sourceAccount,
      pullRequests.contains(where: { $0.reviewIdentity == request.reviewIdentity })
    else { return nil }
    let revision = sourceRevision
    do {
      guard try await service.reviewAccount() == account else {
        clearAccount()
        throw GitHubReviewSourceError.accountChanged
      }
      guard !Task.isCancelled, sourceRevision == revision, sourceAccount == account else {
        return nil
      }
      return account
    } catch {
      if GitHubReviewRecoveryIssue.classify(error).kind == .authenticationRequired {
        clearAccount()
      }
      presentRecoveryIssue(for: error)
      return nil
    }
  }

  public func registerReviewLaunch(
    for pullRequest: GitHubProjectPullRequest,
    provider: SessionProviderKind,
    pendingID: UUID,
    projectPath: String,
    launchedAt: Date = Date(),
    branchName: String? = nil
  ) async {
    let launch = GitHubReviewSessionLaunch(
      pullRequestID: "\(sourceAccount?.persistenceKey ?? "legacy")|\(pullRequest.reviewIdentity)",
      pullRequestURL: pullRequest.url,
      provider: provider,
      pendingID: pendingID,
      projectPath: projectPath,
      launchedAt: launchedAt, sourceAccountKey: sourceAccount?.persistenceKey,
      branchName: branchName
    )
    upsert(launch)
    await persist(launch)
  }

  public func resolveReviewLaunches(
    _ resolutions: [UUID: String],
    provider: SessionProviderKind
  ) async {
    guard !resolutions.isEmpty else { return }

    for (pullRequestID, launches) in reviewSessionLaunchesByPullRequestID {
      var updatedLaunches = launches
      var didChange = false
      for index in updatedLaunches.indices {
        let launch = updatedLaunches[index]
        guard launch.provider == provider,
          let pendingID = launch.pendingID,
          let sessionID = resolutions[pendingID],
          launch.sessionID != sessionID
        else { continue }

        let resolved = launch.resolving(to: sessionID)
        updatedLaunches[index] = resolved
        didChange = true
        await persist(resolved)
      }
      if didChange {
        reviewSessionLaunchesByPullRequestID[pullRequestID] = updatedLaunches
      }
    }
  }

  func recoverReviewSessions(
    provider: SessionProviderKind,
    searchResults: [SessionSearchResult]
  ) async {
    // A matching URL or prompt does not prove which GitHub account launched a
    // session. Keep legacy records unchanged until the user explicitly links
    // them through an account-verified action; search must never adopt them.
  }

  func finishLegacySessionRecovery() {
    didAttemptLegacySessionRecovery = true
  }

  var hasUnverifiedReviewSessions: Bool {
    sourceAccount != nil && reviewSessionLaunchesByPullRequestID.values
      .flatMap { $0 }.contains { $0.sourceAccountKey == nil }
  }

  func quarantinedReviewSessionIDs(provider: SessionProviderKind) -> Set<String> {
    let launches = reviewSessionLaunchesByPullRequestID.values.flatMap { $0 }
      .filter { $0.provider == provider }
    let accountKey = sourceAccount?.persistenceKey
    let verified = Set(launches.filter {
      accountKey != nil && $0.sourceAccountKey == accountKey
    }.compactMap(\.sessionID))
    // Do not let ticket/URL inference bypass an unverified persisted association.
    return Set(launches.compactMap(\.sessionID)).subtracting(verified)
  }

  func reviewSessionLaunches(
    for pullRequest: GitHubProjectPullRequest
  ) -> [GitHubReviewSessionLaunch] {
    guard let accountKey = sourceAccount?.persistenceKey else { return [] }
    return reviewSessionLaunchesByPullRequestID.values.flatMap { $0 }.filter {
      $0.pullRequestURL.caseInsensitiveCompare(pullRequest.url) == .orderedSame
        && $0.sourceAccountKey == accountKey
    }
  }

  func linkedSessionTitles(provider: SessionProviderKind) -> [String: String] {
    let titlesByPullRequestID = Dictionary(
      uniqueKeysWithValues: pullRequests.map { ($0.url.lowercased(), $0.title) }
    )
    var titles: [String: String] = [:]
    for launches in reviewSessionLaunchesByPullRequestID.values {
      for launch in launches where launch.provider == provider {
        guard let title = titlesByPullRequestID[launch.pullRequestURL.lowercased()] else {
          continue
        }
        if let sessionID = launch.sessionID {
          titles[sessionID] = title
        }
      }
    }
    return titles
  }

  func linkedPullRequestReferencesByItemID(
    provider: SessionProviderKind
  ) -> [String: [GitHubPullRequestURLReference]] {
    // Touch the observed source so views still update when launches change.
    _ = reviewSessionLaunchesByPullRequestID.count
    if let cached = linkedReferencesCache[provider] { return cached }
    var referencesByItemID: [String: [GitHubPullRequestURLReference]] = [:]
    let launches = reviewSessionLaunchesByPullRequestID.values
      .flatMap { $0 }
      .filter { $0.provider == provider }
      .sorted { $0.launchedAt < $1.launchedAt }

    for launch in launches {
      guard
        let reference = GitHubPullRequestURLReference(
          urlString: launch.pullRequestURL,
          expectedHost: URL(string: launch.pullRequestURL)?.host ?? "github.com")
      else {
        continue
      }

      let itemID: String
      if let sessionID = launch.sessionID {
        itemID = SidebarSessionItemID.monitored(provider: provider, sessionId: sessionID)
      } else if let pendingID = launch.pendingID {
        itemID = SidebarSessionItemID.pending(provider: provider, pendingId: pendingID)
      } else {
        continue
      }

      if referencesByItemID[itemID]?.contains(reference) != true {
        referencesByItemID[itemID, default: []].append(reference)
      }
    }
    linkedReferencesCache[provider] = referencesByItemID
    return referencesByItemID
  }

  private func upsert(_ launch: GitHubReviewSessionLaunch) {
    var launches = reviewSessionLaunchesByPullRequestID[launch.pullRequestID] ?? []
    launches.removeAll { $0.provider == launch.provider }
    launches.append(launch)
    reviewSessionLaunchesByPullRequestID[launch.pullRequestID] = launches
  }

  private func restoreReviewSessionLaunches() async {
    guard let sessionStore else { return }
    do {
      let associations = try await sessionStore.githubReviewSessionAssociations()
      reviewSessionLaunchesByPullRequestID = Dictionary(
        grouping: associations.compactMap(GitHubReviewSessionLaunch.init),
        by: \.pullRequestID
      )
      sessionLinkErrorMessage = nil
    } catch {
      sessionLinkErrorMessage =
        "Could not restore linked review sessions: \(error.localizedDescription)"
    }
  }

  private func persist(_ launch: GitHubReviewSessionLaunch) async {
    guard let sessionStore else { return }
    do {
      try await sessionStore.saveGitHubReviewSessionAssociation(launch.association)
      sessionLinkErrorMessage = nil
    } catch {
      sessionLinkErrorMessage =
        "Could not save the review session link: \(error.localizedDescription)"
    }
  }

  private func loadSources() async {
    cancelRefresh()
    let generation = refreshGeneration
    isLoadingProjects = true
    recoveryIssue = nil
    errorMessage = nil
    var didVerifyAccount = false
    do {
      let context = try await service.reviewSourceContext()
      guard !Task.isCancelled, generation == refreshGeneration else { return }
      didVerifyAccount = true
      let changed = sourceAccount?.persistenceKey != context.account.persistenceKey
      if changed {
        clearAccount()
        sourceAccount = context.account
        let workspace = try await sessionStore?.reviewWorkspace(account: context.account)
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        if let saved = workspace,
          saved.account.persistenceKey == context.account.persistenceKey
        {
          selectedOwnerID = saved.selectedOwnerID
          enabledOwnerIDs = saved.enabledOwnerIDs
          repositoryName = saved.repositoryName
          ownerLabels = saved.ownerLabels
          selectedProjectID = saved.projectID
          selectedViewID = saved.viewID
          cachedQueues = saved.queues
        } else {
          selectedOwnerID = context.owners.first(where: \.isPersonal)?.id
          enabledOwnerIDs = Set(context.owners.filter(\.isPersonal).map(\.id))
        }
      }
      sourceAccount = context.account
      sourceOwners = context.owners
      areOwnersTruncated = context.isTruncated
      viewerLogin = context.account.login
      // Never substitute a different owner when a saved source loses access.
      if (selectedOwnerID != nil && !sourceOwners.contains(where: { $0.id == selectedOwnerID }))
        || (selectedOwnerID == nil && !enabledOwnerIDs.isSubset(of: Set(sourceOwners.map(\.id))))
      {
        pullRequests = []
        throw GitHubReviewSourceError.unavailableSource
      }
      if selectedProjectID != nil {
        projects = try await service.listProjects(account: context.account)
        guard generation == refreshGeneration else { return }
        guard selectedProject != nil, selectedView != nil else {
          throw GitHubReviewSourceError.unavailableSource
        }
      }
      refreshCachedQueryIdentities()
      restoreCachedPullRequests()
      isLoadingProjects = false
      await refreshPullRequests()
    } catch {
      guard generation == refreshGeneration else { return }
      isLoadingProjects = false
      if !didVerifyAccount || error as? GitHubReviewSourceError == .accountChanged
        || GitHubReviewRecoveryIssue.classify(error).kind == .authenticationRequired
      {
        clearAccount()
      } else {
        // Keep verified source choices available so the user can repair a saved scope.
        pullRequests = []
        selectedPullRequestID = nil
        isShowingCachedPullRequests = false
        sourceRevision += 1
      }
      presentRecoveryIssue(for: error)
    }
  }

  /// Projects are optional and loaded only when the advanced filter is opened.
  public func loadOptionalProjects() async {
    guard let account = sourceAccount else { return }
    let previousQuery = currentQuery
    projectErrorMessage = nil
    do {
      let loaded = try await service.listProjects(account: account)
      guard sourceAccount == account else { return }
      projects = loaded.filter { URL(string: $0.url)?.host?.lowercased() == account.host }
      refreshCachedQueryIdentities()
      if selectedProjectID != nil, selectedProject == nil || selectedView == nil {
        cancelRefresh()
        pullRequests = []
        sourceRevision += 1
        throw GitHubReviewSourceError.unavailableSource
      }
      if previousQuery != currentQuery { sourceDidChange() }
    } catch {
      guard sourceAccount == account else { return }
      if error as? GitHubReviewSourceError == .accountChanged
        || GitHubReviewRecoveryIssue.classify(error).kind == .authenticationRequired
      {
        cancelRefresh()
        clearAccount()
        presentRecoveryIssue(for: error)
        return
      }
      projectErrorMessage = error.localizedDescription
    }
  }

  private func clearAccount() {
    sourceAccount = nil
    reviewRepositoryIdentities = [:]
    sourceOwners = []
    selectedOwnerID = nil
    enabledOwnerIDs = []
    repositoryName = ""
    projects = []
    selectedProjectID = nil
    selectedViewID = nil
    ownerLabels = [:]
    cachedQueues = [:]
    pullRequests = []
    checksByPullRequestID = [:]
    viewerLogin = nil
    selectedPullRequestID = nil
    sourceRevision += 1
    isShowingCachedPullRequests = false
    cachedPullRequestsUpdatedAt = nil
  }

  private func presentRecoveryIssue(for error: Error) {
    errorMessage = nil
    let issue = GitHubReviewRecoveryIssue.classify(error)
    recoveryIssue = issue
    guard issue.kind == .rateLimited else { return }
    // Say when the quota frees up; the lookup itself costs no quota.
    Task { [service] in
      let resetAt = await service.rateLimitResetDate()
      guard let resetAt, self.recoveryIssue?.kind == .rateLimited else { return }
      self.recoveryIssue = .rateLimited(resetAt: resetAt, details: issue.technicalDetails)
    }
  }

  private func preferredView(in project: GitHubReviewProject?) -> GitHubProjectView? {
    guard let project else { return nil }
    return project.views.first {
      $0.name.localizedCaseInsensitiveContains("code review")
    } ?? project.views.first {
      let filter = $0.filter?.lowercased() ?? ""
      return filter.contains("is:pr") && filter.contains("status:")
    } ?? project.views.first {
      $0.filter?.localizedCaseInsensitiveContains("is:pr") == true
    } ?? project.views.first
  }

  private func refreshCachedQueryIdentities() {
    guard let account = sourceAccount else { return }
    var refreshed: [String: GitHubReviewWorkspace.CachedQueue] = [:]
    for (key, queue) in cachedQueues {
      var newKey = key
      if let data = Data(base64Encoded: key),
        let oldQuery = try? JSONDecoder().decode(GitHubReviewQuery.self, from: data),
        oldQuery.account.persistenceKey == account.persistenceKey
      {
        let sources = oldQuery.sources.compactMap { source -> GitHubReviewSource? in
          guard let owner = sourceOwners.first(where: { $0.id == source.owner.id }) else {
            return nil
          }
          switch source {
          case .owner: return .owner(owner)
          case .repository(let repository):
            return .repository(GitHubReviewRepository(owner: owner, name: repository.name))
          }
        }
        let project = oldQuery.project.flatMap { old in projects.first { $0.id == old.id } }
        let view = oldQuery.view.flatMap { old in project?.views.first { $0.id == old.id } }
        if sources.count == oldQuery.sources.count,
          oldQuery.project == nil || project != nil,
          oldQuery.view == nil || view != nil,
          oldQuery.view?.filter == view?.filter
        {
          let query = GitHubReviewQuery(
            account: account, sources: sources, project: project, view: view)
          newKey = query.cacheKey
        }
      }
      if let existing = refreshed[newKey], existing.updatedAt > queue.updatedAt {
        continue
      }
      refreshed[newKey] = queue
    }
    cachedQueues = refreshed
  }

  private func restoreCachedPullRequests() {
    guard let query = currentQuery, !query.hasUnsupportedProjectFilter,
      let cached = cachedQueues[query.cacheKey]
    else {
      pullRequests = []
      cachedPullRequestsUpdatedAt = nil
      isShowingCachedPullRequests = false
      isQueueTruncated = false
      return
    }
    pullRequests = cached.pullRequests
    cachedPullRequestsUpdatedAt = cached.updatedAt
    isShowingCachedPullRequests = true
    isQueueTruncated = cached.isTruncated
  }

  private func persistWorkspace() {
    guard let account = sourceAccount, let sessionStore else { return }
    // Bound saved queues as well as network results.
    let recent = cachedQueues.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(10)
    let workspace = GitHubReviewWorkspace(
      account: account, selectedOwnerID: selectedOwnerID,
      enabledOwnerIDs: enabledOwnerIDs, repositoryName: repositoryName, ownerLabels: ownerLabels,
      projectID: selectedProjectID, viewID: selectedViewID,
      queues: Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) }))
    let previous = persistTask
    persistTask = Task {
      await previous?.value
      do { try await sessionStore.saveReviewWorkspace(workspace) } catch {
        self.sessionLinkErrorMessage =
          "Could not save Reviews sources: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Session launch guard

  /// Returns true if the pull request ID was not already in flight and is now marked.
  public func beginStartingReview(for prID: String) -> Bool {
    startingReviewPRIDs.insert(prID).inserted
  }

  /// Clears the in-flight state for a pull request ID.
  public func endStartingReview(for prID: String) {
    startingReviewPRIDs.remove(prID)
  }
}
