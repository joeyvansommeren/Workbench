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
  let refs: PullRequestRefs
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
    case pushing, handedOff, verified
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
  func abandonPullRequestPush(id: UUID) async throws
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
  case pending
}

enum PullRequestPublicationError: LocalizedError, Equatable {
  case detached, wrongBranch, missingRepository, wrongRepository, dirty, defaultBranch, gitUnavailable, baseUnavailable
  case emptyDiff, staleReview, unchangedPending, gitHubUnavailable, unconfirmedRepository

  var errorDescription: String? {
    switch self {
    case .detached: "Switch from detached HEAD to the session’s branch."
    case .wrongBranch: "Open a session with the intended branch checked out, then review again."
    case .missingRepository: "Select and confirm the intended GitHub repository before continuing."
    case .unconfirmedRepository: "Enter the GitHub owner and repository shown for this branch."
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
  func confirmRepository(_ context: PullRequestContext, name: String) async throws -> PullRequestPreparation
  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation
  func reviewCurrentCommits(_ context: PullRequestContext) async throws -> PullRequestPreparation
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
    let context: PullRequestContext
    if unboundContext.repository != nil {
      context = unboundContext
    } else if let recorded = try await store.pullRequestPublicationRepository(for: unboundContext) {
      context = unboundContext.targeting(recorded)
    } else {
      return .chooseRepository(try git.origin(unboundContext))
    }
    let key = try Self.key(for: context)
    let record = try await store.pullRequestPublication(for: key)
    let repository = try Self.repository(for: context)
    // Reconcile an earlier handoff even after the checkout becomes dirty or changes branches.
    if let request = try await fetchPullRequest(repository, branch: key.branch) {
      guard let record, record.phase != .pushing else { return .existing(request) }
      if record.phase == .verified { return .existing(request) }
      guard Self.matches(request, record) else { return .mismatched(request, record) }
      _ = try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .verified)
      return .existing(request)
    }
    if let record {
      if running.contains(record.id) { return .pending }
      if record.phase == .verified { return .pending }
      if record.phase == .handedOff {
        guard let checkout = try? checkedCheckout(context), checkout.head == record.head,
          let refs = try? git.remoteRefs(checkout, base: record.base),
          refs.base == record.baseOID, refs.head == record.head
        else { return .pending }
        return .handoff(.init(destination: try compareURL(record.key, base: record.base), record: record))
      }
    }

    let checkout = try checkedCheckout(context)
    let base = try await fetchBase(repository)
    guard !checkout.branch.utf8.elementsEqual(base.utf8),
      !["main", "master"].contains(checkout.branch)
    else { throw PullRequestPublicationError.defaultBranch }

    if let record {
      // Only an exact-object push could have started. A fresh review can safely resume.
      try await store.abandonPullRequestPush(id: record.id)
    }
    guard try checkedCheckout(context) == checkout else { throw PullRequestPublicationError.staleReview }
    let refs = try git.remoteRefs(checkout, base: base)
    let files = try git.files(checkout, base: refs.base)
    guard !files.isEmpty else { throw PullRequestPublicationError.emptyDiff }
    return .review(.init(context: context, checkout: checkout, baseBranch: base, refs: refs, files: files))
  }

  func confirmRepository(_ context: PullRequestContext, name: String) async throws -> PullRequestPreparation {
    let typedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = try git.origin(context)
    let currentName = "\(candidate.owner)/\(candidate.repository)"
    guard typedName.caseInsensitiveCompare(currentName) == .orderedSame else {
      throw PullRequestPublicationError.unconfirmedRepository
    }
    // The independently entered repository name is bound into the review plan.
    // An origin retarget after this check fails the checkout verification in prepare.
    return try await prepare(context.targeting(candidate))
  }

