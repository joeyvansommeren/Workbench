import AgentHubGitHub
import Foundation

struct PullRequestContext: Equatable, Sendable {
  let sessionID: String
  let provider: SessionProviderKind
  let projectPath: String
  let branch: String?
  let repository: GitHubRepositoryIdentity?

  func targeting(_ repository: GitHubRepositoryIdentity) -> Self {
    .init(sessionID: sessionID, provider: provider, projectPath: projectPath,
          branch: branch, repository: repository)
  }
}

struct PullRequestPublicationPlan: Equatable, Sendable {
  let context: PullRequestContext
  let checkout: PullRequestCheckout
  let baseBranch: String
  let refs: GitHubPublicationRefs
  let files: [String]

  var needsPush: Bool { refs.head != checkout.head }

  var key: PullRequestPublicationKey {
    .init(
      host: checkout.remote.host, owner: checkout.remote.owner.lowercased(),
      repository: checkout.remote.repository.lowercased(), branch: checkout.branch)
  }
}

struct PullRequestPublicationKey: Hashable, Sendable {
  let host: String
  let owner: String
  let repository: String
  let branch: String
}

struct PullRequestPublicationRecord: Equatable, Sendable {
  enum Phase: String, Sendable {
    case preparing = "pushing"
    case handedOff, verified
  }

  let id: UUID
  let key: PullRequestPublicationKey
  let base: String
  let baseOID: String
  let head: String
  let sessionID: String
  let provider: String
  let phase: Phase
}

protocol PullRequestPublicationStoring: Sendable {
  func pullRequestPublication(for key: PullRequestPublicationKey) async throws -> PullRequestPublicationRecord?
  func pullRequestPublicationRepository(for context: PullRequestContext) async throws -> GitHubRepositoryIdentity?
  func beginPullRequestPublication(_ record: PullRequestPublicationRecord) async throws -> Bool
  func advancePullRequestPublication(id: UUID, from: PullRequestPublicationRecord.Phase,
                                     to: PullRequestPublicationRecord.Phase) async throws -> Bool
  func abandonPullRequestPreparation(id: UUID) async throws
  func retireVerifiedPullRequestPublication(id: UUID) async throws -> Bool
}

struct PullRequestHandoff: Equatable, Sendable {
  let destination: URL
  let record: PullRequestPublicationRecord
}

enum PullRequestPreparation: Equatable, Sendable {
  case chooseRepository(GitHubRepositoryIdentity)
  case review(PullRequestPublicationPlan)
  case existing(GitHubPublishedPullRequest)
  case handoff(PullRequestHandoff)
  case mismatched(GitHubPublishedPullRequest, PullRequestPublicationRecord)
  case pending(UUID?)
}

enum PullRequestPublicationError: LocalizedError, Equatable {
  case detached, wrongBranch, missingRepository, wrongRepository, dirty, defaultBranch, gitUnavailable, baseUnavailable
  case emptyDiff, staleReview, unchangedPending, gitHubUnavailable, unconfirmedRepository, pushRequired

  var errorDescription: String? {
    switch self {
    case .detached: "Switch from detached HEAD to the session’s branch."
    case .wrongBranch: "Open a session with the intended branch checked out, then review again."
    case .missingRepository: "Select and confirm the intended GitHub repository before continuing."
    case .unconfirmedRepository: "Enter the GitHub owner and repository shown for this branch."
    case .pushRequired: "Push the reviewed commit to the shown GitHub branch, then check again."
    case .wrongRepository: "The worktree origin differs from the repository selected for this session."
    case .dirty: "Review and commit the intended files first. Leave unrelated changes out of this worktree."
    case .defaultBranch: "Switch to a feature branch before creating a pull request."
    case .gitUnavailable: "Could not verify the checkout or its GitHub branch. Check Git access and try again."
    case .baseUnavailable: "Fetch the current base branch with Git, then review again."
    case .emptyDiff: "The session branch has no changes to publish."
    case .staleReview: "The branch, change scope, or remote changed. Review the pull request again."
    case .unchangedPending: "GitHub has not confirmed this pull request. Check again before starting another."
    case .gitHubUnavailable: "Could not verify GitHub access. Check GitHub CLI authentication and your connection."
    }
  }
}

