//
//  PullRequestDetailPresentation.swift
//  AgentHub
//
//  Pure text and state for the Reviews detail panel: the state chips, the
//  checks list and the conversation (comments, reviews, code comments).
//  Everything the legacy `GitHubReviewDetailView` showed. No SwiftUI.
//

import AgentHubGitHub
import Foundation

/// The colour family of a tag chip in Reviews.
enum ReviewsTagTone: Equatable, Sendable {
  case neutral
  case ready
  case attention
  case error
  case working
}

/// A small label chip: pull request state, review decision, project status.
struct ReviewsTag: Equatable, Hashable, Sendable, Identifiable {
  /// What the tag says something about. Part of the id, so a project status
  /// of "Draft" and the Draft state chip are two tags, not one.
  enum Kind: String, Sendable {
    case state
    case draft
    case reviewDecision
    case reviewState
    case projectStatus
    case priority
  }

  let text: String
  let tone: ReviewsTagTone
  let kind: Kind

  var id: String { "\(kind.rawValue)-\(text)" }
}

enum PullRequestDetailPresentation {
  /// Open / Merged / Closed, Draft, then the review decision.
  static func stateTags(for pullRequest: GitHubPullRequest) -> [ReviewsTag] {
    var tags: [ReviewsTag] = []
    switch pullRequest.state.uppercased() {
    case "MERGED": tags.append(ReviewsTag(text: "Merged", tone: .working, kind: .state))
    case "CLOSED": tags.append(ReviewsTag(text: "Closed", tone: .error, kind: .state))
    default: tags.append(ReviewsTag(text: "Open", tone: .ready, kind: .state))
    }
    if pullRequest.isDraft {
      tags.append(ReviewsTag(text: "Draft", tone: .neutral, kind: .draft))
    }
    if let decision = reviewDecisionTag(pullRequest.reviewDecision) {
      tags.append(decision)
    }
    return tags
  }

  /// State tags, then the project's status and priority, for the detail header.
  static func headerTags(detail: GitHubPullRequest?, pullRequest: GitHubProjectPullRequest) -> [ReviewsTag] {
    var tags = detail.map(stateTags(for:)) ?? []
    if let status = nonEmpty(pullRequest.projectStatus) {
      tags.append(ReviewsTag(text: status, tone: .neutral, kind: .projectStatus))
    }
    if let priority = nonEmpty(pullRequest.projectPriority) {
      let urgent = GitHubReviewRecommendation.isUrgent(priority)
      tags.append(ReviewsTag(text: priority, tone: urgent ? .attention : .neutral, kind: .priority))
    }
    return tags
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  static func reviewDecisionTag(_ decision: String?) -> ReviewsTag? {
    let text: String
    let tone: ReviewsTagTone
    switch decision?.uppercased() {
    case "APPROVED": (text, tone) = ("Approved", .ready)
    case "CHANGES_REQUESTED": (text, tone) = ("Changes requested", .error)
    case "REVIEW_REQUIRED": (text, tone) = ("Review required", .attention)
    default: return nil
    }
    return ReviewsTag(text: text, tone: tone, kind: .reviewDecision)
  }

  /// A submitted review's state as a chip.
  static func reviewStateTag(_ state: String) -> ReviewsTag {
    let text: String
    let tone: ReviewsTagTone
    switch state.uppercased() {
    case "APPROVED": (text, tone) = ("Approved", .ready)
    case "CHANGES_REQUESTED": (text, tone) = ("Changes requested", .error)
    case "DISMISSED": (text, tone) = ("Dismissed", .neutral)
    case "PENDING": (text, tone) = ("Pending", .attention)
    default: (text, tone) = ("Commented", .neutral)
    }
    return ReviewsTag(text: text, tone: tone, kind: .reviewState)
  }

  // MARK: - Checks

  struct CheckItem: Equatable, Identifiable {
    let id: String
    let name: String
    /// The workflow, when it differs from the check name.
    let workflow: String?
    let statusText: String
    let state: PullRequestChecksState?
    let detailsURL: URL?
  }

  /// Every check, failing first, then pending, passed and the rest; by name
  /// within a group.
  static func checkItems(_ checks: [GitHubCheckRun]?) -> [CheckItem] {
    (checks ?? [])
      .map { check in
        let workflow = check.workflowName.flatMap { $0.isEmpty || $0 == check.name ? nil : $0 }
        return CheckItem(
          id: check.id,
          name: check.name,
          workflow: workflow,
          statusText: check.statusDisplayName,
          state: PullRequestChecksState(check.ciStatus),
          detailsURL: check.detailsUrl.flatMap(URL.init(string:))
        )
      }
      .sorted { lhs, rhs in
        let left = PullRequestChecksState.sortRank(lhs.state)
        let right = PullRequestChecksState.sortRank(rhs.state)
        if left != right { return left < right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  // MARK: - Conversation

  struct ConversationEntry: Equatable, Identifiable {
    enum Kind: Equatable {
      case comment
      case review(ReviewsTag)
      /// A comment on a line of code: `path:line`.
      case codeComment(location: String)
    }

    let id: String
    let author: String
    let date: Date?
    let body: String
    let kind: Kind
  }

  /// Comments, reviews and code comments, oldest first. A review with no body
  /// that only commented is left out: it is the wrapper GitHub adds around
  /// code comments, which are listed on their own.
  static func conversation(_ detail: GitHubReviewDetail) -> [ConversationEntry] {
    let comments = (detail.pullRequest.comments ?? []).map {
      ConversationEntry(
        id: "comment-\($0.id)", author: $0.author?.login ?? "unknown", date: $0.createdAt,
        body: $0.body, kind: .comment)
    }
    let reviews = detail.reviews.compactMap { review -> ConversationEntry? in
      let tag = reviewStateTag(review.state)
      let body = review.body.trimmingCharacters(in: .whitespacesAndNewlines)
      if body.isEmpty, tag.text == "Commented" { return nil }
      return ConversationEntry(
        id: "review-\(review.id)", author: review.author?.login ?? "unknown",
        date: review.submittedAt, body: body, kind: .review(tag))
    }
    let codeComments = detail.inlineComments.map { comment in
      let location =
        [comment.path, comment.line.map(String.init)].compactMap { $0 }.joined(separator: ":")
      return ConversationEntry(
        id: "code-\(comment.id)", author: comment.author?.login ?? "unknown",
        date: comment.createdAt, body: comment.body,
        kind: .codeComment(location: location.isEmpty ? "Code comment" : location))
    }
    return (comments + reviews + codeComments).enumerated()
      .sorted { lhs, rhs in
        let left = lhs.element.date ?? .distantPast
        let right = rhs.element.date ?? .distantPast
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }
}
