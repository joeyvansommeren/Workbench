import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("GitHub Project review service")
struct GitHubProjectReviewServiceTests {
  @Test("Detail decodes current state, conversation, reviews and paginated inline comments")
  func reviewDetail() throws {
    let json = #"{"number":42,"title":"Fix","state":"MERGED","url":"https://github.com/o/r/pull/42","headRefName":"fix","baseRefName":"main","isDraft":false,"additions":1,"deletions":0,"changedFiles":1,"comments":[{"id":"c1","body":"Conversation","author":{"login":"alice"}}],"reviews":[{"id":"r1","body":"Looks good","state":"APPROVED","submittedAt":"2026-11-03T09:00:00Z"}]}"#
    let detail = try GitHubProjectReviewService.decodeDetail(json,
      inlineCommentsJSON: #"[[{"id":3,"body":"Inline","path":"a.swift","line":7,"user":{"login":"bob"}}],[]]"#)
    #expect(detail.pullRequest.state == "MERGED")
    #expect(detail.pullRequest.comments?.first?.body == "Conversation")
    #expect(detail.reviews.first?.state == "APPROVED")
    #expect(detail.reviews.first?.submittedAt != nil)
    #expect(detail.inlineComments.first?.path == "a.swift")
  }

  @Test("OR is its own argument so gh does not quote the query as one phrase")
  func orTerms() {
    #expect(GitHubProjectReviewService.orTerms(["A-1", "A-2", "A-3"]) == ["A-1", "OR", "A-2", "OR", "A-3"])
    #expect(GitHubProjectReviewService.orTerms(["A-1"]) == ["A-1"])
  }

  @Test("Ticket keys match exactly in title or body")
  func ticketKeyMentions() {
    #expect(GitHubProjectReviewService.mentions("XFA-12: fix", key: "XFA-12"))
    #expect(GitHubProjectReviewService.mentions("Fixes xfa-12.", key: "XFA-12"))
    #expect(!GitHubProjectReviewService.mentions("XFA-123: other", key: "XFA-12"))
    #expect(!GitHubProjectReviewService.mentions("AXFA-12", key: "XFA-12"))
  }

  @Test("Ticket pull requests list open ones first, then most recently updated")
  func ticketPullRequestOrder() {
    func pr(_ id: String, _ state: String, _ updated: Double) -> GitHubProjectPullRequest {
      GitHubProjectPullRequest(
        id: id, number: 1, title: id, url: "u", repositoryName: "r", repositoryNameWithOwner: "o/r",
        authorLogin: nil, updatedAt: Date(timeIntervalSince1970: updated), isDraft: false,
        state: state, projectStatus: nil, projectPriority: nil)
    }
    let sorted = GitHubProjectReviewService.sortedForTicket([
      pr("merged-new", "MERGED", 300), pr("open-old", "OPEN", 100), pr("open-new", "open", 200),
    ])
    #expect(sorted.map(\.id) == ["open-new", "open-old", "merged-new"])
  }

  @Test("Rate-limit reset prefers the exhausted bucket")
  func rateLimitResetPrefersExhaustedBucket() {
    let json = """
      {"resources": {
        "core": {"limit": 5000, "remaining": 4900, "reset": 1791400000},
        "graphql": {"limit": 5000, "remaining": 0, "reset": 1791401234},
        "search": {"limit": 30, "remaining": 30, "reset": 1791399000}
      }}
      """
    #expect(
      GitHubProjectReviewService.rateLimitResetDate(fromRateLimitJSON: json)
        == Date(timeIntervalSince1970: 1_791_401_234))
    #expect(GitHubProjectReviewService.rateLimitResetDate(fromRateLimitJSON: "not json") == nil)
  }

  @Test("Project status is separated from the GitHub pull request search")
  func buildsSearchPlan() {
    let plan = GitHubProjectReviewService.searchPlan(
      for: #"is:pr -is:closed -is:merged status:"Code Review 🔎" -is:draft"#
    )

    #expect(plan.query.isEmpty)
    #expect(plan.statusPredicates.count == 1)
    #expect(plan.statusPredicates[0].value == "Code Review 🔎")
    #expect(!plan.statusPredicates[0].isNegated)
    #expect(plan.state == "open")
    #expect(plan.merged == false)
  }

  @Test("Draft PRs are always excluded")
  func alwaysExcludesDrafts() {
    let plan = GitHubProjectReviewService.searchPlan(for: "is:pr label:backend is:draft")

    #expect(plan.query == "label:backend")
  }