protocol PullRequestPublicationServiceProtocol: Sendable {
  func prepare(_ context: PullRequestContext) async throws -> PullRequestPreparation
  func confirmRepository(_ context: PullRequestContext, name: String) async throws
    -> (context: PullRequestContext, preparation: PullRequestPreparation)
  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation
  func reopenHandoff(_ context: PullRequestContext, expectedID: UUID) async throws -> PullRequestPreparation
  func reviewCurrentCommits(_ context: PullRequestContext, expectedID: UUID) async throws -> PullRequestPreparation
}

actor PullRequestPublicationService: PullRequestPublicationServiceProtocol {
  private let git: any PullRequestPublicationGit
  private let remote: any GitHubReviewedPublishing
  private let store: any PullRequestPublicationStoring
  private var running: Set<UUID> = []

  init(
    git: any PullRequestPublicationGit = ReviewedPullRequestGit(), remote: any GitHubReviewedPublishing,
    store: any PullRequestPublicationStoring
  ) {
    self.git = git
    self.remote = remote
    self.store = store
  }

  func prepare(_ unboundContext: PullRequestContext) async throws -> PullRequestPreparation {
    guard let branch = unboundContext.branch, !branch.isEmpty else {
      _ = try git.checkout(unboundContext)
      throw PullRequestPublicationError.wrongBranch
    }
    guard let context = try await boundContext(unboundContext) else {
      return .chooseRepository(try git.origin(unboundContext))
    }
    let key = try Self.key(for: context)
    let record = try await store.pullRequestPublication(for: key)
    let repository = try Self.repository(for: context)
    let requests = try await fetchPullRequests(repository, branch: key.branch)
    if let record, record.phase == .handedOff {
      return try await recoverHandoff(context, repository: repository, requests: requests, record: record)
    }

    if let open = requests.first(where: \.isOpen) { return .existing(open) }
    if let record, running.contains(record.id) { return .pending(nil) }
    let checkout = try checkedCheckout(context)
    if let record, record.phase == .verified {
      if checkout.head == record.head,
        let closed = requests.first(where: { Self.matchesBranchAndHead($0, record) })
      {
        return .existing(closed)
      }
      // A verified request may have received more commits before closing.
      // With no matching closed request or active PR, allow a fresh review.
      guard try await store.retireVerifiedPullRequestPublication(id: record.id) else { return .pending(nil) }
    } else if let record {
      // No browser handoff was recorded, so a new review can safely resume.
      try await store.abandonPullRequestPreparation(id: record.id)
    }

    let base = try await fetchBase(repository)
    guard !checkout.branch.utf8.elementsEqual(base.utf8),
      !["main", "master"].contains(checkout.branch)
    else { throw PullRequestPublicationError.defaultBranch }

    let refs = try await fetchRefs(repository, base: base, branch: key.branch)
    guard try checkedCheckout(context) == checkout else { throw PullRequestPublicationError.staleReview }
    if let closed = requests.first(where: {
      $0.head == checkout.head && $0.baseOID == refs.base && $0.base.utf8.elementsEqual(base.utf8)
    }) {
      return .existing(closed)
    }
    let files = try git.files(checkout, base: refs.base)
    guard !files.isEmpty else { throw PullRequestPublicationError.emptyDiff }
    return .review(.init(context: context, checkout: checkout, baseBranch: base, refs: refs, files: files))
  }

  func confirmRepository(_ context: PullRequestContext, name: String) async throws
    -> (context: PullRequestContext, preparation: PullRequestPreparation)
  {
    let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = try git.origin(context)
    let currentName = "\(candidate.owner)/\(candidate.repository)"
    guard typedName.caseInsensitiveCompare(currentName) == .orderedSame else {
      throw PullRequestPublicationError.unconfirmedRepository
    }
    // The independently entered repository name is bound into the review plan.
    // An origin retarget after this check fails the checkout verification in prepare.
    let scoped = context.targeting(candidate)
    return (scoped, try await prepare(scoped))
  }

  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation {
    let current = try await prepare(plan.context)
    switch current {
    case .handoff(let handoff):
      let record = handoff.record
      guard record.key == plan.key, record.head == plan.checkout.head, record.baseOID == plan.refs.base,
        record.base.utf8.elementsEqual(plan.baseBranch.utf8), !plan.needsPush
      else { throw PullRequestPublicationError.staleReview }
      return current
    case .review(let fresh):
      guard fresh == plan else { throw PullRequestPublicationError.staleReview }
      guard !plan.needsPush else { throw PullRequestPublicationError.pushRequired }
    default:
      return current
    }

    let destination = try compareURL(plan.key, base: plan.baseBranch)
    let record = PullRequestPublicationRecord(
      id: UUID(), key: plan.key, base: plan.baseBranch, baseOID: plan.refs.base, head: plan.checkout.head,
      sessionID: plan.context.sessionID, provider: plan.context.provider.rawValue, phase: .preparing)
    running.insert(record.id)
    defer { running.remove(record.id) }
    guard try await store.beginPullRequestPublication(record) else { return .pending(nil) }
    do {
      return try await execute(plan, record: record, destination: destination)
    } catch {
      try await store.abandonPullRequestPreparation(id: record.id)
      throw error
    }
  }

  func reopenHandoff(_ unboundContext: PullRequestContext, expectedID: UUID) async throws -> PullRequestPreparation {
    let (context, record) = try await expectedHandoff(unboundContext, id: expectedID)
    let repository = try Self.repository(for: context)
    let requests = try await fetchPullRequests(repository, branch: record.key.branch)
    return try await recoverHandoff(context, repository: repository, requests: requests, record: record)
  }

  func reviewCurrentCommits(_ unboundContext: PullRequestContext, expectedID: UUID) async throws
    -> PullRequestPreparation
  {
    let (context, record) = try await expectedHandoff(unboundContext, id: expectedID)
    let requests = try await fetchPullRequests(try Self.repository(for: context), branch: record.key.branch)
    guard try await store.pullRequestPublication(for: record.key) == record
    else { throw PullRequestPublicationError.staleReview }
    if let result = try await reconcile(requests, record: record) { return result }
    // Returning a fresh review only discards the handoff identified by the sheet.
    _ = try checkedCheckout(context)
    guard try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .preparing)
    else { throw PullRequestPublicationError.staleReview }
    try await store.abandonPullRequestPreparation(id: record.id)
    return try await prepare(context)
  }

  private func boundContext(_ context: PullRequestContext) async throws -> PullRequestContext? {
    if context.repository != nil { return context }
    return try await store.pullRequestPublicationRepository(for: context).map(context.targeting)
  }

  private func expectedHandoff(_ context: PullRequestContext, id: UUID) async throws
    -> (PullRequestContext, PullRequestPublicationRecord)
  {
    guard let scoped = try await boundContext(context),
      let record = try await store.pullRequestPublication(for: Self.key(for: scoped)),
      record.id == id, record.phase == .handedOff, !running.contains(id)
    else { throw PullRequestPublicationError.staleReview }
    return (scoped, record)
  }

  private func recoverHandoff(
    _ context: PullRequestContext, repository: GitHubRepositoryIdentity,
    requests: [GitHubPublishedPullRequest], record: PullRequestPublicationRecord
  ) async throws -> PullRequestPreparation {
    // GitHub may already have the request after the user leaves the original checkout.
    guard try await store.pullRequestPublication(for: record.key) == record else { return .pending(nil) }
    if let result = try await reconcile(requests, record: record) { return result }
    if running.contains(record.id) { return .pending(nil) }
    guard let checkout = try? checkedCheckout(context), checkout.head == record.head,
      let refs = try? await fetchRefs(repository, base: record.base, branch: record.key.branch),
      refs.base == record.baseOID, refs.head == record.head,
      (try? checkedCheckout(context)) == checkout
    else { return .pending(record.id) }
    guard try await store.pullRequestPublication(for: record.key) == record else { return .pending(nil) }
    return .handoff(.init(destination: try compareURL(record.key, base: record.base), record: record))
  }

  private func execute(
    _ plan: PullRequestPublicationPlan, record: PullRequestPublicationRecord, destination: URL
  ) async throws -> PullRequestPreparation {
    let requests = try await fetchPullRequests(plan.checkout.remote, branch: plan.checkout.branch)
    if let existing = requests.first(where: { $0.isOpen || Self.matches($0, record) }) {
      try await store.abandonPullRequestPreparation(id: record.id)
      return .existing(existing)
    }
    try await validatePublishedRefs(plan)
    guard try await store.advancePullRequestPublication(id: record.id, from: .preparing, to: .handedOff)
    else { return .pending(nil) }
    do {
      try await validatePublishedRefs(plan)
    } catch {
      // No browser destination was returned. Offer a new review.
      _ = try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .preparing)
      throw error
    }
    guard let current = try await store.pullRequestPublication(for: record.key),
      current.id == record.id, current.phase == .handedOff
    else { return .pending(nil) }
    return .handoff(.init(destination: destination, record: current))
  }

  private func compareURL(_ key: PullRequestPublicationKey, base baseBranch: String) throws -> URL {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard
      let branch = key.branch.addingPercentEncoding(withAllowedCharacters: allowed),
      let base = baseBranch.addingPercentEncoding(withAllowedCharacters: allowed)
    else { throw PullRequestPublicationError.gitUnavailable }
    var url = URLComponents()
    url.scheme = "https"
    url.host = key.host
    url.percentEncodedPath = "/\(key.owner)/\(key.repository)/compare/\(base)...\(branch)"
    url.queryItems = [URLQueryItem(name: "expand", value: "1")]
    guard let destination = url.url else { throw PullRequestPublicationError.gitUnavailable }
    return destination
  }

  private func checkedCheckout(_ context: PullRequestContext) throws -> PullRequestCheckout {
    let expected = try Self.repository(for: context)
    let checkout = try git.checkout(context)
    guard checkout.remote.host == expected.host,
      checkout.remote.owner.caseInsensitiveCompare(expected.owner) == .orderedSame,
      checkout.remote.repository.caseInsensitiveCompare(expected.repository) == .orderedSame
    else { throw PullRequestPublicationError.wrongRepository }
    return checkout
  }

  private static func repository(for context: PullRequestContext) throws -> GitHubRepositoryIdentity {
    guard let expected = context.repository, expected.host == "github.com",
      let result = ReviewedPullRequestGit.safeRemote("https://github.com/\(expected.owner)/\(expected.repository)"),
      result == expected
    else { throw PullRequestPublicationError.missingRepository }
    return expected
  }

  private static func key(for context: PullRequestContext) throws -> PullRequestPublicationKey {
    let repository = try Self.repository(for: context)
    guard let branch = context.branch, !branch.isEmpty else { throw PullRequestPublicationError.wrongBranch }
    return .init(host: repository.host, owner: repository.owner.lowercased(),
                 repository: repository.repository.lowercased(), branch: branch)
  }

  private func validatePublishedRefs(_ plan: PullRequestPublicationPlan) async throws {
    let refs = try await fetchRefs(plan.checkout.remote, base: plan.baseBranch, branch: plan.checkout.branch)
    guard refs == plan.refs, try checkedCheckout(plan.context) == plan.checkout
    else { throw PullRequestPublicationError.staleReview }
  }

  private func reconcile(
    _ requests: [GitHubPublishedPullRequest], record: PullRequestPublicationRecord
  ) async throws -> PullRequestPreparation? {
    let matching = requests.first { $0.isOpen && Self.matches($0, record) }
      ?? requests.first { Self.matches($0, record) }
    if let matching {
      guard try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .verified)
      else { return .pending(nil) }
      return .existing(matching)
    }
    return requests.first(where: \.isOpen).map { .mismatched($0, record) }
  }

  private func fetchRefs(
    _ repository: GitHubRepositoryIdentity, base: String, branch: String
  ) async throws -> GitHubPublicationRefs {
    do { return try await remote.publicationRefs(in: repository, base: base, branch: branch) }
    catch { throw PullRequestPublicationError.gitHubUnavailable }
  }

  private func fetchBase(_ repository: GitHubRepositoryIdentity) async throws -> String {
    do { return try await remote.publicationBase(in: repository) }
    catch { throw PullRequestPublicationError.gitHubUnavailable }
  }

  private func fetchPullRequests(
    _ repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> [GitHubPublishedPullRequest] {
    do { return try await remote.publicationPullRequests(in: repository, branch: branch) }
    catch { throw PullRequestPublicationError.gitHubUnavailable }
  }

  private static func matches(
    _ request: GitHubPublishedPullRequest, _ record: PullRequestPublicationRecord
  ) -> Bool {
    matchesBranchAndHead(request, record) && request.baseOID == record.baseOID
  }

  private static func matchesBranchAndHead(
    _ request: GitHubPublishedPullRequest, _ record: PullRequestPublicationRecord
  ) -> Bool {
    request.head == record.head && request.branch.utf8.elementsEqual(record.key.branch.utf8)
      && request.base.utf8.elementsEqual(record.base.utf8)
  }
}
