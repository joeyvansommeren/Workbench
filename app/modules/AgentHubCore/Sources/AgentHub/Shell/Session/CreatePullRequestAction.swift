import AgentHubGitHub
import Foundation
import Observation

/// Shared with the monitoring card. No part of publication types into a terminal.
@MainActor
@Observable
final class CreatePullRequestAction: Identifiable {
  enum Phase: Equatable {
    case preparing, reviewing, publishing, checking, failed
    case pending(UUID?)
    case existing(GitHubPublishedPullRequest), handoff(PullRequestHandoff), mismatched(GitHubPublishedPullRequest, PullRequestPublicationRecord)
    case confirmingRepository(GitHubRepositoryIdentity)
  }

  let id = UUID()
  private(set) var context: PullRequestContext
  var title: String
  var body = ""
  var repositoryName = ""
  private(set) var phase = Phase.preparing
  private(set) var plan: PullRequestPublicationPlan?
  private(set) var error: String?
  private(set) var requiresCommitReview = false
  private var started = false
  private var invalidated = false
  private let service: any PullRequestPublicationServiceProtocol
  private let observation: (any GitHubPRObservationServiceProtocol)?
  private let target: GitHubPRObservationTarget

  init(
    session: CLISession, provider: SessionProviderKind, title: String, origin: SessionLaunchOrigin?,
    service: any PullRequestPublicationServiceProtocol,
    observation: (any GitHubPRObservationServiceProtocol)?, target: GitHubPRObservationTarget
  ) {
    context = .init(sessionID: session.id, provider: provider, projectPath: session.projectPath,
                    branch: session.branchName, repository: origin?.publicationRepository)
    self.title = origin?.displayName ?? title
    if let origin, origin.source != .pullRequest { body = "Ticket: \(origin.key)" }
    self.service = service
    self.observation = observation
    self.target = target
  }

  var isBusy: Bool { phase == .preparing || phase == .publishing || phase == .checking }
  var canPublish: Bool {
    phase == .reviewing && plan?.needsPush == false && !invalidated
  }

  func prepare() async {
    guard !started else { return }
    started = true
    await check()
  }

  func check() async {
    guard !invalidated, phase != .publishing, phase != .checking else { return }
    phase = .checking
    do {
      let preparation = try await service.prepare(context)
      apply(preparation)
      switch preparation {
      case .chooseRepository, .review: break
      default: await observation?.refresh(target)
      }
    } catch {
      fail(error)
    }
  }

  var canReviewCurrentCommits: Bool {
    if case .pending(.some) = phase { return true }
    return false
  }

  func reopenHandoff() async -> URL? {
    guard !invalidated, case .handoff(let expected) = phase else { return nil }
    phase = .publishing
    do {
      apply(try await service.reopenHandoff(context, expectedID: expected.record.id))
      if case .handoff(let refreshed) = phase, refreshed.record.id == expected.record.id {
        return refreshed.destination
      }
    } catch {
      fail(error)
    }
    return nil
  }

  func reviewCurrentCommits() async {
    guard !invalidated, case .pending(let expectedID?) = phase else { return }
    phase = .checking
    do { apply(try await service.reviewCurrentCommits(context, expectedID: expectedID)) }
    catch { fail(error) }
  }

  func confirmRepository() async {
    guard !invalidated, case .confirmingRepository(let repository) = phase else { return }
    phase = .checking
    do {
      let confirmation = try await service.confirmRepository(context, name: repositoryName)
      guard !invalidated else { return }
      context = confirmation.context
      apply(confirmation.preparation)
    } catch PullRequestPublicationError.unconfirmedRepository {
      error = PullRequestPublicationError.unconfirmedRepository.localizedDescription
      phase = .confirmingRepository(repository)
    } catch {
      fail(error)
    }
  }

  func publish() async {
    guard canPublish, let plan else { return }
    phase = .publishing
    do { apply(try await service.publish(plan)) }
    catch { fail(error) }
  }

  func invalidate() {
    // An approved operation still reports on its captured repository.
    guard phase != .publishing else { return }
    invalidated = true
    fail(PullRequestPublicationError.staleReview, evenIfInvalidated: true)
  }

  private func apply(_ preparation: PullRequestPreparation) {
    guard !invalidated else { return }
    error = nil
    requiresCommitReview = false
    plan = nil
    switch preparation {
    case .chooseRepository(let repository):
      repositoryName = ""
      phase = .confirmingRepository(repository)
    case .review(let plan):
      let scoped = plan.context.repository.map(context.targeting) ?? context
      guard plan.context == scoped, context.repository == nil || context.repository == scoped.repository else {
        fail(PullRequestPublicationError.staleReview)
        return
      }
      context = scoped
      self.plan = plan
      phase = .reviewing
    case .existing(let request):
      phase = .existing(request)
    case .handoff(let destination):
      phase = .handoff(destination)
    case .mismatched(let request, let record):
      phase = .mismatched(request, record)
    case .pending(let expectedID):
      phase = .pending(expectedID)
    }
  }

  private func fail(_ error: any Error, evenIfInvalidated: Bool = false) {
    guard !invalidated || evenIfInvalidated else { return }
    plan = nil
    self.error = error.localizedDescription
    requiresCommitReview = error as? PullRequestPublicationError == .dirty
    phase = .failed
  }
}