  func publish(_ plan: PullRequestPublicationPlan) async throws -> PullRequestPreparation {
    let current = try await prepare(plan.context)
    guard case .review(let fresh) = current else { return current }
    guard fresh == plan else { throw PullRequestPublicationError.staleReview }

    let destination = try compareURL(plan.key, base: plan.baseBranch)
    let record = PullRequestPublicationRecord(
      id: UUID(), key: plan.key, base: plan.baseBranch, baseOID: plan.refs.base, head: plan.checkout.head,
      sessionID: plan.context.sessionID, provider: plan.context.provider.rawValue, phase: .pushing)
    running.insert(record.id)
    defer { running.remove(record.id) }
    guard try await store.beginPullRequestPublication(record) else { return .pending }
    do {
      return try await execute(plan, record: record, destination: destination)
    } catch {
      try await store.abandonPullRequestPush(id: record.id)
      throw error
    }
  }

  func reviewCurrentCommits(_ unboundContext: PullRequestContext) async throws -> PullRequestPreparation {
    let context: PullRequestContext
    if unboundContext.repository != nil {
      context = unboundContext
    } else if let recorded = try await store.pullRequestPublicationRepository(for: unboundContext) {
      context = unboundContext.targeting(recorded)
    } else {
      return try await prepare(unboundContext)
    }
    let key = try Self.key(for: context)
    guard let record = try await store.pullRequestPublication(for: key),
      record.phase == .handedOff, !running.contains(record.id)
    else { return try await prepare(context) }
    if let request = try await fetchPullRequest(try Self.repository(for: context), branch: key.branch) {
      guard Self.matches(request, record) else { return .mismatched(request, record) }
      _ = try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .verified)
      return .existing(request)
    }
    // With no PR observed, the user may discard the earlier browser handoff.
    // Returning a fresh review cannot push or create a PR.
    _ = try checkedCheckout(context)
    guard try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .pushing)
    else { return .pending }
    try await store.abandonPullRequestPush(id: record.id)
    return try await prepare(context)
  }

  private func execute(
    _ plan: PullRequestPublicationPlan, record: PullRequestPublicationRecord, destination: URL
  ) async throws -> PullRequestPreparation {
    guard try checkedCheckout(plan.context) == plan.checkout,
      try git.remoteRefs(plan.checkout, base: plan.baseBranch) == plan.refs
    else { throw PullRequestPublicationError.staleReview }
    if plan.needsPush { try git.push(plan.checkout) }

    if let request = try await fetchPullRequest(plan.checkout.remote, branch: plan.checkout.branch) {
      try await store.abandonPullRequestPush(id: record.id)
      return .existing(request)
    }
    try validatePublishedRefs(plan)
    guard try await store.advancePullRequestPublication(id: record.id, from: .pushing, to: .handedOff)
    else { return .pending }
    do {
      try validatePublishedRefs(plan)
    } catch {
      // No browser destination was returned. Offer a new review.
      _ = try await store.advancePullRequestPublication(id: record.id, from: .handedOff, to: .pushing)
      throw error
    }
    return .handoff(.init(destination: destination, record: record))
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

  private func validatePublishedRefs(_ plan: PullRequestPublicationPlan) throws {
    guard try checkedCheckout(plan.context) == plan.checkout,
      try git.remoteRefs(plan.checkout, base: plan.baseBranch)
        == PullRequestRefs(base: plan.refs.base, head: plan.checkout.head)
    else { throw PullRequestPublicationError.staleReview }
  }

  private func fetchBase(_ repository: GitHubRepositoryIdentity) async throws -> String {
    do { return try await remote.publicationBase(in: repository) }
    catch { throw PullRequestPublicationError.gitHubUnavailable }
  }

  private func fetchPullRequest(
    _ repository: GitHubRepositoryIdentity, branch: String
  ) async throws -> GitHubPublishedPullRequest? {
    do { return try await remote.publicationPullRequest(in: repository, branch: branch) }
    catch { throw PullRequestPublicationError.gitHubUnavailable }
  }

  private static func matches(
    _ request: GitHubPublishedPullRequest, _ record: PullRequestPublicationRecord
  ) -> Bool {
    request.head == record.head && request.baseOID == record.baseOID && request.branch.utf8.elementsEqual(record.key.branch.utf8)
      && request.base.utf8.elementsEqual(record.base.utf8)
  }
}
