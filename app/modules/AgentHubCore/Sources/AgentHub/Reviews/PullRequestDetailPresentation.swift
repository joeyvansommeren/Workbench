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
struct ReviewsTag: Equatable, Hashable, Sendable {
  let text: String
  let tone: ReviewsTagTone
}

enum PullRequestDetailPresentation {
  /// Open / Merged / Closed, Draft, then the review decision.
  static func stateTags(for pullRequest: GitHubPullRequest) -> [ReviewsTag] {
    var tags: [ReviewsTag] = []
    switch pullRequest.state.uppercased() {
    case "MERGED": tags.append(ReviewsTag(text: "Merged", tone: .working))
    case "CLOSED": tags.append(ReviewsTag(text: "Closed", tone: .error))
    default: tags.append(ReviewsTag(text: "Open", tone: .ready))
    }
    if pullRequest.isDraft {
      tags.append(ReviewsTag(text: "Draft", tone: .neutral))
    }
    if let decision = reviewDecisionTag(pullRequest.reviewDecision) {
      tags.append(decision)
    }
    return tags
  }

  static func reviewDecisionTag(_ decision: String?) -> ReviewsTag? {
    switch decision?.uppercased() {
    case "APPROVED": return ReviewsTag(text: "Approved", tone: .ready)
    case "CHANGES_REQUESTED": return ReviewsTag(text: "Changes requested", tone: .error)
    case "REVIEW_REQUIRED": return ReviewsTag(text: "Review required", tone: .attention)
    default: return nil
    }
  }

  /// A submitted review's state as a chip.
  static func reviewStateTag(_ state: String) -> ReviewsTag {
    switch state.uppercased() {
    case "APPROVED": return ReviewsTag(text: "Approved", tone: .ready)
    case "CHANGES_REQUESTED": return ReviewsTag(text: "Changes requested", tone: .error)
    case "DISMISSED": return ReviewsTag(text: "Dismissed", tone: .neutral)
    case "PENDING": return ReviewsTag(text: "Pending", tone: .attention)
    default: return ReviewsTag(text: "Commented", tone: .neutral)
    }
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
        let left = rank(lhs.state)
        let right = rank(rhs.state)
        if left != right { return left < right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  private static func rank(_ state: PullRequestChecksState?) -> Int {
    switch state {
    case .fail: return 0
    case .pending: return 1
    case .pass: return 2
    case nil: return 3
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