  @Test("Decodes open projects and their saved views")
  func decodesProjects() throws {
    let json = #"""
      {
        "data": {
          "viewer": {
            "login": "phxlle",
            "projectsV2": { "nodes": [] },
            "organizations": {
              "nodes": [
                {
                  "login": "gl-ventures",
                  "projectsV2": {
                    "nodes": [
                      {
                        "id": "project-3",
                        "number": 3,
                        "title": "XFA",
                        "url": "https://github.com/orgs/gl-ventures/projects/3",
                        "closed": false,
                        "views": {
                          "nodes": [
                            {
                              "id": "view-48",
                              "number": 48,
                              "name": "Code review",
                              "filter": "is:pr status:\"Code Review 🔎\" -is:draft",
                              "layout": "TABLE_LAYOUT"
                            }
                          ]
                        }
                      },
                      {
                        "id": "closed-project",
                        "number": 9,
                        "title": "Closed",
                        "url": "https://example.com/closed",
                        "closed": true,
                        "views": { "nodes": [] }
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
      """#

    let projects = try GitHubProjectReviewService.decodeProjects(json)

    #expect(projects.count == 1)
    #expect(projects[0].displayName == "gl-ventures / XFA")
    #expect(projects[0].views.first?.name == "Code review")
    #expect(projects[0].views.first?.filter?.contains("Code Review") == true)
  }

  @Test("Decodes the selected project's status and priority for a PR")
  func decodesProjectFields() throws {
    let json = #"""
      {
        "data": {
          "nodes": [
            {
              "id": "pr-1",
              "projectItems": {
                "nodes": [
                  {
                    "project": { "id": "other-project" },
                    "status": { "name": "Done" },
                    "priority": null
                  },
                  {
                    "project": { "id": "project-3" },
                    "status": { "name": "Code Review 🔎" },
                    "priority": { "name": "Urgent ‼️" }
                  }
                ]
              }
            }
          ]
        }
      }
      """#

    let values = try GitHubProjectReviewService.decodeProjectFieldValues(
      json,
      projectID: "project-3"
    )

    #expect(values["pr-1"]?.status == "Code Review 🔎")
    #expect(values["pr-1"]?.priority == "Urgent ‼️")
  }

  @Test("Queue checks decode success, failure, pending, no checks, and skip missing PRs")
  func decodesCheckRollups() throws {
    func node(_ id: String, _ rollup: String) -> String {
      #"{"id":"\#(id)","commits":{"nodes":[{"commit":{"statusCheckRollup":\#(rollup)}}]}}"#
    }
    let json = #"{"data":{"nodes":["#
      + [
        node("pass", #"{"state":"SUCCESS"}"#),
        node("fail", #"{"state":"FAILURE"}"#),
        node("error", #"{"state":"ERROR"}"#),
        node("pending", #"{"state":"PENDING"}"#),
        node("expected", #"{"state":"EXPECTED"}"#),
        node("no-checks", "null"),
        #"{"id":"no-commits","commits":{"nodes":[]}}"#,
        "null",
      ].joined(separator: ",")
      + "]}}"

    let states = try GitHubProjectReviewService.decodeCheckRollups(json)

    #expect(states["pass"] == .success)
    #expect(states["fail"] == .failure)
    #expect(states["error"] == .failure)
    #expect(states["pending"] == .pending)
    #expect(states["expected"] == .pending)
    #expect(states["no-checks"] == CIStatus.none)
    #expect(states["no-commits"] == CIStatus.none)
    #expect(states.count == 7)
  }

  @Test("A malformed checks response is an error, not an empty result")
  func rejectsMalformedCheckRollups() {
    #expect(throws: GitHubCLIError.self) {
      try GitHubProjectReviewService.decodeCheckRollups(#"{"errors":[{"message":"rate limited"}]}"#)
    }
  }

  @Test("Queue checks are fetched 50 pull requests per call, in order")
  func batchesCheckRollupIDs() {
    let ids = (1...120).map { "pr-\($0)" }
    let batches = GitHubProjectReviewService.batches(ids, size: GitHubProjectReviewService.checkRollupBatchSize)
    #expect(batches.map(\.count) == [50, 50, 20])
    #expect(batches.flatMap { $0 } == ids)
    #expect(GitHubProjectReviewService.batches([], size: 50).isEmpty)
    #expect(GitHubProjectReviewService.batches(Array(ids.prefix(50)), size: 50).count == 1)
  }

  // MARK: - Checks batch loop

  @Test("A failed batch stops the loop: batch 2 of 3 fails → 2 calls, batch 1 results, no throw")
  func checksStopAtFailedBatch() async {
    let runner = ChecksRunnerStub { call, ids in
      guard call == 1 else { throw GitHubCLIError.commandFailed("rate limited") }
      return checksResponse(ids.map { ($0, "SUCCESS") })
    }
    let service = GitHubProjectReviewService(runChecksCommand: runner.run)
    let ids = (1...120).map { "pr-\($0)" }

    let states = await service.checkRollups(forPullRequestIDs: ids)

    #expect(await runner.calls == 2)
    #expect(Set(states.keys) == Set(ids.prefix(50)))
    #expect(states.values.allSatisfy { $0 == .success })
  }

  @Test("A cancelled task makes no gh calls")
  func checksCancelledMakesNoCalls() async {
    let runner = ChecksRunnerStub { _, ids in checksResponse(ids.map { ($0, "SUCCESS") }) }
    let service = GitHubProjectReviewService(runChecksCommand: runner.run)

    let task = Task { () -> [String: CIStatus] in
      withUnsafeCurrentTask { $0?.cancel() }
      return await service.checkRollups(forPullRequestIDs: ["a", "b"])
    }
    let states = await task.value

    #expect(states.isEmpty)
    #expect(await runner.calls == 0)
  }

  @Test("Partial data with an errors array is used, and the next batch still runs")
  func checksPartialDataContinues() async throws {
    // What `gh api graphql` prints (exit 1) when one pull request is inaccessible.
    let partial = #"{"data":{"nodes":[{"id":"pr-1","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},null]},"errors":[{"type":"NOT_FOUND","path":["nodes",1],"message":"Could not resolve to a node with the global id of 'pr-2'"}]}"#
    let decoded = try GitHubProjectReviewService.decodeCheckRollups(partial)
    #expect(decoded == ["pr-1": .failure])

    let runner = ChecksRunnerStub { call, ids in
      call == 1 ? partial : checksResponse(ids.map { ($0, "PENDING") })
    }
    let service = GitHubProjectReviewService(runChecksCommand: runner.run)
    let ids = (1...60).map { "pr-\($0)" }

    let states = await service.checkRollups(forPullRequestIDs: ids)

    #expect(await runner.calls == 2)
    #expect(states["pr-1"] == .failure)
    #expect(states["pr-2"] == nil)
    #expect(states["pr-51"] == .pending)
    #expect(states.count == 11)
  }

  @Test("A response with errors and no data is a failure")
  func checksErrorsWithoutDataFail() {
    #expect(throws: GitHubCLIError.self) {
      try GitHubProjectReviewService.decodeCheckRollups(#"{"data":null,"errors":[{"message":"rate limited"}]}"#)
    }
  }

  // MARK: - One CI rule for queue and detail

  @Test("A detail's checks give the same state as GitHub's rollup for that pull request")
  func detailAgreesWithRollup() throws {
    func runs(_ json: String) throws -> [GitHubCheckRun] {
      try JSONDecoder().decode([GitHubCheckRun].self, from: Data(json.utf8))
    }
    let cases: [(checks: String, rollupState: String?)] = [
      (#"[{"name":"a","status":"COMPLETED","conclusion":"SKIPPED"}]"#, "SUCCESS"),
      (#"[{"name":"a","status":"COMPLETED","conclusion":"NEUTRAL"},{"name":"b","status":"COMPLETED","conclusion":"SKIPPED"}]"#, "SUCCESS"),
      (#"[{"name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"b","status":"COMPLETED","conclusion":"SKIPPED"}]"#, "SUCCESS"),
      (#"[{"name":"a","status":"COMPLETED","conclusion":"SKIPPED"},{"name":"b","status":"IN_PROGRESS"}]"#, "PENDING"),
      (#"[{"name":"a","status":"COMPLETED","conclusion":"FAILURE"},{"name":"b","status":"IN_PROGRESS"}]"#, "FAILURE"),
      (#"[{"context":"ci/x","state":"ERROR"}]"#, "ERROR"),
      ("[]", nil),
    ]
    for (checks, rollupState) in cases {
      let fromDetail = CIStatus.rollup(of: try runs(checks))
      let fromQueue = GitHubProjectReviewService.ciStatus(rollupState: rollupState)
      #expect(fromDetail == fromQueue, "\(checks)")
    }
    #expect(CIStatus.rollup(of: nil) == CIStatus.none)
  }
}

// MARK: - Helpers

/// Stands in for `gh`: counts calls and answers with `respond(callNumber, ids)`.
private actor ChecksRunnerStub {
  private(set) var calls = 0
  private let respond: @Sendable (Int, [String]) throws -> String

  init(_ respond: @escaping @Sendable (Int, [String]) throws -> String) {
    self.respond = respond
  }

  nonisolated var run: GitHubProjectReviewService.ChecksCommandRunner {
    { arguments in try await self.handle(arguments) }
  }

  private func handle(_ arguments: [String]) throws -> String {
    calls += 1
    let ids = arguments.filter { $0.hasPrefix("ids[]=") }.map { String($0.dropFirst("ids[]=".count)) }
    return try respond(calls, ids)
  }
}

private func checksResponse(_ states: [(id: String, state: String)]) -> String {
  let nodes = states.map {
    #"{"id":"\#($0.id)","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"\#($0.state)"}}}]}}"#
  }
  return #"{"data":{"nodes":["# + nodes.joined(separator: ",") + "]}}"
}
