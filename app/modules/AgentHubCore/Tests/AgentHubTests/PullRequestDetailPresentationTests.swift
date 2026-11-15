import AgentHubGitHub
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Pull request detail presentation")
struct PullRequestDetailPresentationTests {
  @Test("State chips: open, draft and the review decision")
  func stateTags() throws {
    let draft = try pullRequest(state: "OPEN", isDraft: true, decision: "CHANGES_REQUESTED")
    #expect(
      PullRequestDetailPresentation.stateTags(for: draft) == [
        ReviewsTag(text: "Open", tone: .ready, kind: .state),
        ReviewsTag(text: "Draft", tone: .neutral, kind: .draft),
        ReviewsTag(text: "Changes requested", tone: .error, kind: .reviewDecision),
      ])

    let merged = try pullRequest(state: "MERGED", isDraft: false, decision: "APPROVED")
    #expect(
      PullRequestDetailPresentation.stateTags(for: merged) == [
        ReviewsTag(text: "Merged", tone: .working, kind: .state),
        ReviewsTag(text: "Approved", tone: .ready, kind: .reviewDecision),
      ])

    let closed = try pullRequest(state: "CLOSED", isDraft: false, decision: nil)
    #expect(PullRequestDetailPresentation.stateTags(for: closed) == [ReviewsTag(text: "Closed", tone: .error, kind: .state)])
    #expect(PullRequestDetailPresentation.reviewDecisionTag("REVIEW_REQUIRED")?.tone == .attention)
  }

  @Test("Header tags: no repeats; Draft drops Open, a status equal to a chip is left out")
  func headerTagsWithoutRepeats() throws {
    let draft = try pullRequest(state: "OPEN", isDraft: true, decision: nil)
    let projectPullRequest = GitHubProjectPullRequest(
      id: "pr", number: 1, title: "T", url: "u", repositoryName: "r", repositoryNameWithOwner: "o/r",
      authorLogin: "a", updatedAt: nil, isDraft: true, state: "open", projectStatus: "draft",
      projectPriority: " Urgent ")
    let tags = PullRequestDetailPresentation.headerTags(detail: draft, pullRequest: projectPullRequest)

    #expect(tags.map(\.text) == ["Draft", "Urgent"])
    #expect(Set(tags.map(\.id)).count == tags.count)
    #expect(tags.last == ReviewsTag(text: "Urgent", tone: .attention, kind: .priority))

    // An open pull request keeps Open, and a different status still shows.
    let open = try pullRequest(state: "OPEN", isDraft: false, decision: nil)
    let inReview = GitHubProjectPullRequest(
      id: "pr", number: 1, title: "T", url: "u", repositoryName: "r", repositoryNameWithOwner: "o/r",
      authorLogin: "a", updatedAt: nil, isDraft: false, state: "open", projectStatus: "In review",
      projectPriority: nil)
    #expect(
      PullRequestDetailPresentation.headerTags(detail: open, pullRequest: inReview).map(\.text)
        == ["Open", "In review"])

    // Before the detail loads: only the project fields.
    let early = PullRequestDetailPresentation.headerTags(detail: nil, pullRequest: projectPullRequest)
    #expect(early.map(\.kind) == [.projectStatus, .priority])
  }

  @Test("Long descriptions are cut at the limit and say so")
  func shortenedDescription() {
    let short = PullRequestDetailPresentation.shortenedDescription("Fixes the login.", limit: 100)
    #expect(short.text == "Fixes the login.")
    #expect(short.isShortened == false)

    let long = PullRequestDetailPresentation.shortenedDescription(
      String(repeating: "a", count: 120), limit: 100)
    #expect(long.text == String(repeating: "a", count: 100) + "…")
    #expect(long.isShortened)
  }

  @Test("Long conversations show the latest entries and count the earlier ones")
  func visibleConversation() {
    let entries = (1...25).map {
      PullRequestDetailPresentation.ConversationEntry(
        id: "\($0)", author: "a", date: nil, body: "", kind: .comment)
    }
    let folded = PullRequestDetailPresentation.visibleConversation(entries, showsAll: false, limit: 20)
    #expect(folded.entries.map(\.id) == (6...25).map { "\($0)" })
    #expect(folded.hiddenCount == 5)

    let all = PullRequestDetailPresentation.visibleConversation(entries, showsAll: true, limit: 20)
    #expect(all.entries.count == 25)
    #expect(all.hiddenCount == 0)

    let few = PullRequestDetailPresentation.visibleConversation(
      Array(entries.prefix(3)), showsAll: false, limit: 20)
    #expect(few.entries.count == 3)
    #expect(few.hiddenCount == 0)
  }

  @Test("Checks list: failing first, then pending, passed and unknown; by name within a group")
  func checkItems() throws {
    let checks = try decode(
      [GitHubCheckRun].self,
      """
      [
        {"name":"lint","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"CI"},
        {"name":"build","status":"COMPLETED","conclusion":"SUCCESS","workflowName":"build"},
        {"name":"unit","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://example.com/run/1"},
        {"name":"deploy","status":"IN_PROGRESS"}
      ]
      """)
    let items = PullRequestDetailPresentation.checkItems(checks)

    #expect(items.map(\.name) == ["unit", "deploy", "build", "lint"])
    #expect(items[0].state == .fail)
    #expect(items[0].detailsURL?.absoluteString == "https://example.com/run/1")
    #expect(items[1].state == .pending)
    // The workflow shows only when it adds something to the name.
    #expect(items[2].workflow == nil)
    #expect(items[3].workflow == "CI")
    #expect(PullRequestDetailPresentation.checkItems(nil).isEmpty)
  }

  @Test("Conversation: comments, reviews and code comments, oldest first")
  func conversation() throws {
    let pr = try decode(
      GitHubPullRequest.self,
      """
      {"number":1,"title":"T","state":"OPEN","url":"u","headRefName":"h","baseRefName":"main",
       "isDraft":false,"additions":1,"deletions":0,"changedFiles":1,
       "comments":[{"id":"c1","author":{"login":"amaes"},"body":"Looks good","createdAt":"2026-11-10T10:00:00Z"}]}
      """)
    let reviews = try decode(
      [GitHubReviewDetail.Review].self,
      """
      [
        {"id":"r1","author":{"login":"jdewit"},"body":"","state":"COMMENTED","submittedAt":"2026-11-10T09:00:00Z"},
        {"id":"r2","author":{"login":"jdewit"},"body":"Please fix","state":"CHANGES_REQUESTED","submittedAt":"2026-11-10T11:00:00Z"},
        {"id":"r3","author":{"login":"snoor"},"body":"","state":"APPROVED","submittedAt":"2026-11-10T12:00:00Z"}
      ]
      """)
    let inline = try decode(
      [GitHubComment].self,
      """
      [{"id":"i1","author":{"login":"jdewit"},"body":"Nit","createdAt":"2026-11-10T08:00:00Z","path":"src/App.swift","line":12}]
      """)
    let entries = PullRequestDetailPresentation.conversation(
      GitHubReviewDetail(pullRequest: pr, reviews: reviews, inlineComments: inline))

    // The empty "commented" review is GitHub's wrapper around code comments: left out.
    #expect(entries.map(\.id) == ["code-i1", "comment-c1", "review-r2", "review-r3"])
    #expect(entries[0].kind == .codeComment(location: "src/App.swift:12"))
    #expect(entries[1].kind == .comment)
    #expect(entries[2].kind == .review(ReviewsTag(text: "Changes requested", tone: .error, kind: .reviewState)))
    #expect(entries[3].kind == .review(ReviewsTag(text: "Approved", tone: .ready, kind: .reviewState)))
    #expect(entries[3].author == "snoor")
  }

  // MARK: - Helpers

  private func pullRequest(state: String, isDraft: Bool, decision: String?) throws -> GitHubPullRequest {
    let decisionField = decision.map { #","reviewDecision":"\#($0)""# } ?? ""
    return try decode(
      GitHubPullRequest.self,
      #"{"number":1,"title":"T","state":"\#(state)","url":"u","headRefName":"h","baseRefName":"main","isDraft":\#(isDraft),"additions":1,"deletions":0,"changedFiles":1\#(decisionField)}"#
    )
  }

  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }
}
